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
    _refuse_if_readonly(vault, "mark_done!")
    done = _done_file(vault, key)
    mkpath(dirname(done))
    write(done, _done_body(vault, key; jobid=jobid, tag_value=tag_value))
    running = _running_file(vault, key)
    isfile(running) && rm(running; force=true)
    return nothing
end

# Everything a `.done` records, built BEFORE anything is written. `_git_hash` spawns a `git`
# subprocess, so leaving it between an ownership check and the act would make that gap a
# subprocess wide.
function _done_body(vault::Vault, key::DataKey; jobid=nothing, tag_value=nothing)::String
    jobid_str = if jobid !== nothing
        string(jobid)
    elseif haskey(ENV, "SLURM_JOB_ID")
        ENV["SLURM_JOB_ID"]
    else
        string(getpid())
    end
    lines = [
        "jobid=$jobid_str",
        "completed=$(Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS"))",
        "git_hash=$(_git_hash(vault.config_path))",
    ]
    tag_value !== nothing && push!(lines, "tag_value=$tag_value")
    return join(lines, "\n") * "\n"
end

"""
    mark_done!(vault, key, owner; jobid=nothing, tag_value=nothing) -> Bool

[`mark_done!`](@ref) that refuses unless the `.running` lock is still `owner`'s, writing neither
`.done` nor the deletion when it is not.

The check is repeated immediately before each write, so the gap is a syscall rather than the
`mkpath` plus `git` subprocess that delegating to the two-argument form would put there. It is
still a gap: a reclaim inside it is not detected, and an inode number the filesystem has recycled
reads as a match. This narrows the hazard; it does not remove it.

The two-argument form removes whatever `.running` is there and commits its `.done` regardless of
who holds the lock. A master that stalled past `stale_after`, lost the key to a sibling, and then
finished its own now-superseded computation therefore deletes the SIBLING's live lock and commits
over it. No race is needed for that, only a slow key, so a per-key loop that ends in `mark_done!`
wants this form.

Returns whether it committed.
"""
function mark_done!(
    vault::Vault, key::DataKey, owner::AbstractString; jobid=nothing, tag_value=nothing
)::Bool
    _refuse_if_readonly(vault, "mark_done!")
    running = _running_file(vault, key)
    io = try
        open(running, "r")
    catch e
        e isa InterruptException && rethrow()
        return false
    end
    ours, ino = try
        (any(l -> l == "owner=$(owner)", readlines(io)), stat(io).inode)
    catch e
        e isa InterruptException && rethrow()
        (false, UInt64(0))
    finally
        _close_quietly(io)
    end
    ours || return false

    # Built first, so the re-check below is adjacent to the writes rather than a `git` subprocess
    # away from them. Delegating to the two-argument form instead put every filesystem operation
    # it does between the check and its owner-blind `rm`.
    body = _done_body(vault, key; jobid=jobid, tag_value=tag_value)
    done = _done_file(vault, key)
    mkpath(dirname(done))
    _still_inode(running, ino) || return false
    write(done, body)
    _still_inode(running, ino) && rm(running; force=true)
    return true
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

# `close` can throw: NFS defers write-back errors to it. A verb that promises a `Bool` must not
# let that escape, and a `finally close(io)` is a SIBLING of the local `catch`, so it does.
function _close_quietly(io)
    try
        close(io)
    catch e
        e isa InterruptException && rethrow()
        @warn "closing a .running descriptor failed" exception = e
    end
    return nothing
end

"""
    _still_inode(path, ino) -> Bool

Whether `path` still resolves to the inode a token was read from. A reclaim publishes by unlinking
the name and `link`ing a new file onto it, so this is what stops a verb from acting on the file
that REPLACED the one it inspected. Unreadable counts as "no", since the answer cannot be shown.
"""
function _still_inode(path::AbstractString, ino::UInt64)::Bool
    try
        return stat(path).inode == ino
    catch e
        e isa InterruptException && rethrow()
        return false
    end
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
    catch e
        e isa InterruptException && rethrow()
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
        catch e
            e isa InterruptException && rethrow()
            # `force=true` does not throw for "already gone", so this is a real fault. Reported
            # because a persistent one returns `:busy` forever, which reads as healthy contention.
            @warn "stale .running could not be reclaimed" path exception = e
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
    catch e
        e isa InterruptException && rethrow()
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
    catch e
        e isa InterruptException && rethrow()
        # A removal by another master is ordinary and silent. Anything else means the heartbeat
        # this was called to write did not land, and if the truncating `open` had already run, the
        # file is now missing it or half-written.
        isfile(path) &&
            @warn "heartbeat write failed; .running may be truncated" path exception = e
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

