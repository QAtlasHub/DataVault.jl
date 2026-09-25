# provenance/observe.jl — what the code a process could see looked like, observed once.
#
# An observation keeps two claims apart:
#
#   * a SOURCE SNAPSHOT: every file of each source root as (path, type, mode, size, SHA-256),
#     identified by the SHA-256 of that inventory, `src1-<hex>`, and stored once per vault;
#   * its BINDING to the code the process runs, which never claims a match: `unverified`, or
#     `loaded-differs-from-disk` when a loaded package's cached sources are known to differ from
#     the snapshot. A match is not claimed because it cannot be shown from inside the process:
#     code defined in a script, a closure, or a method added to Base from `Main` runs without
#     leaving a trace in any cache header (`Base._included_files` records no run-time include).
#
# Nothing here says the snapshot is the code that ran. It says what was on disk, when, and how far
# the process's loaded code was checked against it. File names under `.datavault/` must never end
# in `.log.toml`: discovery walks the whole tree for that suffix.

const SOURCE_RECIPE = "src1"
const OBSERVATION_VERSION = 1
const MATERIALIZE_EXTENSIONS = (".jl", ".toml")    # contents always kept, at any size up to the hash limit
const DEFAULT_MATERIALIZE_LIMIT = 1024^2             # any other file: contents kept up to this size
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

# The study, every `path` dependency of the active environment that is not already inside it, and —
# when `depot` — every package this process loaded from a depot. Names are logical: no absolute
# path enters the snapshot.
#
# The study is the active environment's directory when the config lies inside it (a study that
# carries its own Project.toml, so that a repository of many studies does not capture them all),
# and otherwise the config's repository, or its directory outside git.
function _source_roots(vault::Vault; depot::Bool=false, notes=String[])
    cfg = dirname(abspath(vault.config_path))
    top = _git_read(cfg, "rev-parse", "--show-toplevel")
    project = Base.active_project()
    envdir = project === nothing ? nothing : dirname(abspath(project))
    study = if envdir !== nothing && (_inside(cfg, envdir) || _real(cfg) == _real(envdir))
        envdir
    else
        something(top, cfg)
    end
    roots = Any[(name="config", dir=study, kind=top === nothing ? :plain : :git, tree="")]
    for dep in _path_dependencies()
        any(r -> _inside(dep.path, r.dir) || _real(dep.path) == _real(r.dir), roots) &&
            continue
        ingit = _git_read(dep.path, "rev-parse", "--show-toplevel") !== nothing
        push!(
            roots,
            (
                name="pkg:$(dep.name):$(dep.uuid)",
                dir=dep.path,
                kind=ingit ? :git : :plain,
                tree="",
            ),
        )
    end
    depot && append!(roots, _depot_roots(roots, notes))
    return roots
end

# Every package this process loaded from a depot (`packages/<name>/<slug>`), with the tree hash the
# active Manifest pins it to. These are what a registered or git-URL dependency is: a tree that
# only a registry, a package server or a git remote can give back, so the snapshot keeps it.
function _depot_roots(existing, notes=String[])
    manifest = _active_manifest()
    manifest === nothing && return Any[]
    pinned = Dict{String,String}()
    for (_, entries) in get(TOML.parsefile(manifest), "deps", Dict{String,Any}()),
        e in entries

        haskey(e, "git-tree-sha1") &&
            haskey(e, "uuid") &&
            (pinned[e["uuid"]] = e["git-tree-sha1"])
    end
    depots = [joinpath(_real(d), "packages") for d in DEPOT_PATH if isdir(d)]
    out = Any[]
    for (id, origin) in Base.pkgorigins
        (id.uuid === nothing || origin.path === nothing) && continue
        tree = get(pinned, string(id.uuid), nothing)
        tree === nothing && continue
        any(d -> _inside(origin.path, d), depots) || continue
        dir = dirname(dirname(origin.path))                     # <slug>/src/<name>.jl → <slug>
        any(r -> _real(r.dir) == _real(dir) || _inside(dir, r.dir), existing) && continue
        push!(out, (name="pkg:$(id.name):$(id.uuid)", dir=dir, kind=:depot, tree=tree))
    end
    append!(out, _artifact_roots(out, notes))
    return sort!(out; by=r -> r.name)
end

