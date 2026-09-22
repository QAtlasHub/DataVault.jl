# io/status.jl — .done / .running ステータスファイル
#
# `.running` is the single source of truth for "this key is in-flight":
# - [`acquire_running!`](@ref) is the atomic multi-master acquire,
#   implemented via POSIX `link()` for NFS-safe "create iff not exists"
#   semantics.
# - [`refresh_running!`](@ref) / [`touch_running!`](@ref) refresh the
#   heartbeat while work is in progress.
# - [`mark_done!`](@ref) removes the `.running` and writes `.done`.
# - [`clear_running!`](@ref) explicitly releases without marking done
#   (used on failure paths so the key is immediately retriable).
# - [`cleanup_stale`](@ref) reaps any `.running` whose heartbeat is
#   older than `stale_after`.
#
# Downstream packages (e.g. `SweepRunner.jl`) should not maintain
# a separate lock-file tree — `acquire_running!` IS the lock.

using Printf: @sprintf

"""
    is_done(vault, key) -> Bool
"""
is_done(vault::Vault, key::DataKey)::Bool = isfile(_done_file(vault, key))

"""
    mark_done!(vault, key; jobid=nothing, tag_value=nothing, result=nothing, observation=nothing)

Write a `.done` file for `key`. Removes the corresponding `.running` file if present.

`result` is what [`save!`](@ref) returned for this key. Pass it: it is the only way the marker can
name the bytes that were written. `observation` is the token [`observe_sources`](@ref) returned in
the process that computed the key; the marker records it, and the observation says how far that
process's loaded code was checked against its source snapshot.

Fields written (`done_version=2`), every one of them on every call:

| field | value |
|---|---|
| `jobid` | `SLURM_JOB_ID`, else the current PID, unless given |
| `completed` | local time with no zone, as before (kept for existing readers) |
| `completed_at` | the completion time in UTC, `yyyy-mm-ddTHH:MM:SSZ` |
| `git_hash` | short HEAD of the config's repo, as before (kept for existing readers) |
| `git_commit_observed`, `git_object_format` | full HEAD and object format, or `unknown` |
| `git_observed_at` | `completion`: the working tree seen now, not the code the process loaded |
| `result_sha256`, `result_file` | from `result` (file relative to the outdir), or `unknown` |
| `observation` | the token of the computing process's source observation, or `unknown` |
| `tag_value` | only when given |
"""
function mark_done!(
    vault::Vault,
    key::DataKey;
    jobid=nothing,
    tag_value=nothing,
    result=nothing,
    observation=nothing,
)
    _refuse_if_readonly(vault, "mark_done!")
    done = _done_file(vault, key)
    mkpath(dirname(done))

    jobid_str = if jobid !== nothing
        string(jobid)
    elseif haskey(ENV, "SLURM_JOB_ID")
        ENV["SLURM_JOB_ID"]
    else
        string(getpid())
    end

    completed = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    completed_at = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"
    git_hash = _git_hash(vault.config_path)
    observed = _git_observe(vault.config_path)
    sha, file = if result === nothing
        "unknown", "unknown"
    else
        String(result.sha256), relpath(result.file, vault.outdir)
    end

    lines = [
        "done_version=2",
        "jobid=$jobid_str",
        "completed=$completed",
        "completed_at=$completed_at",
        "git_hash=$git_hash",
        "git_commit_observed=$(observed.commit)",
        "git_object_format=$(observed.object_format)",
        "git_observed_at=completion",
        "result_sha256=$sha",
        "result_file=$file",
        "observation=$(observation === nothing ? "unknown" : observation)",
    ]
    tag_value !== nothing && push!(lines, "tag_value=$tag_value")

    write(done, join(lines, "\n") * "\n")

    running = _running_file(vault, key)
    isfile(running) && rm(running; force=true)
    return nothing
end

