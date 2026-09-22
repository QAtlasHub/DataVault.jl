# io/artifact.jl — intermediate results shared across sweep points, built once and reused.
#
# ParamIO says what an artifact IS (`[artifacts.<name>]`: the key projected onto `depends_on`,
# plus `version`). This file stores it, under a lock, OUTSIDE any run — so the next job, or the
# next run of a different config over the same axes, finds it too.

"""
    ArtifactBusy(name, identity)

Thrown by [`artifact!`](@ref) with `wait=false` when another process is building the artifact.
A scheduler catches it and runs a different cell instead of blocking a worker.
"""
struct ArtifactBusy <: Exception
    name::String
    identity::String
end

function Base.showerror(io::IO, e::ArtifactBusy)
    return print(io, "ArtifactBusy: \"$(e.name)\" is being built elsewhere ($(e.identity))")
end

_artifact_root(vault::Vault)::String =
    joinpath(vault.outdir, "artifacts", vault.spec.study.project_name)

# Sixteen hex digits of SHA-256: a directory name that fits any filesystem however many knobs
# the identity carries. A collision is caught on read, because the full identity is stored
# INSIDE the payload and compared.
function _artifact_dir(vault::Vault, name::AbstractString, identity::AbstractString)::String
    return joinpath(_artifact_root(vault), name, bytes2hex(sha256(identity))[1:16])
end

"""
    artifact_dir(vault, name, key) -> String

The directory artifact `name` of `key` lives in:
`{outdir}/artifacts/{project}/{name}/{16 hex of sha256(identity)}/`, holding `artifact.jld2`
and a human-readable `inputs.toml`. Shared by every run under `outdir`, not owned by one.
"""
function artifact_dir(vault::Vault, name, key::DataKey)::String
    id = ParamIO.artifact_identity(vault.spec, name, key)
    return _artifact_dir(vault, string(name), id)
end

_artifact_file(dir) = joinpath(dir, "artifact.jld2")
_artifact_lock(dir) = joinpath(dir, ".building")

function _read_artifact(file::AbstractString, id::AbstractString)
    stored = JLD2.load(file)
    got = get(stored, "identity", nothing)
    got == id || error(
        "artifact at $file was stored for $(repr(got)), not $(repr(id)). A 64-bit prefix " *
        "collision or a hand-moved directory; delete it to rebuild.",
    )
    return stored["value"]
end

"""
    has_artifact(vault, name, key) -> Bool

Whether artifact `name` of `key` is already built. Only a COMPLETE artifact counts: the payload
is moved into place atomically after it is written.
"""
function has_artifact(vault::Vault, name, key::DataKey)::Bool
    return isfile(_artifact_file(artifact_dir(vault, name, key)))
end

"""
    load_artifact(vault, name, key) -> value

The stored artifact; an error if it has not been built. See [`artifact!`](@ref) to build on
a miss, and [`tryload_artifact`](@ref) for absence as `nothing`.
"""
function load_artifact(vault::Vault, name, key::DataKey)
    id = ParamIO.artifact_identity(vault.spec, name, key)
    file = _artifact_file(_artifact_dir(vault, string(name), id))
    isfile(file) || error("artifact \"$name\" not built: $id")
    return _read_artifact(file, id)
end

"""
    tryload_artifact(vault, name, key) -> Union{value,Nothing}

[`load_artifact`](@ref) with absence as `nothing`. An artifact that exists and cannot be read,
or was stored under a different identity, still raises.
"""
function tryload_artifact(vault::Vault, name, key::DataKey)
    id = ParamIO.artifact_identity(vault.spec, name, key)
    file = _artifact_file(_artifact_dir(vault, string(name), id))
    isfile(file) || return nothing
    return _read_artifact(file, id)
end