# The artifacts those packages' `Artifacts.toml` select for this platform, where installed: a JLL
# loads a library from `artifacts/<tree>`, which no package tree holds. Named by their tree hash,
# which is also their directory's name, so a restore knows where each goes and what it must hash to.
# One that cannot be resolved is a note, and the inventory is then not complete: a recomputation
# would find the library missing, and the observation must not look whole.
function _artifact_roots(packages, notes=String[])
    out = Any[]
    seen = Set{String}()
    platform = Base.BinaryPlatforms.HostPlatform()
    for p in packages
        toml = joinpath(p.dir, "Artifacts.toml")
        isfile(toml) || continue
        dict = try
            TOML.parsefile(toml)
        catch e
            push!(
                notes,
                "$(p.name): Artifacts.toml could not be resolved: $(sprint(showerror, e))",
            )
            continue
        end
        for name in sort!(collect(keys(dict)))
            meta = try
                Artifacts.artifact_meta(name, dict, toml; platform)
            catch e
                push!(
                    notes,
                    "$(p.name): artifact $name could not be resolved: $(sprint(showerror, e))",
                )
                nothing
            end
            (meta === nothing || !haskey(meta, "git-tree-sha1")) && continue
            tree = meta["git-tree-sha1"]
            tree in seen && continue
            dir = nothing
            for d in DEPOT_PATH
                cand = joinpath(d, "artifacts", tree)
                isdir(cand) && (dir=cand; break)
            end
            dir === nothing && continue                        # lazy and never fetched
            push!(seen, tree)
            push!(out, (name="artifact:$name:$tree", dir=dir, kind=:artifact, tree=tree))
        end
    end
    return out
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

# Relative to the root. Anything under `exclude` (the vault's own output) is not source, even when
# it sits inside the study and nothing ignores it.
function _root_files(root; exclude=nothing)::Union{Vector{String},Nothing}
    keep(rel) = exclude === nothing || !_inside(joinpath(root.dir, rel), exclude)
    if root.kind === :git
        out = _git_read(
            root.dir, "ls-files", "-z", "--cached", "--others", "--exclude-standard"
        )
        out === nothing && return nothing
        return sort!(filter!(keep, unique!(filter!(!isempty, String.(split(out, '\0'))))))
    end
    files = String[]
    for (dir, dirs, fs) in walkdir(root.dir)
        filter!(d -> d != ".git", dirs)
        # Do not walk into the output at all: it can be far larger than the study.
        exclude === nothing || filter!(dirs) do d
            p = joinpath(dir, d)
            return !(_real(p) == _real(exclude) || _inside(p, exclude))
        end
        append!(files, relpath(joinpath(dir, f), root.dir) for f in fs)
    end
    return sort!(filter!(keep, files))
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

# A file's contents are kept when it is `.jl`/`.toml` (at any size up to the hash limit) or no
# larger than `materialize_limit`: the snapshot must hold what a package reads besides its code (a
# table, a template, a script), and an extension list drops those without a word.
function _materialize(rel, size, limit)
    return size <= limit ||
           any(ext -> endswith(lowercase(rel), ext), MATERIALIZE_EXTENSIONS)
end

function _entry(root, rel, hash_limit, blobs, notes; materialize_limit)::SourceEntry
    full = joinpath(root.dir, rel)
    st = lstat(full)
    # A package or artifact from a depot is kept whole: it is what only its origin could give
    # back, and a library in it is routinely larger than any limit meant for a study's files.
    root.kind in (:depot, :artifact) && (materialize_limit = hash_limit)
    if islink(st)
        target = readlink(full)
        # The link's target is its content; kept, so that a library's `libx.so -> libx.so.1`
        # can be laid out again.
        blobs[bytes2hex(sha256(target))] = Vector{UInt8}(target)
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
        _materialize(rel, length(bytes), materialize_limit) && (blobs[sha] = bytes)
        return SourceEntry(
            root.name, rel, "file", mode, length(bytes), sha, crc32c(bytes), full
        )
    elseif isdir(st)
        push!(notes, "$(root.name):$rel: a directory (a submodule?) is not inventoried")
        return SourceEntry(root.name, rel, "dir", "-", 0, "", 0x00000000, full)
    end
    return SourceEntry(root.name, rel, "missing", "-", 0, "", 0x00000000, full)
end

