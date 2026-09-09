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
    mark_done!(vault, key; jobid=nothing, tag_value=nothing)

Write a `.done` file for `key`. Removes the corresponding `.running` file if present.

Fields written: `jobid`, `completed`, `git_hash`, and optionally `tag_value`.
`jobid` defaults to `SLURM_JOB_ID` env var, then current PID.
"""
function mark_done!(vault::Vault, key::DataKey; jobid=nothing, tag_value=nothing)
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
    git_hash = _git_hash(vault.config_path)

    lines = ["jobid=$jobid_str", "completed=$completed", "git_hash=$git_hash"]
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
"""
function acquire_running!(vault::Vault, key::DataKey; stale_after::Real=600.0)::Symbol
    path = _running_file(vault, key)
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
    write(tmp, "pid=$(getpid())\nstarted=$(now_str)\nheartbeat=$(now_str)\n")

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
    path = _running_file(vault, key)
    isfile(path) || return false
    touch_running!(vault, key)
    return isfile(path)
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
    path = _running_file(vault, key)
    isfile(path) && rm(path; force=true)
    return nothing
end

"""
    is_running(vault, key) -> Bool
"""
is_running(vault::Vault, key::DataKey)::Bool = isfile(_running_file(vault, key))
