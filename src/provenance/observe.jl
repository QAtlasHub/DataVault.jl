# provenance/observe.jl — what the code a process could see looked like, observed once.
#
# An observation keeps two claims apart:
#
#   * a SOURCE SNAPSHOT: every file of each source root as (path, type, mode, size, SHA-256),
#     identified by the SHA-256 of that inventory, `src1-<hex>`, and stored once per vault;
#   * its BINDING to the code the process runs: `unverified` unless shown otherwise. It is
#     `loaded-matches-disk` only when the caller NAMES the entry code the process will run (a
#     sweep's work function, a report's recipe), that code and every method of the package that
#     owns it come from sources listed in a precompile cache header, and those sources equal the
#     snapshot. Code defined in `Main` — a script, the REPL, `-e`, a closure — cannot be checked,
#     and says so.
#
# Nothing here says the snapshot is the code that ran. It says what was on disk, when, and how far
# the process's loaded code was checked against it. File names under `.datavault/` must never end
# in `.log.toml`: discovery walks the whole tree for that suffix.

const SOURCE_RECIPE = "src1"
# 2: the binding checks the named entry code. Version 1 looked for files included into `Main` in
# `Base._included_files`, which records no include made at run time, so a v1 `loaded-matches-disk`
# can hide code defined in a script.
const OBSERVATION_VERSION = 2
const MATERIALIZE_EXTENSIONS = (".jl", ".toml")    # contents kept; every other file inventoried only
const DEFAULT_HASH_LIMIT = 64 * 1024^2               # larger files are inventoried without a digest
const ENV_RECORDED = (
    "JULIA_NUM_THREADS",
    "JULIA_CPU_TARGET",
    "JULIA_PROJECT",
    "JULIA_LOAD_PATH",
    "JULIA_DEPOT_PATH",
    "JULIA_PKG_OFFLINE",
    "OMP_NUM_THREADS",
    "OPENBLAS_NUM_THREADS",
    "MKL_NUM_THREADS",
    "SLURM_JOB_ID",
    "SLURM_ARRAY_JOB_ID",
    "SLURM_ARRAY_TASK_ID",
    "SLURM_PROCID",
    "SLURM_NODEID",
)

function _provenance_dir(vault::Vault)
    return joinpath(vault.outdir, DATAVAULT_DIR_NAME, vault.spec.study.project_name)
end
_sources_dir(vault::Vault) = joinpath(_provenance_dir(vault), "sources")
_observations_dir(vault::Vault) = joinpath(_provenance_dir(vault), "observations")
_utc_stamp() = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"

function _git_read(dir::AbstractString, args...)::Union{String,Nothing}
    try
        return String(strip(read(pipeline(`git -C $dir $args`; stderr=devnull), String)))
    catch
        return nothing
    end
end

_real(path) = ispath(path) ? realpath(path) : normpath(path)
_inside(path, dir) = startswith(_real(path), rstrip(_real(dir), '/') * "/")

# ── roots ─────────────────────────────────────────────────────────────────────────────────────

# The config's repository (or directory), and every `path` dependency of the active environment
# that is not already inside it. Names are logical — no absolute path enters the snapshot.
function _source_roots(vault::Vault)
    cfg = dirname(abspath(vault.config_path))
    top = _git_read(cfg, "rev-parse", "--show-toplevel")
    roots = [
        if top === nothing
            (name="config", dir=cfg, kind=:plain)
        else
            (name="config", dir=top, kind=:git)
        end,
    ]
    for dep in _path_dependencies()
        any(r -> _inside(dep.path, r.dir) || _real(dep.path) == _real(r.dir), roots) &&
            continue
        ingit = _git_read(dep.path, "rev-parse", "--show-toplevel") !== nothing
        push!(
            roots,
            (name="pkg:$(dep.name):$(dep.uuid)", dir=dep.path, kind=ingit ? :git : :plain),
        )
    end
    return roots
end

const _PathDep = NamedTuple{(:name, :uuid, :path),NTuple{3,String}}

function _active_manifest()::Union{String,Nothing}
    project = Base.active_project()
    project === nothing && return nothing
    manifest = try
        Base.project_file_manifest_path(project)
    catch
        nothing
    end
    return manifest !== nothing && isfile(manifest) ? manifest : nothing