function _inventory(
    roots; hash_limit::Integer, materialize_limit::Integer=0, exclude=nothing
)
    entries = SourceEntry[]
    blobs = Dict{String,Vector{UInt8}}()
    notes = String[]
    for root in roots
        files = _root_files(root; exclude)
        if files === nothing
            push!(notes, "$(root.name): files could not be listed")
            continue
        end
        append!(
            entries,
            _entry(root, rel, hash_limit, blobs, notes; materialize_limit) for rel in files
        )
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
# `not-loaded` when none came from it.
function _loaded_status(roots, entries)::Dict{String,String}
    byfile = Dict(
        _real(e.full) => e for e in entries if e.type == "file" && e.sha256 != "skipped"
    )
    status = Dict(r.name => "not-loaded" for r in roots)
    rank = Dict("not-loaded" => 0, "matches" => 1, "unknown" => 2, "differs" => 3)
    raise!(name, s) = rank[s] > rank[status[name]] && (status[name] = s)
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
        end
    end
    return status
end

"""
    binding_of(status, revise_loaded, main_files_in_roots) -> (binding, reasons)

The binding an observation can claim, from each root's loaded status: `loaded-differs-from-disk`
when a loaded package's sources differ from the snapshot (a fact: the bytes it was built from are
not on disk), and otherwise `unverified`, with the reasons. It never returns
`loaded-matches-disk`: that every loaded package matched does not show that the code which ran
was theirs, since code defined outside any package (a script, a closure, a method added to Base
from `Main`) leaves no trace to check. A reader treats a `loaded-matches-disk` written by an
earlier version as `unverified`.
"""
function binding_of(status::AbstractDict, revise_loaded::Bool, main_files_in_roots)
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
    append!(
        reasons,
        "$f is included into Main, where its code cannot be checked" for
        f in main_files_in_roots
    )
    isempty(reasons) && push!(reasons, NO_MATCH_CLAIMED)
    return "unverified", reasons
end

const NO_MATCH_CLAIMED =
    "every loaded package matched the snapshot, but a match is not claimed: code defined " *
    "outside a package (a script, a closure, a method added from Main) cannot be checked"

# ── the observation ───────────────────────────────────────────────────────────────────────────

function _root_record(root, loaded::String)::Dict{String,Any}
    record = Dict{String,Any}(
        "name" => root.name,
        "kind" => String(root.kind),
        "dir" => root.dir,
        "loaded" => loaded,
    )
    if root.kind === :git
        observed = _git_observe(root.dir)
        record["head"] = observed.commit
        record["object_format"] = observed.object_format
        porcelain = _git_read(
            root.dir, "status", "--porcelain", "--untracked-files=all", "--", "."
        )
        record["dirty"] = porcelain === nothing ? "unknown" : string(!isempty(porcelain))
    elseif root.kind in (:depot, :artifact)
        # The tree the Manifest pins. Whether the directory still hashes to it is for a restore
        # to check: a depot is not written to after install, but nothing here proves it.
        record["head"] = root.tree
        record["object_format"] = "sha1"
        record["dirty"] = "unknown"
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
    exe = joinpath(Sys.BINDIR, Base.julia_exename())
    record = Dict{String,Any}(
        "version" => string(VERSION),
        "commit" => Base.GIT_VERSION_INFO.commit,
        "image_file" => opts.image_file == C_NULL ? "" : unsafe_string(opts.image_file),
        "check_bounds" => Int(opts.check_bounds),
        "opt_level" => Int(opts.opt_level),
        "fast_math" => Int(opts.fast_math),
        "threads" => Threads.nthreads(),
        # Which binary, not only which version: a launcher (juliaup) given the same command in
        # another HOME starts another Julia. The digest is of the binary itself.
        "bindir" => Sys.BINDIR,
        "platform" => Base.BinaryPlatforms.triplet(Base.BinaryPlatforms.HostPlatform()),
        "cpu_name" => Sys.CPU_NAME,
        # BLAS's own thread count, whatever set it: results differ in the last bits between
        # counts, so a bitwise comparison is only meaningful at the one recorded here.
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        "blas_libraries" =>
            [basename(l.libname) for l in LinearAlgebra.BLAS.get_config().loaded_libs],
    )
    isfile(exe) && (record["executable_sha256"] = bytes2hex(open(sha256, exe)))
    return record