"""
    mark_running!(vault, key)

Write a `.running` sentinel with `pid`, `started`, and `heartbeat`
fields.  **Non-atomic overwrite** — for multi-master coordination use
[`acquire_running!`](@ref) instead, which guarantees exclusive
acquisition via POSIX `link()`.
"""
function mark_running!(vault::Vault, key::DataKey)
    _refuse_if_readonly(vault, "mark_running!")
    path = _running_file(vault, key)
    mkpath(dirname(path))
    now_str = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    write(path, "pid=$(getpid())\nstarted=$(now_str)\nheartbeat=$(now_str)\n")
    return nothing
end

"""
    acquire_running!(vault, key; stale_after=600.0) -> Symbol

Atomically acquire the `.running` sentinel as the *exclusive* in-flight
marker for `(vault, key)`.  This is the intended multi-master
coordination primitive — downstream packages call it in place of
maintaining a separate lock-file tree.

# Returns

| Symbol       | Meaning                                                          |
| :----------- | :--------------------------------------------------------------- |
| `:ok`        | No prior `.running` existed; fresh file created.                 |
| `:reclaimed` | Prior `.running` was stale (heartbeat age > `stale_after`);      |
|              | replaced with a fresh file owned by this caller.                 |
| `:busy`      | Another master holds a fresh `.running`; caller must not run     |
|              | work for this key.                                               |

# Atomicity

Implemented via POSIX `link()` ("create iff not exists").  A uniquely
named temp file is written, then `link(tmp, path)` publishes it under
the canonical `.running` name — `link` returns `-1` with `errno=EEXIST`
if the target already exists.  `link` is atomic on local filesystems
and on NFSv3/v4 per `man 2 link`, so two concurrent `acquire_running!`
calls on different hosts cannot both return `:ok`.

Stale-reclaim is best-effort (the `rm()` before `link()` is racy with
other reclaimers), but the final `link()` call still serialises: at
most one caller sees `:ok` / `:reclaimed`; the rest see `:busy`.

# Companion API

- [`refresh_running!`](@ref) — refresh heartbeat while holding the lock.
- [`mark_done!`](@ref) — remove `.running` and write `.done` on success.
- [`clear_running!`](@ref) — release without marking done (failure paths).
- [`cleanup_stale`](@ref) — background reaper for crashed masters.

# Ownership

This form leaves the lock UNOWNED, and the companions above are owner-blind: after a sibling
reclaims, the previous holder's `refresh_running!` still returns `true` and its `clear_running!`
still deletes, now against the reclaimer's file. Pass a [`new_owner_token`](@ref) to the
three-argument methods to close both.
"""
function acquire_running!(vault::Vault, key::DataKey; stale_after::Real=600.0)::Symbol
    return acquire_running!(vault, key, ""; stale_after=stale_after)
end

"""
    new_owner_token() -> String

A token identifying one acquisition, as `"<host>:<pid>:<nonce>"`. The nonce is what makes it
identify the ACQUISITION rather than the process: a master that loses a lock and later reacquires
the same key must not be mistaken for its earlier self by a heartbeat still in flight.
"""
function new_owner_token()::String
    return @sprintf("%s:%d:%08x", gethostname(), getpid(), rand(UInt32))
end

"""
    running_owner(vault, key) -> Union{String,Nothing}

The `owner=` token in the `.running` file, or `nothing` when the file is absent or carries no
token. A `.running` written before owner stamping, or by [`mark_running!`](@ref), has none.
"""
function running_owner(vault::Vault, key::DataKey)::Union{String,Nothing}
    lines = _running_lines(vault, key)
    lines === nothing && return nothing
    i = findfirst(l -> startswith(l, "owner="), lines)
    return i === nothing ? nothing : String(lines[i][7:end])
end

# The `.running` file's lines, or `nothing` when it cannot be read. Absent and unreadable are one
# outcome on purpose: an owner-aware verb can prove ownership from neither.
function _running_lines(vault::Vault, key::DataKey)::Union{Vector{String},Nothing}
    try
        return readlines(_running_file(vault, key))
    catch
        return nothing
    end
end