"""
    artifact!(build, vault, name, key; wait=true, poll=5.0, stale_after=600.0,
              heartbeat_interval=60.0, timeout=Inf) -> value

Artifact `name` for sweep key `key`: loaded if some process already built it, built by calling
`build(akey)` otherwise, and stored for every later caller — this job, the next one, another
run under the same `outdir`.

```julia
gs = DataVault.artifact!(vault, :ground_state, key) do akey
    prepare_ground_state(param(akey, "run.U"), param(akey, "run.D"))
end
```

`akey` is `key` **projected onto the artifact's `depends_on`** (see `ParamIO.artifact_key`),
not `key`: reading a parameter the artifact did not declare fails there, instead of silently
sharing one artifact across that parameter's values.

**Concurrency.** Callers that need the same artifact at once serialise on a `link()` lock in
its directory — the same lock and reclaim rule as [`acquire_running!`](@ref). One builds; with
`wait=true` the rest poll every `poll` seconds and then load it; with `wait=false` they throw
[`ArtifactBusy`](@ref) at once. A builder that throws leaves nothing behind and releases the
lock, and the error propagates.

**Heartbeat.** While `build` runs, a small `sh` child process rewrites the lock's `heartbeat=`
every `heartbeat_interval` seconds for as long as this process is alive (`kill -0`), and a
sibling reclaims the lock after `stale_after` seconds without one. It is a separate PROCESS on
purpose: a task inside Julia does not run while a build computes without yielding — measured,
a `sleep`-driven task on an interactive thread (`julia -t 1,1`) ticked 0 times in 3 s of a busy
main thread. So `stale_after` bounds how long a crashed or walltime-killed builder blocks the
next job, independently of how long a build takes.

A `readonly` vault loads but never builds: a miss throws.
"""
function artifact!(
    build,
    vault::Vault,
    name,
    key::DataKey;
    wait::Bool=true,
    poll::Real=5.0,
    stale_after::Real=600.0,
    heartbeat_interval::Real=60.0,
    timeout::Real=Inf,
)
    heartbeat_interval < stale_after || throw(
        ArgumentError(
            "artifact!: heartbeat_interval ($heartbeat_interval) must be < stale_after " *
            "($stale_after), or a live builder is reclaimed as stale.",
        ),
    )
    n = string(name)
    id = ParamIO.artifact_identity(vault.spec, n, key)
    akey = ParamIO.artifact_key(vault.spec, n, key)
    dir = _artifact_dir(vault, n, id)
    file = _artifact_file(dir)
    lock = _artifact_lock(dir)
    t0 = time()
    announced = -Inf

    while true
        isfile(file) && return _read_artifact(file, id)
        vault.readonly && error(
            "artifact!: \"$n\" is not built and this Vault is readonly, so it will not be: $id",
        )

        owner = new_owner_token()
        acq = _acquire_lock_at!(lock, owner; stale_after=stale_after)
        if acq !== :busy
            try
                # Another process may have finished between our check and our acquire.
                isfile(file) && return _read_artifact(file, id)
                return _build_artifact!(
                    build, akey, vault, n, id, dir, file, lock, owner, heartbeat_interval
                )
            finally
                _clear_lock_at!(lock, owner)
            end
        end

        wait || throw(ArtifactBusy(n, id))
        # A wait is otherwise silent, and a stale lock can hold it for `stale_after`: say so.
        if time() - announced >= 600
            announced = time()
            @info "artifact!: waiting for \"$n\" to be built elsewhere" identity = id waited_s = round(
                time() - t0
            ) stale_after
        end
        time() - t0 > timeout && error(
            "artifact!: waited $(round(time() - t0; digits=1)) s for \"$n\" to be built " *
            "elsewhere ($id); giving up at timeout=$timeout.",
        )
        sleep(poll)
    end
end

function _build_artifact!(
    build, akey, vault, name, id, dir, file, lock, owner, heartbeat_interval
)
    hb = _start_heartbeat(lock, owner, heartbeat_interval)
    value = try
        build(akey)
    finally
        _stop_heartbeat(hb)
    end

    # `inputs.toml` first, so that when `artifact.jld2` appears — atomically, by `mv` — its
    # description is already beside it.
    a = vault.spec.artifacts[name]
    _atomic_toml_write(
        joinpath(dir, "inputs.toml"),
        Dict{String,Any}(
            "identity" => id,
            "name" => name,
            "version" => a.version,
            "params" => Dict{String,Any}(k => _toml_safe(v) for (k, v) in akey.params),
            "sample" => akey.sample,
            "created" => Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS"),
            "host" => gethostname(),
        ),
    )
    _atomic_jld2_write(file, Dict{String,Any}("value" => value, "identity" => id))
    return value
end

_toml_safe(v::Union{Bool,Integer,AbstractFloat,AbstractString}) = v
_toml_safe(v::AbstractVector) = [_toml_safe(x) for x in v]
_toml_safe(v) = repr(v)

# The heartbeat as a child process: refresh `heartbeat=` in `lock` every `interval` seconds while
# the parent pid lives and the lock is still `owner`'s. Arguments go in as `$1..$4`, never
# spliced into the script, so no path or token needs quoting. The rewrite goes through a temp file
# and `mv`, so a reader never sees half a file.
const _HEARTBEAT_SH = raw"""
pid=$1; interval=$2; lock=$3; owner=$4
while kill -0 "$pid" 2>/dev/null; do
    sleep "$interval"
    grep -qx "owner=$owner" "$lock" 2>/dev/null || exit 0
    hb=$(date '+%Y-%m-%dT%H:%M:%S')
    tmp="$lock.hb.$$"
    awk -v hb="$hb" '/^heartbeat=/ { print "heartbeat=" hb; next } { print }' "$lock" > "$tmp" &&
        mv -f "$tmp" "$lock"
done
"""

function _start_heartbeat(lock::AbstractString, owner::AbstractString, interval::Real)
    Sys.iswindows() && return nothing       # no `sh`: the lock then ages out after `stale_after`
    cmd = `sh -c $_HEARTBEAT_SH sh $(getpid()) $(interval) $lock $owner`
    return run(pipeline(cmd; stdout=devnull, stderr=devnull); wait=false)
end

function _stop_heartbeat(p)
    p === nothing && return nothing
    try
        kill(p)
        Base.wait(p)
    catch
    end
    return nothing
end