end

function _path_dependencies()::Vector{_PathDep}
    manifest = _active_manifest()
    manifest === nothing && return _PathDep[]
    out = _PathDep[]
    for (name, entries) in get(TOML.parsefile(manifest), "deps", Dict{String,Any}()),
        e in entries

        haskey(e, "path") || continue
        p = normpath(joinpath(dirname(manifest), e["path"]))
        isdir(p) && push!(out, (name=String(name), uuid=String(get(e, "uuid", "")), path=p))
    end
    return sort!(out; by=d -> d.name)
end

# ── inventory ─────────────────────────────────────────────────────────────────────────────────

function _root_files(root)::Union{Vector{String},Nothing}
    if root.kind === :git
        out = _git_read(
            root.dir, "ls-files", "-z", "--cached", "--others", "--exclude-standard"
        )
        out === nothing && return nothing
        return sort!(unique!(filter!(!isempty, String.(split(out, '\0')))))
    end
    files = String[]
    for (dir, dirs, fs) in walkdir(root.dir)
        filter!(d -> d != ".git", dirs)
        append!(files, relpath(joinpath(dir, f), root.dir) for f in fs)
    end
    return sort!(files)
end

struct SourceEntry
    root::String
    path::String            # relative to the root
    type::String            # file | symlink | dir | missing
    mode::String            # "x" executable, "-" otherwise
    size::Int
    sha256::String          # hex, "skipped" (over the hash limit) or "" (no content)
    crc32c::UInt32          # for the binding check; not part of the snapshot
    full::String
end

function _entry(root, rel, hash_limit, blobs, notes)::SourceEntry
    full = joinpath(root.dir, rel)
    st = lstat(full)
    if islink(st)
        target = readlink(full)
        return SourceEntry(
            root.name,
            rel,
            "symlink",
            "-",
            sizeof(target),
            bytes2hex(sha256(target)),
            0x00000000,
            full,
        )
    elseif isfile(st)
        mode = (st.mode & 0o111) != 0 ? "x" : "-"
        if st.size > hash_limit
            push!(notes, "$(root.name):$rel: larger than the hash limit, no digest")
            return SourceEntry(
                root.name, rel, "file", mode, st.size, "skipped", 0x00000000, full
            )
        end
        bytes = read(full)
        sha = bytes2hex(sha256(bytes))
        any(ext -> endswith(lowercase(rel), ext), MATERIALIZE_EXTENSIONS) &&
            (blobs[sha] = bytes)
        return SourceEntry(
            root.name, rel, "file", mode, length(bytes), sha, crc32c(bytes), full
        )
    elseif isdir(st)
        push!(notes, "$(root.name):$rel: a directory (a submodule?) is not inventoried")
        return SourceEntry(root.name, rel, "dir", "-", 0, "", 0x00000000, full)
    end
    return SourceEntry(root.name, rel, "missing", "-", 0, "", 0x00000000, full)
end

function _inventory(roots; hash_limit::Integer)
    entries = SourceEntry[]
    blobs = Dict{String,Vector{UInt8}}()
    notes = String[]
    for root in roots
        files = _root_files(root)
        if files === nothing
            push!(notes, "$(root.name): files could not be listed")
            continue
        end
        append!(entries, _entry(root, rel, hash_limit, blobs, notes) for rel in files)
    end
    return entries, blobs, notes
end

# The canonical inventory: its bytes ARE the snapshot's identity.
function _files_tsv(entries)::String
    io = IOBuffer()
    println(io, SOURCE_RECIPE)
    for e in sort(entries; by=e -> (e.root, e.path))
        println(
            io,
            join((e.root, escape_string(e.path), e.type, e.mode, e.size, e.sha256), '\t'),
        )
    end
    return String(take!(io))
end

# ── storage ───────────────────────────────────────────────────────────────────────────────────

function _atomic_bytes_write(path::AbstractString, bytes)
    isfile(path) && return path
    mkpath(dirname(path))
    tmp = string(path, ".tmp.", getpid(), ".", objectid(current_task()), ".", time_ns())
    try
        write(tmp, bytes)
        mv(tmp, path; force=true)
    catch e
        isfile(tmp) && rm(tmp; force=true)
        rethrow(e)
    end
    return path