"""
    acquire_running!(vault, key, owner; stale_after=600.0) -> Symbol

[`acquire_running!`](@ref) stamping `owner=` into the `.running` file, so that
[`refresh_running!`](@ref) and [`clear_running!`](@ref) can tell this acquisition's lock from the
one a sibling took after reclaiming it. `owner` is normally [`new_owner_token`](@ref).

Returns the same `:ok` / `:reclaimed` / `:busy` as the two-argument form.
"""
function acquire_running!(
    vault::Vault, key::DataKey, owner::AbstractString; stale_after::Real=600.0
)::Symbol
    _refuse_if_readonly(vault, "acquire_running!")
    return _acquire_lock_at!(_running_file(vault, key), owner; stale_after=stale_after)
end

# The lock itself, on a path rather than a key, so that anything with a directory — a sweep
# key's status dir, an artifact's dir — takes the same `link()` lock and the same reclaim rule.
function _acquire_lock_at!(
    path::AbstractString, owner::AbstractString; stale_after::Real=600.0
)::Symbol
    mkpath(dirname(path))

    reclaimed = false
    if isfile(path)
        age = _running_age_secs(path, Dates.now())
        if age <= Float64(stale_after)
            return :busy
        end
        # Stale — attempt reclaim.  The `rm` is racy against concurrent
        # reclaimers, but the `link()` below is the final serialiser.
        try
            rm(path; force=true)
            reclaimed = true
        catch
            return :busy
        end
    end

    # Write fresh content to a unique tmp name, then `link()` it into
    # place.  `link()` fails atomically if the target already exists.
    now_str = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    tmp_name = @sprintf("%s.acq.%d.%x", basename(path), getpid(), rand(UInt32))
    tmp = joinpath(dirname(path), tmp_name)
    body = "pid=$(getpid())\nstarted=$(now_str)\nheartbeat=$(now_str)\n"
    isempty(owner) || (body *= "owner=$(owner)\n")
    write(tmp, body)

    linked = try
        ccall(:link, Cint, (Cstring, Cstring), tmp, path) == 0
    catch
        false
    end
    # Always unlink the tmp path.  On success, the inode stays alive
    # through the `path` hardlink; on failure, the tmp file is purged.
    rm(tmp; force=true)

    return linked ? (reclaimed ? :reclaimed : :ok) : :busy
end

"""
    touch_running!(vault, key)

Update the `heartbeat=` line in the `.running` file to the current time.
Called periodically (e.g. every 60 s) while computation is in progress so
that [`cleanup_stale`](@ref) can distinguish live jobs from crashed ones.

No-op if the `.running` file does not exist (already cleared or never created).
"""
function touch_running!(vault::Vault, key::DataKey)
    _refuse_if_readonly(vault, "touch_running!")
    path = _running_file(vault, key)
    isfile(path) || return nothing
    now_str = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    try
        lines = readlines(path)
        open(path, "w") do io
            for line in lines
                if startswith(line, "heartbeat=")
                    println(io, "heartbeat=$(now_str)")
                else
                    println(io, line)
                end
            end
        end
    catch
        # .running may have been removed by another master; swallow
    end
    return nothing
end

"""
    refresh_running!(vault, key) -> Bool

Refresh the `.running` heartbeat to now.  Returns `true` if the file
existed (our lock is still ours) or `false` if it was cleared
underneath us — meaning another master has reclaimed via
[`acquire_running!`](@ref) after `stale_after` elapsed, and the caller
should stop work.

Thin wrapper around [`touch_running!`](@ref) that also tells the caller
whether the heartbeat update actually landed.
"""
function refresh_running!(vault::Vault, key::DataKey)::Bool
    _refuse_if_readonly(vault, "refresh_running!")
    path = _running_file(vault, key)
    isfile(path) || return false
    touch_running!(vault, key)
    return isfile(path)
end

