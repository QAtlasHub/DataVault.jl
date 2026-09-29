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
# - [`start_heartbeat`](@ref) keeps a held lock fresh from a child process.
#
# The protocol itself (age, reclaim, in-place heartbeat) is in `io/lock.jl`.
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
    write(done, _done_body(vault; jobid, tag_value, result, observation))

    running = _running_file(vault, key)
    isfile(running) && rm(running; force=true)
    return nothing
end

# The `.done` marker's content. Built BEFORE the owner form takes its lock out of circulation, so
# the moment the key carries neither lock nor marker is two renames long rather than the git calls
# this makes: with those in the gap, a sibling master started the key again (in-process masters on
# one vault, 2 of 6 keys computed twice).
function _done_body(
    vault::Vault; jobid=nothing, tag_value=nothing, result=nothing, observation=nothing
)
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
    return join(lines, "\n") * "\n"
end

"""
    mark_done!(vault, key, owner; jobid=nothing, tag_value=nothing, result=nothing,
               observation=nothing) -> Bool

[`mark_done!`](@ref) for the holder of an owner-stamped lock: writes the `.done` marker only if
the `.running` file is still `owner`'s, and returns whether it did.

The two-argument form deletes whatever `.running` is there and commits regardless. A master that
stalled past `stale_after` and lost its key to a reclaim would then delete the reclaimer's live
lock and put its own result in the marker; here it gets `false`, nothing is written, and the
reclaimer's lock is untouched.

The marker is written to a temporary file first. Then the lock is moved aside (a `rename`) and
what moved is checked to be `owner`'s — a reclaim landing between the owner check and the move is
put back — and the marker is renamed into place. The key carries neither lock nor marker only
between those two renames, and a sibling that acquires in that gap still finds the marker when it
re-checks `is_done` after acquiring.
"""
function mark_done!(vault::Vault, key::DataKey, owner::AbstractString; kwargs...)::Bool
    _refuse_if_readonly(vault, "mark_done!")
    # Before this method existed a third positional argument was a MethodError. A job id or a tag
    # passed there by mistake would now be an owner that never matches, and the commit a silent
    # `false`; a token always has the `host:pid:nonce` shape, so anything else is refused loudly.
    count(==(':'), owner) >= 2 || throw(
        ArgumentError(
            "mark_done!: the third argument is an owner token (`host:pid:nonce`, from " *
            "new_owner_token), got $(repr(owner)). jobid and tag_value are keywords.",
        ),
    )
    done = _done_file(vault, key)
    mkpath(dirname(done))
    tmp = _write_unique(done, "tmp", _done_body(vault; kwargs...))
    try
        aside = _take_own_lock_aside!(_running_file(vault, key), owner)
        aside === nothing && return false
        Base.rename(tmp, done)
        rm(aside; force=true)
        return true
    finally
        rm(tmp; force=true)
    end
end

"""
    mark_running!(vault, key)

Write a `.running` sentinel with `heartbeat_unix`, `heartbeat`, `pid` and
`started` fields.  **Non-atomic overwrite** — for multi-master coordination use
[`acquire_running!`](@ref) instead, which guarantees exclusive
acquisition via POSIX `link()`.
"""
function mark_running!(vault::Vault, key::DataKey)
    _refuse_if_readonly(vault, "mark_running!")
    path = _running_file(vault, key)
    mkpath(dirname(path))
    write(path, _lock_body(""))
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

A stale lock is reclaimed under a second link-lock (`.running.reclaim`),
so reclaimers take turns, and the stale file is moved aside and compared
with what was judged stale before it is removed: a holder that beat in the
meantime keeps its lock. At most one caller sees `:ok` / `:reclaimed`.

# Age

A lock's age is read from `heartbeat_unix=` (seconds since the epoch, so the
writer's and reader's time zones do not enter). A lock written by an older
DataVault has only `heartbeat=` (local time, whole seconds) and is read as
before.

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
    content = _read_lock(_running_file(vault, key))
    content === nothing && return nothing
    for line in eachsplit(content, '\n')
        startswith(line, "owner=") && return String(line[7:end])
    end
    return nothing
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

"""
    touch_running!(vault, key)

Update the heartbeat (`heartbeat_unix=` and `heartbeat=`) in the `.running` file to the current
time.
Called periodically (e.g. every 60 s) while computation is in progress so
that [`cleanup_stale`](@ref) can distinguish live jobs from crashed ones.

No-op if the `.running` file does not exist (already cleared or never created).
"""
function touch_running!(vault::Vault, key::DataKey)
    _refuse_if_readonly(vault, "touch_running!")
    _beat_lock_at!(_running_file(vault, key), nothing)
    return nothing
end