end

# Blobs first, then the snapshot directory by one rename: a snapshot that exists is complete, and
# every blob it names is already there.
function _publish_snapshot(vault::Vault, tsv::String, state::Dict, blobs)
    sources = _sources_dir(vault)
    for (sha, bytes) in blobs
        _atomic_bytes_write(joinpath(sources, "blobs", sha), bytes)
    end
    hex = bytes2hex(sha256(tsv))
    id = "$(SOURCE_RECIPE)-$hex"
    final = joinpath(sources, id)
    if isdir(final)
        bytes2hex(sha256(read(joinpath(final, "files.tsv")))) == hex ||
            error("DataVault: source snapshot $final does not match its own id")
        return id
    end
    tmp = joinpath(sources, ".tmp-$id-$(getpid())-$(time_ns())")
    mkpath(tmp)
    write(joinpath(tmp, "files.tsv"), tsv)
    open(
        io -> TOML.print(io, merge(state, Dict("id" => id)); sorted=true),
        joinpath(tmp, "state.toml"),
        "w",
    )
    write(joinpath(tmp, "COMPLETE"), "")
    try
        mv(tmp, final)
    catch
        isdir(final) || rethrow()
        rm(tmp; recursive=true, force=true)          # another process published the same snapshot
    end
    return id
end

# ── binding ───────────────────────────────────────────────────────────────────────────────────

# Julia's precompile cache header lists every source a package image was built from, with its
# size and CRC32c. This reads that list, or returns `nothing` when there is no cache or the header
# is laid out differently in this Julia (an internal API, checked on 1.12 and 1.13).
function _cached_sources(cachepath)
    cachepath === nothing && return nothing
    try
        h = Base.parse_cache_header(cachepath)[2]
        incs = [x for x in vcat(h[1], h[2]) if x isa Base.CacheHeaderIncludes]
        return unique(x -> x.filename, incs)
    catch
        return nothing
    end
end

# Per root: `matches` when every source of every package loaded from it equals the snapshot's
# bytes, `differs` when one does not, `unknown` when a loaded package cannot be checked, and
# `not-loaded` when none came from it. `files` holds, per root, the loaded sources it checked.
function _loaded_status(roots, entries)
    byfile = Dict(
        _real(e.full) => e for e in entries if e.type == "file" && e.sha256 != "skipped"
    )
    status = Dict(r.name => "not-loaded" for r in roots)
    rank = Dict("not-loaded" => 0, "matches" => 1, "unknown" => 2, "differs" => 3)
    raise!(name, s) = rank[s] > rank[status[name]] && (status[name] = s)
    files = Dict(r.name => String[] for r in roots)
    for (_, origin) in Base.pkgorigins
        origin.path === nothing && continue
        i = findfirst(r -> _inside(origin.path, r.dir), roots)
        i === nothing && continue
        name = roots[i].name
        includes = _cached_sources(origin.cachepath)
        if includes === nothing || isempty(includes)
            raise!(name, "unknown")
            continue
        end
        for inc in includes
            e = get(byfile, _real(inc.filename), nothing)
            if e === nothing
                raise!(name, "unknown")                # built from a file the snapshot does not hold
            elseif e.size != inc.fsize || e.crc32c != inc.hash
                raise!(name, "differs")
            else
                raise!(name, "matches")
            end
            push!(files[name], _real(inc.filename))
        end
    end
    return status, files
end

# Whether the loaded sources of a git root are also what HEAD holds: tracked, and unchanged from
# HEAD. Only then does the root's `head` name the code that was loaded, not just the tree.
function _loaded_matches_head(root, loaded, files)::String
    loaded == "not-loaded" && return "not-loaded"
    (root.kind === :git && loaded == "matches" && !isempty(files)) || return "unknown"
    rel = [relpath(f, _real(root.dir)) for f in unique(files)]
    tracked = _git_read(root.dir, "ls-files", "--error-unmatch", "--", rel...)
    tracked === nothing && return "false"
    changed = _git_read(root.dir, "diff", "--name-only", "HEAD", "--", rel...)
    changed === nothing && return "unknown"
    return string(isempty(changed))