"""
    refresh_running!(vault, key, owner) -> Bool

[`refresh_running!`](@ref) that first checks the file is still `owner`'s. Returns `false` and
writes NOTHING when the on-disk `owner=` differs, is absent, or the file is gone, so a master that
stalled past `stale_after` learns it lost the lock instead of stamping its own clock onto the
reclaiming master's file.

The owner-blind two-argument form cannot: it returns `false` only when the file is ABSENT, which is
a window of microseconds during a reclaim.

The check is read-then-write and not atomic. A sibling reclaiming in the gap between the two is
still possible; what this closes is the case where a reclaim has ALREADY happened, which is the one
that lasts for the rest of the key. A file that cannot be read at all is `false` as well: absent
and unreadable are both "not provably ours".
"""
function refresh_running!(vault::Vault, key::DataKey, owner::AbstractString)::Bool
    _refuse_if_readonly(vault, "refresh_running!")
    return _refresh_lock_at!(_running_file(vault, key), owner)
end

function _refresh_lock_at!(path::AbstractString, owner::AbstractString)::Bool
    lines = _lock_lines(path)
    lines === nothing && return false
    any(l -> l == "owner=$(owner)", lines) || return false

    now_str = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    open(path, "w") do io
        for line in lines
            println(io, startswith(line, "heartbeat=") ? "heartbeat=$(now_str)" : line)
        end
    end
    return true
end

# A lock file's lines, or `nothing` when it cannot be read — absent and unreadable alike.
function _lock_lines(path::AbstractString)::Union{Vector{String},Nothing}
    try
        return readlines(path)
    catch
        return nothing
    end
end

"""
    running_age_secs(vault, key) -> Float64

Age in seconds of the `.running` file's most recent heartbeat.  Returns
`Inf` if no `.running` file exists.  The same computation is used
internally by [`acquire_running!`](@ref) and [`cleanup_stale`](@ref).
"""
function running_age_secs(vault::Vault, key::DataKey)::Float64
    path = _running_file(vault, key)
    isfile(path) || return Inf
    return _running_age_secs(path, Dates.now())
end

"""
    running_heartbeat(vault, key) -> Union{DateTime, Nothing}

Read the `heartbeat=` timestamp from the `.running` file. Returns `nothing`
if the file does not exist or the timestamp cannot be parsed.
"""
function running_heartbeat(vault::Vault, key::DataKey)::Union{DateTime,Nothing}
    path = _running_file(vault, key)
    isfile(path) || return nothing
    try
        for line in eachline(path)
            if startswith(line, "heartbeat=")
                return Dates.DateTime(line[11:end], "yyyy-mm-ddTHH:MM:SS")
            end
        end
    catch
    end
    return nothing
end

"""
    clear_running!(vault, key)

Remove the `.running` sentinel for `key`. Idempotent — safe to call when
the file has already been removed (e.g. by [`mark_done!`](@ref)).
"""
function clear_running!(vault::Vault, key::DataKey)
    _refuse_if_readonly(vault, "clear_running!")
    path = _running_file(vault, key)
    isfile(path) && rm(path; force=true)
    return nothing
end

"""
    clear_running!(vault, key, owner) -> Bool

[`clear_running!`](@ref) that removes the file only when its `owner=` is `owner`. Returns whether
it removed anything.

The two-argument form deletes regardless of owner, so a master releasing AFTER losing its lock
deletes the reclaiming master's live `.running` and re-opens double execution. An unstamped file is
not removed either: it cannot be shown to be ours, and `stale_after` will reclaim it.

Read-then-unlink, so the same non-atomic gap as [`refresh_running!`](@ref) applies. The difference
from the owner-blind form is unbounded-to-microseconds, not to zero.
"""
function clear_running!(vault::Vault, key::DataKey, owner::AbstractString)::Bool
    _refuse_if_readonly(vault, "clear_running!")
    return _clear_lock_at!(_running_file(vault, key), owner)
end

function _clear_lock_at!(path::AbstractString, owner::AbstractString)::Bool
    lines = _lock_lines(path)
    lines === nothing && return false
    any(l -> l == "owner=$(owner)", lines) || return false
    rm(path; force=true)
    return true
end

"""
    is_running(vault, key) -> Bool
"""
is_running(vault::Vault, key::DataKey)::Bool = isfile(_running_file(vault, key))
