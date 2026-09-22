# provenance/observe.jl — what the code a process could see looked like, observed once.
#
# An observation keeps two claims apart:
#
#   * a SOURCE SNAPSHOT: every file of each source root as (path, type, mode, size, SHA-256),
#     identified by the SHA-256 of that inventory, `src1-<hex>`, and stored once per vault;
#   * its BINDING to the code the process runs: `unverified`, unless every package the process
#     loaded from a root was checked against the snapshot through its precompile cache header.
#
# Nothing here says the snapshot is the code that ran. It says what was on disk, when, and how far
# the process's loaded code was checked against it. File names under `.datavault/` must never end
# in `.log.toml`: discovery walks the whole tree for that suffix.

const SOURCE_RECIPE = "src1"
const OBSERVATION_VERSION = 1
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

The binding an observation can claim, from each root's loaded status. `loaded-matches-disk` only
when the config's repository (where the study's code lives) was loaded from and matched, every
other root that was loaded from matched, Revise is not loaded, and no file included into `Main`
lies inside a root (code defined there cannot be checked).
`loaded-differs-from-disk` when a loaded package's sources differ from the snapshot. Otherwise
`unverified`, with the reasons.
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
    return isempty(reasons) ? "loaded-matches-disk" : "unverified", reasons
end

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
    observe_sources(vault; phase = "run-start", process = Dict(), hash_limit = 64 MiB) -> token

Observe the source roots this process can see — the config's repository and every `path`
dependency of the active environment — store the snapshot (once per distinct content) and an
observation record, and return the record's token for [`mark_done!`](@ref)'s `observation`.

The record says when (`observed_at`, `phase`), where (host, pid, and whatever `process` adds, such
as a worker id), which snapshot (`source`), each root's git HEAD and whether it was dirty, the Julia
build and a fixed list of environment variables, and the **binding**: how far the code this process
has loaded was checked against the snapshot (see [`binding_of`](@ref)). File contents are stored
only for `.jl` and `.toml` files; every other file is inventoried by size and digest.
"""
function observe_sources(
    vault::Vault;
    phase::AbstractString="run-start",
    process::AbstractDict=Dict{String,Any}(),
    hash_limit::Integer=DEFAULT_HASH_LIMIT,
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
        "env" => Dict{String,Any}(k => ENV[k] for k in ENV_RECORDED if haskey(ENV, k)),
        "environment" => _environment_record(vault),
        "revise_loaded" => revise,
        "main_files" => main_files,
    )
    path = joinpath(_observations_dir(vault), "$token.toml")
    _atomic_bytes_write(path, sprint(io -> TOML.print(io, record; sorted=true)))
    return token
end