end

# ── entry code ────────────────────────────────────────────────────────────────────────────────

# Julia 1.12 partitions bindings and methods by world age: a caller already running does not see a
# method or a name defined after it started (a patch made by the script that called us). Every
# lookup here therefore asks the latest world.
_latest_names(mod) = Base.invokelatest(names, mod; all=true)
_latest_methods(f) = Base.invokelatest(methods, f)
function _latest_get(mod, n)
    return if Base.invokelatest(isdefined, mod, n)
        Base.invokelatest(getfield, mod, n)
    else
        nothing
    end
end

# The sources of the package `mod` belongs to, as its cache header lists them, or `nothing`.
function _package_sources(mod::Module)
    top = Base.moduleroot(mod)
    origin = get(Base.pkgorigins, Base.PkgId(top), nothing)
    origin === nothing && return nothing
    incs = _cached_sources(origin.cachepath)
    (incs === nothing || isempty(incs)) && return nothing
    return (; path=origin.path, files=Set(_real(x.filename) for x in incs))
end

_where(m::Method) = "$(m.file):$(m.line)"

# A method's code is checked when it was defined by its package's own sources: its module belongs
# to that package, and its file is one the cache header lists. A method evaluated into the package
# from `Main` (a patch, an `@eval`) fails one or the other.
function _method_checked(m::Method, top::Module, files)
    return Base.moduleroot(m.module) === top && _real(String(m.file)) in files
end

"""
    entry_code_reasons(code, roots, status) -> Vector{String}

Why the entry code cannot be vouched for; empty when it can. Each entry must be a function that
captures nothing, owned by a package loaded from a source root whose loaded status is `matches`,
and every method of every function that package defines must come from the package's own cached
sources. Without entry code nothing is known about what the process will run.
"""
function entry_code_reasons(code, roots, status)::Vector{String}
    isempty(code) &&
        return ["no entry code was named, so what this process will run is not known"]
    reasons = String[]
    seen = Set{Module}()
    for f in code
        T = typeof(f)
        name = string(f)
        if !(f isa Function)
            push!(reasons, "$name is not a function")
            continue
        end
        fieldcount(T) == 0 || push!(
            reasons,
            "$name captures values (a closure or a callable struct), which cannot be checked",
        )
        if nameof(parentmodule(f)) === :__deserialized_types__
            push!(
                reasons,
                "$name arrived from another process (a closure sent by the master), so its " *
                "code is that process's and cannot be checked here",
            )
            continue
        end
        top = Base.moduleroot(parentmodule(f))
        if top === Main
            push!(
                reasons,
                "$name is defined in Main (a script, the REPL or -e), which cannot be checked",
            )
            continue
        end
        src = _package_sources(top)
        if src === nothing
            push!(reasons, "$name belongs to $top, which has no readable precompile cache")
            continue
        end
        i = findfirst(r -> _inside(src.path, r.dir), roots)
        if i === nothing
            push!(reasons, "$name belongs to $top, which is not loaded from a source root")
            continue
        end
        get(status, roots[i].name, "unknown") == "matches" || push!(
            reasons,
            "$name belongs to $top, whose loaded sources do not match the snapshot",
        )
        for m in _latest_methods(f)
            _method_checked(m, top, src.files) || push!(
                reasons,
                "a method of $name is defined at $(_where(m)), outside $top's checked sources",
            )
        end
        top in seen && continue
        push!(seen, top)
        append!(reasons, _patched_methods(top, src.files))
    end
    return unique!(reasons)
end

# Methods of the package's own functions that its sources did not define: what the entry code
# calls can be changed from outside without changing a file.
function _patched_methods(top::Module, files)::Vector{String}
    out = String[]
    for mod in _submodules(top), n in _latest_names(mod)
        f = _latest_get(mod, n)
        f isa Function && parentmodule(f) === mod || continue
        for m in _latest_methods(f)
            # A method another package adds to this function is that package's code, not a patch.
            owner = Base.moduleroot(m.module)
            (owner === top || owner === Main) || continue
            _method_checked(m, top, files) || push!(
                out,
                "$(mod).$(n) has a method defined at $(_where(m)), outside $top's checked sources",
            )
        end
    end
    return out