"""
    refresh_running!(vault, key) -> Bool

Refresh the `.running` heartbeat to now.  Returns `true` if the file
existed (our lock is still ours) or `false` if it was cleared
underneath us — meaning another master has reclaimed via
[`acquire_running!`](@ref) after `stale_after` elapsed, and the caller
should stop work.

The same heartbeat as [`touch_running!`](@ref), and whether it landed.
"""
function refresh_running!(vault::Vault, key::DataKey)::Bool
    _refuse_if_readonly(vault, "refresh_running!")
    path = _running_file(vault, key)
    return _beat_lock_at!(path, nothing)
end

"""
    refresh_running!(vault, key, owner) -> Bool

[`refresh_running!`](@ref) that first checks the file is still `owner`'s. Returns `false` and
writes NOTHING when the on-disk `owner=` differs, is absent, or the file is gone, so a master that
stalled past `stale_after` learns it lost the lock instead of stamping its own clock onto the
reclaiming master's file.

The owner-blind two-argument form cannot: it returns `false` only when the file is ABSENT, which is
a window of microseconds during a reclaim.

The heartbeat is written through a descriptor opened on the lock's inode, after the owner was read
from that same descriptor and while the name still points at it. A reclaim landing after the check
therefore writes to the inode it took out of circulation, never to the reclaimer's file. A file
that cannot be read at all is `false` as well: absent and unreadable are both "not provably ours".

A holder whose work may not yield for `stale_after` should not rely on calling this from a task:
use [`start_heartbeat`](@ref).
"""
function refresh_running!(vault::Vault, key::DataKey, owner::AbstractString)::Bool
    _refuse_if_readonly(vault, "refresh_running!")
    return _beat_lock_at!(_running_file(vault, key), owner)
end

"""
    start_heartbeat(vault, key, owner; interval=60.0) -> HeartbeatHandle

Keep `owner`'s `.running` lock fresh from a CHILD process until [`stop_heartbeat`](@ref), until
this process exits, or until the lock is released or reclaimed, whichever is first.

A heartbeat task inside the holder is starved by work that does not yield — a long BLAS call, a
tight loop — whatever `-t` is: measured with `-t 1`, `-t 2` and `-t 2,1`, the heartbeat did not
move for the whole of such a loop, and a live holder's key was reclaimed. The child is a small `sh`
loop that checks the parent is alive (`kill -0`) and that the lock's name still points at the
inode it opened, then rewrites the heartbeat header in place.

It does not tell the holder that the lock was lost; check with [`running_owner`](@ref) before
committing, and commit with the owner form of [`mark_done!`](@ref), which refuses a lost key.
[`heartbeat_alive`](@ref) says whether it is still beating, and [`stop_heartbeat`](@ref) warns if
it stopped while the lock was still held.

The child needs Linux: it rewrites the header through `/dev/fd`, which re-opens the file there
with its own offset, and BSD / macOS share the descriptor's instead. Elsewhere — and for a lock
written by a DataVault older than 0.8.9 — the heartbeat is a task, which beats only while the
holder yields. `interval <= 0` gives an inert handle, and the lock ages out after `stale_after`.
"""
function start_heartbeat(
    vault::Vault, key::DataKey, owner::AbstractString; interval::Real=60.0
)::HeartbeatHandle
    _refuse_if_readonly(vault, "start_heartbeat")
    return _start_lock_heartbeat(_running_file(vault, key), owner, interval)
end

"""
    running_age_secs(vault, key) -> Float64

Age in seconds of the `.running` file's most recent heartbeat.  Returns
`Inf` if no `.running` file exists.  The same computation is used
internally by [`acquire_running!`](@ref) and [`cleanup_stale`](@ref).
"""
function running_age_secs(vault::Vault, key::DataKey)::Float64
    path = _running_file(vault, key)
    age = _lock_age(path)
    return age === nothing ? Inf : age
end

"""
    running_heartbeat(vault, key) -> Union{DateTime, Nothing}

Read the `heartbeat=` timestamp from the `.running` file. Returns `nothing`
if the file does not exist or the timestamp cannot be parsed.
"""
function running_heartbeat(vault::Vault, key::DataKey)::Union{DateTime,Nothing}
    content = _read_lock(_running_file(vault, key))
    return content === nothing ? nothing : _heartbeat_local(content)
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

The file is moved aside (a `rename`) and what moved is checked to be `owner`'s before it is
removed; a lock reclaimed between the owner check and the move is put back.
"""
function clear_running!(vault::Vault, key::DataKey, owner::AbstractString)::Bool
    _refuse_if_readonly(vault, "clear_running!")
    return _release_lock_at!(_running_file(vault, key), owner)
end

"""
    is_running(vault, key) -> Bool
"""
is_running(vault::Vault, key::DataKey)::Bool = isfile(_running_file(vault, key))