end

"""
    observe_sources(vault; phase = "run-start", process = Dict(), hash_limit = 64 MiB,
                    materialize_limit = 1 MiB, depot_packages = (phase == "run-start")) -> token

Observe the source roots this process can see, store the snapshot (once per distinct content) and
an observation record, and return the record's token for [`mark_done!`](@ref)'s `observation`.

The roots are the study (the active environment's directory when the config lies inside it,
otherwise the config's repository), every `path` dependency of the active environment, and, when
`depot_packages`, every package this process loaded from a depot, recorded as a `depot` root whose
`head` is the tree hash the Manifest pins. The vault's own output directory is never source.

The record says when (`observed_at`, `phase`), where (host, pid, and whatever `process` adds, such
as a worker id), which snapshot (`source`), each root's git HEAD and whether it was dirty, the Julia
build (with the binary's digest, the platform and BLAS's thread count) and a fixed list of
environment variables, and the **binding**: how far the code this process has loaded was checked
against the snapshot (see [`binding_of`](@ref)). File contents are stored for `.jl` and `.toml`
files and for any other file up to `materialize_limit`, and for every file of a `depot` or
`artifact` root up to `hash_limit` (a library there is routinely larger); a symlink's target is kept
as its content. Every file is inventoried by size, and by digest up to `hash_limit`. An artifact
that cannot be resolved, like a root that cannot be listed, is a note and leaves the inventory
incomplete.

Depot packages are kept at `run-start` only by default: that is the process that computed, and a
render's plotting stack is large and not what a recomputation needs.
"""
function observe_sources(
    vault::Vault;
    phase::AbstractString="run-start",
    process::AbstractDict=Dict{String,Any}(),
    hash_limit::Integer=DEFAULT_HASH_LIMIT,
    materialize_limit::Integer=DEFAULT_MATERIALIZE_LIMIT,
    depot_packages::Bool=(phase == "run-start"),
)::String
    _refuse_if_readonly(vault, "observe_sources")
    observed_at = _utc_stamp()
    root_notes = String[]
    roots = _source_roots(vault; depot=depot_packages, notes=root_notes)
    entries, blobs, notes = _inventory(
        roots; hash_limit, materialize_limit, exclude=vault.outdir
    )
    notes = vcat(root_notes, notes)
    complete =
        !any(e -> e.sha256 == "skipped" || e.type == "dir", entries) &&
        !any(n -> occursin(r"could not be (listed|resolved)", n), notes)
    state = Dict{String,Any}(
        "recipe" => SOURCE_RECIPE,
        "roots" => [
            merge(
                Dict("name" => r.name, "kind" => String(r.kind)),
                isempty(r.tree) ? Dict{String,String}() : Dict("tree" => r.tree),
            ) for r in roots
        ],
        "inventory_complete" => complete,
        "materialized" => collect(MATERIALIZE_EXTENSIONS),
        "materialize_limit" => materialize_limit,
        "notes" => notes,
    )
    source = _publish_snapshot(vault, _files_tsv(entries), state, blobs)

    status = _loaded_status(roots, entries)
    revise = any(id -> id.name == "Revise", keys(Base.loaded_modules))
    main_files = [f for (m, f) in Base._included_files if m === Main]
    in_roots = [f for f in main_files if any(r -> _inside(f, r.dir), roots)]
    binding, reasons = binding_of(status, revise, in_roots)

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
        "roots" => [_root_record(r, status[r.name]) for r in roots],
        "process" => merge(
            Dict{String,Any}("host" => gethostname(), "pid" => getpid()),
            Dict{String,Any}(String(k) => v for (k, v) in process),
        ),
        "julia" => _julia_record(),
        # The script `julia <file>` ran: not among `main_files`, which only lists includes.
        "program" => isempty(PROGRAM_FILE) ? "" : abspath(PROGRAM_FILE),
        "env" => Dict{String,Any}(k => ENV[k] for k in ENV_RECORDED if haskey(ENV, k)),
        "environment" => _environment_record(vault),
        "revise_loaded" => revise,
        "main_files" => main_files,
    )
    path = joinpath(_observations_dir(vault), "$token.toml")
    _atomic_bytes_write(path, sprint(io -> TOML.print(io, record; sorted=true)))
    return token
end