end

function _submodules(top::Module)
    out = Module[top]
    i = 1
    while i <= length(out)
        mod = out[i]
        for n in _latest_names(mod)
            x = _latest_get(mod, n)
            x isa Module &&
                x !== mod &&
                parentmodule(x) === mod &&
                !(x in out) &&
                push!(out, x)
        end
        i += 1
    end
    return out
end

"""
    binding_of(status, revise_loaded, code_reasons) -> (binding, reasons)

The binding an observation can claim, from each root's loaded status and what
[`entry_code_reasons`](@ref) found. `loaded-matches-disk` only when the config's repository (where
the study's code lives) was loaded from and matched, every other root that was loaded from
matched, Revise is not loaded, and the named entry code was vouched for (`code_reasons` empty).
`loaded-differs-from-disk` when a loaded package's sources differ from the snapshot. Otherwise
`unverified`, with the reasons — the default: a claim needs evidence, its absence does not.
"""
function binding_of(status::AbstractDict, revise_loaded::Bool, code_reasons)
    differs = sort([k for (k, v) in status if v == "differs"])
    isempty(differs) || return "loaded-differs-from-disk",
    ["$k: a loaded package's sources differ from the snapshot" for k in differs]
    reasons = [
        "$k: a loaded package could not be checked" for
        k in sort([k for (k, v) in status if v == "unknown"])
    ]
    # The study's own code lives in the config's repository. Matching dependencies alone would
    # say nothing about it, so the config root must itself have been loaded from and checked.
    get(status, "config", "not-loaded") == "not-loaded" && push!(
        reasons,
        "config: no package was loaded from the config's repository, so the study's code is not " *
        "among what was checked",
    )
    revise_loaded && push!(reasons, "Revise is loaded: code can change after it is checked")
    append!(reasons, code_reasons)
    return isempty(reasons) ? "loaded-matches-disk" : "unverified", reasons
end

# What an entry was, for the record: its name, the module that owns it, and where its methods are.
function _describe(f)::Dict{String,Any}
    f isa Function ||
        return Dict{String,Any}("name" => string(f), "kind" => "not a function")
    return Dict{String,Any}(
        "name" => string(f),
        "module" => string(parentmodule(f)),
        "captures" => fieldcount(typeof(f)) > 0,
        "methods" => [_where(m) for m in _latest_methods(f)],
    )
end

# ── the observation ───────────────────────────────────────────────────────────────────────────

function _root_record(root, loaded::String, files)::Dict{String,Any}
    record = Dict{String,Any}(
        "name" => root.name,
        "kind" => String(root.kind),
        "dir" => root.dir,
        "loaded" => loaded,
        "loaded_matches_head" => _loaded_matches_head(root, loaded, files),
    )
    if root.kind === :git
        observed = _git_observe(root.dir)
        record["head"] = observed.commit
        record["object_format"] = observed.object_format
        porcelain = _git_read(root.dir, "status", "--porcelain", "--untracked-files=all")
        record["dirty"] = porcelain === nothing ? "unknown" : string(!isempty(porcelain))
    else
        record["head"] = record["object_format"] = record["dirty"] = "unknown"
    end
    return record
end

function _environment_record(vault::Vault)::Dict{String,Any}
    out = Dict{String,Any}()
    blobs = joinpath(_sources_dir(vault), "blobs")
    project = Base.active_project()
    for (key, file) in
        (("project_sha256", project), ("manifest_sha256", _active_manifest()))
        (file === nothing || !isfile(file)) && continue
        bytes = read(file)
        out[key] = bytes2hex(sha256(bytes))
        _atomic_bytes_write(joinpath(blobs, out[key]), bytes)
    end
    return out
end