The owner-blind two-argument form returns `false` only when the file is ABSENT, which is a window
of microseconds during a reclaim.

The rewrite goes to a temp file and is `rename`d into place, and only while the name still carries
the inode the token was read from. A write that fails partway therefore leaves the lock untouched,
rather than owned by nobody, refreshable by nobody, and fresh by mtime until `stale_after` expires.

The inode check is not atomic, and an inode number the filesystem has recycled reads as a match, so
a reclaim can still slip through. This narrows the hazard; it does not remove it.

A file that cannot be read at all is `false` as well: absent and unreadable are both "not provably
ours".
"""
function refresh_running!(vault::Vault, key::DataKey, owner::AbstractString)::Bool
    _refuse_if_readonly(vault, "refresh_running!")
    now_str = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    path = _running_file(vault, key)
    io = try
        open(path, "r")
    catch e
        e isa InterruptException && rethrow()
        return false                       # absent or unreadable: not provably ours
    end
    lines, ino = try
        (readlines(io), stat(io).inode)
    catch e
        e isa InterruptException && rethrow()
        (String[], UInt64(0))
    finally
        _close_quietly(io)
    end
    any(l -> l == "owner=$(owner)", lines) || return false

    # Written to a temp file and renamed, never truncated in place. A write that fails partway
    # through an in-place rewrite leaves a lock owned by nobody, refreshable by nobody, and fresh
    # by mtime until `stale_after`; rename either replaces the file whole or does nothing.
    tmp = @sprintf("%s.hb.%d.%x", path, getpid(), rand(UInt32))
    try
        open(tmp, "w") do out
            for line in lines
                println(out, startswith(line, "heartbeat=") ? "heartbeat=$(now_str)" : line)
            end
        end
        # Only if the name still carries the inode our token came from: a reclaim since the read
        # relinked it, and renaming onto that would destroy the winner's lock.
        _still_inode(path, ino) || return false
        mv(tmp, path; force=true)
    catch e
        e isa InterruptException && rethrow()
        return false
    finally
        rm(tmp; force=true)
    end
    return true
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
    catch e
        e isa InterruptException && rethrow()
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

The unlink is guarded by the INODE the token was read from, not by the path alone, so a name
relinked to the reclaimer's file since the read is left alone.

A narrowing, not a guarantee, in two ways: `stat`-then-unlink is not atomic, and an inode NUMBER
the filesystem has recycled onto the reclaimer's new file reads as a match. The owner-blind form
has no guard at all in the other direction, because it always deletes.
"""
function clear_running!(vault::Vault, key::DataKey, owner::AbstractString)::Bool
    _refuse_if_readonly(vault, "clear_running!")
    path = _running_file(vault, key)
    io = try
        open(path, "r")
    catch e
        e isa InterruptException && rethrow()
        return false
    end
    ours, ino = try
        (any(l -> l == "owner=$(owner)", readlines(io)), stat(io).inode)
    catch e
        e isa InterruptException && rethrow()
        (false, UInt64(0))
    finally
        _close_quietly(io)
    end
    ours || return false
    # The name may have been relinked to the reclaimer's file since the read. Unlink only while it
    # still resolves to the inode that carried our token.
    try
        _still_inode(path, ino) || return false
        rm(path; force=true)
    catch e
        e isa InterruptException && rethrow()
        return false
    end
    return true
end

"""
    is_running(vault, key) -> Bool
"""
is_running(vault::Vault, key::DataKey)::Bool = isfile(_running_file(vault, key))