function _julia_record()::Dict{String,Any}
    opts = Base.JLOptions()
    return Dict{String,Any}(
        "version" => string(VERSION),
        "commit" => Base.GIT_VERSION_INFO.commit,
        "image_file" => opts.image_file == C_NULL ? "" : unsafe_string(opts.image_file),
        "check_bounds" => Int(opts.check_bounds),
        "opt_level" => Int(opts.opt_level),
        "fast_math" => Int(opts.fast_math),
        "threads" => Threads.nthreads(),
    )
end

"""
    observe_sources(vault; phase = "run-start", process = Dict(), hash_limit = 64 MiB,
                    code = ()) -> token

Observe the source roots this process can see — the config's repository and every `path`
dependency of the active environment — store the snapshot (once per distinct content) and an
observation record, and return the record's token for [`mark_done!`](@ref)'s `observation`.

The record says when (`observed_at`, `phase`), where (host, pid, and whatever `process` adds, such
as a worker id), which snapshot (`source`), each root's git HEAD and whether it was dirty, the Julia
build and a fixed list of environment variables, and the **binding**: how far the code this process
has loaded was checked against the snapshot (see [`binding_of`](@ref)). File contents are stored
only for `.jl` and `.toml` files; every other file is inventoried by size and digest.

`code` names the entry functions this process will run for its results — a sweep's work
function, a report's recipe. Without it the binding is `unverified`: what the process will run is
not known. With it, the binding can be `loaded-matches-disk` only if each entry passes
[`entry_code_reasons`](@ref). Each git root also records `loaded_matches_head`: `"true"` when the
sources loaded from it are tracked and unchanged from its `head`, so that commit names the loaded
code rather than only the tree.
"""
function observe_sources(
    vault::Vault;
    phase::AbstractString="run-start",
    process::AbstractDict=Dict{String,Any}(),
    hash_limit::Integer=DEFAULT_HASH_LIMIT,
    code=(),
)::String
    _refuse_if_readonly(vault, "observe_sources")
    observed_at = _utc_stamp()
    roots = _source_roots(vault)
    entries, blobs, notes = _inventory(roots; hash_limit)
    complete =
        !any(e -> e.sha256 == "skipped" || e.type == "dir", entries) &&
        !any(n -> occursin("could not be listed", n), notes)
    state = Dict{String,Any}(
        "recipe" => SOURCE_RECIPE,
        "roots" => [Dict("name" => r.name, "kind" => String(r.kind)) for r in roots],
        "inventory_complete" => complete,
        "materialized" => collect(MATERIALIZE_EXTENSIONS),
        "notes" => notes,
    )
    source = _publish_snapshot(vault, _files_tsv(entries), state, blobs)

    status, loaded_files = _loaded_status(roots, entries)
    revise = any(id -> id.name == "Revise", keys(Base.loaded_modules))
    binding, reasons = binding_of(status, revise, entry_code_reasons(code, roots, status))

    token =
        "obs$(OBSERVATION_VERSION)-" *
        Dates.format(Dates.now(Dates.UTC), "yyyymmddTHHMMSS") *
        "Z-" *
        string(getpid(); base=16) *
        "-" *
        string(rand(Random.RandomDevice(), UInt64); base=16, pad=16)   # not the seedable RNG
    record = Dict{String,Any}(
        "observation_version" => OBSERVATION_VERSION,
        "token" => token,
        "observed_at" => observed_at,
        "phase" => String(phase),
        "source" => source,
        "binding" => binding,
        "binding_reasons" => reasons,
        "roots" => [_root_record(r, status[r.name], loaded_files[r.name]) for r in roots],
        "code" => [_describe(f) for f in code],
        "process" => merge(
            Dict{String,Any}("host" => gethostname(), "pid" => getpid()),
            Dict{String,Any}(String(k) => v for (k, v) in process),
        ),
        "julia" => _julia_record(),
        "env" => Dict{String,Any}(k => ENV[k] for k in ENV_RECORDED if haskey(ENV, k)),
        "environment" => _environment_record(vault),
        "revise_loaded" => revise,
        "program_file" => isempty(PROGRAM_FILE) ? "" : abspath(PROGRAM_FILE),
        "interactive" => isinteractive(),
    )
    path = joinpath(_observations_dir(vault), "$token.toml")
    _atomic_bytes_write(path, sprint(io -> TOML.print(io, record; sorted=true)))
    return token
end
