# io/lock.jl — the lock protocol under `.running` and an artifact's `.lock`
#
# A lock is a file created with `link()` ("create iff absent"). Everything here is on a PATH so
# that a sweep key's status dir and an artifact's dir share one protocol. Four rules, each closing
# a hole that was measured before it was closed:
#
# 1. Age comes from `heartbeat_unix=`, seconds since the epoch. The older `heartbeat=` line is
#    local time with no zone and whole seconds: a lock written in New York read 13 h old in Tokyo
#    and was taken from a live holder, and every lock read up to 1 s older than it was. The line
#    is still written, so a reader that knows only it keeps working.
# 2. The two heartbeat lines lead the file at a fixed width, so a heartbeat rewrites them IN PLACE
#    through a descriptor opened on the lock's inode. Rewriting by path (write a temp, `mv` it
#    over) could land on a lock someone else had just taken.
# 3. A reclaim is serialised by a second link-lock (`<lock>.reclaim`), and the file it removes is
#    moved aside first and compared with what was judged stale. Check-then-`rm` let two reclaimers
#    both win (1 round in 300 on a local disk).
# 4. The heartbeat runs in a CHILD process ([`start_heartbeat`](@ref)). A task in the holder is
#    starved by work that never yields: with `-t 1`, `-t 2` and `-t 2,1` alike, the heartbeat did
#    not move for the whole of a busy loop, and a live holder's key was taken.

using Printf: @sprintf

# Future heartbeats within this margin (seconds) are attributed to multi-host clock skew and
# treated as fresh; beyond it the timestamp is taken as corrupt and the file's mtime decides.
const _HEARTBEAT_FUTURE_SKEW = 300.0

# A reclaimer that died holding `<lock>.reclaim` must not block reclaim for good. A reclaim takes
# milliseconds, so a mutex this old was abandoned.
const _RECLAIM_MUTEX_STALE = 30.0

# Temporary and moved-aside files (`<lock>.acq.<pid>.<hex>`, `.stale.…`, `.done.…`, `.tmp.…`, the
# `.reclaim` mutex) live for milliseconds; one this old was left by a process that died mid-step.
const _LEFTOVER_AGE = 60.0

# `heartbeat_unix=` + 17 (10 integer digits until 2286, a point, 6 decimals) + `\n`, and
# `heartbeat=` + 19 + `\n`: 33 + 30.
const _HB_HEADER_BYTES = 63

const _LOCAL_FMT = "%Y-%m-%dT%H:%M:%S"

function _hb_header(t::Float64=time())::String
    h =
        "heartbeat_unix=" *
        @sprintf("%017.6f", t) *
        "\n" *
        "heartbeat=" *
        Libc.strftime(_LOCAL_FMT, t) *
        "\n"
    ncodeunits(h) == _HB_HEADER_BYTES ||
        error("heartbeat header is not fixed width: $(repr(h))")
    return h
end

function _lock_body(owner::AbstractString, t::Float64=time())::String
    body = _hb_header(t) * "pid=$(getpid())\nstarted=$(Libc.strftime(_LOCAL_FMT, t))\n"
    isempty(owner) || (body *= "owner=$(owner)\n")
    return body
end

# A lock file's content, or `nothing` when it cannot be read — absent and unreadable alike.
function _read_lock(path::AbstractString)::Union{String,Nothing}
    return try
        read(path, String)
    catch
        nothing
    end
end

# The `heartbeat_unix=` value, or `nothing` when absent or unparsable.
function _heartbeat_unix(content::AbstractString)::Union{Float64,Nothing}
    for line in eachsplit(content, '\n')
        startswith(line, "heartbeat_unix=") || continue
        t = tryparse(Float64, line[16:end])
        return (t === nothing || !isfinite(t)) ? nothing : t
    end
    return nothing
end

# The `heartbeat=` value (local time, no zone), or `nothing` when absent or unparsable.
function _heartbeat_local(content::AbstractString)::Union{DateTime,Nothing}
    for line in eachsplit(content, '\n')
        startswith(line, "heartbeat=") || continue
        return tryparse(DateTime, line[11:end], dateformat"yyyy-mm-ddTHH:MM:SS")
    end
    return nothing
end

# Seconds since the lock's last heartbeat, or `nothing` when there is no file to read.
function _lock_age(path::AbstractString)::Union{Float64,Nothing}
    content = _read_lock(path)
    return content === nothing ? nothing : _lock_age(path, content)
end

function _lock_age(path::AbstractString, content::AbstractString)::Float64
    t = _heartbeat_unix(content)
    t === nothing || return _age_or_fallback(path, time() - t)
    # Written before `heartbeat_unix=`: local time, whole seconds, the reader's zone assumed.
    hb = _heartbeat_local(content)
    hb === nothing || return _age_or_fallback(path, Dates.value(Dates.now() - hb) / 1000.0)
    return _mtime_age(path)
end

# A small negative age is clock skew between hosts and reads as fresh. A large one would make the
# lock look fresh forever — a key nobody can reclaim — so it falls back to the file's mtime.
function _age_or_fallback(path::AbstractString, age::Float64)::Float64
    age >= 0.0 && return age
    age > -_HEARTBEAT_FUTURE_SKEW && return 0.0
    return _mtime_age(path)
end

_mtime_age(path::AbstractString)::Float64 = (m=mtime(path); m == 0.0 ? Inf : time() - m)

# `link(2)`: true iff `dst` did not exist and now names `src`'s inode.
function _link(src::AbstractString, dst::AbstractString)::Bool
    return try
        ccall(:link, Cint, (Cstring, Cstring), src, dst) == 0
    catch
        false
    end
end

function _aside_name(path::AbstractString, what::AbstractString)
    return @sprintf("%s.%s.%d.%08x", path, what, getpid(), rand(UInt32))
end

function _write_unique(
    path::AbstractString, what::AbstractString, body::AbstractString
)::String
    tmp = _aside_name(path, what)
    write(tmp, body)
    return tmp
end

# Move the file at `path` aside and keep it there iff `keep(content)` holds for what moved.
# Returns the aside name, `:absent` when there was nothing to move, or `:refused` when what moved
# failed `keep` and was put back. Moving first and judging what moved is what makes the judgement
# about the file actually taken, not about one read a moment earlier.
function _move_aside_if(keep::Function, path::AbstractString, what::AbstractString)
    aside = _aside_name(path, what)
    try
        Base.rename(path, aside)
    catch
        return :absent
    end
    keep(something(_read_lock(aside), "")) && return aside
    _put_back!(aside, path)
    return :refused
end

function _put_back!(aside::AbstractString, path::AbstractString)
    if _link(aside, path) || ispath(path)
        # Back in place — or someone took the name in the gap, and the lock we moved belongs to a
        # holder that finds out through its owner check. Either way `aside` is a spare name.
        rm(aside; force=true)
    else
        # Neither: the link failed for another reason (permissions, I/O). Removing `aside` would
        # destroy the only copy of a live holder's lock, so it is left where it is.
        @warn "lock: could not put a lock back after moving it aside; left at $aside" path
    end
    return nothing
end

function _acquire_lock_at!(
    path::AbstractString, owner::AbstractString; stale_after::Real=600.0
)::Symbol
    mkpath(dirname(path))
    tmp = _write_unique(path, "acq", _lock_body(owner))
    try
        _link(tmp, path) && return :ok
        age = _lock_age(path)
        # Released between the link and the read: one more try, and a loss to whoever took it.
        age === nothing && return _link(tmp, path) ? :ok : :busy
        age <= Float64(stale_after) && return :busy
        return _reclaim_lock_at!(path, tmp, Float64(stale_after))
    finally
        rm(tmp; force=true)
    end
end

# Replace the stale lock at `path` with `fresh`. Holds `<path>.reclaim` throughout, so reclaimers
# are serialised; a plain acquirer can still win the gap between our removal and our link, and
# then we lose, which is correct.
function _reclaim_lock_at!(
    path::AbstractString, fresh::AbstractString, stale_after::Float64
)
    mutex = path * ".reclaim"
    _take_mutex!(mutex) || return :busy
    try
        seen = _read_lock(path)
        seen === nothing && return _link(fresh, path) ? :ok : :busy
        # Judged again under the mutex: the holder may have beaten, or the lock been replaced.
        _lock_age(path, seen) <= stale_after && return :busy
        # What moves must be what was judged stale: a holder that beat in between, or a lock
        # released and taken afresh, is put back.
        moved = _move_aside_if(==(seen), path, "stale")
        moved === :absent && return _link(fresh, path) ? :ok : :busy
        moved === :refused && return :busy
        rm(moved; force=true)
        # A reclaimed lock's holder died; so may have its temporaries, and earlier reclaimers'.
        _sweep_lock_leftovers(dirname(path))
        return _link(fresh, path) ? :reclaimed : :busy
    finally
        rm(mutex; force=true)
    end
end

function _take_mutex!(mutex::AbstractString)::Bool
    tmp = _write_unique(mutex, "acq", _hb_header() * "pid=$(getpid())\n")
    try
        _link(tmp, mutex) && return true
        age = _lock_age(mutex)
        age === nothing && return _link(tmp, mutex)
        age > _RECLAIM_MUTEX_STALE || return false
        # Abandoned. Moving it aside is atomic, so of several processes that find it abandoned,
        # one removes it and the rest go on to compete for the link.
        aside = _aside_name(mutex, "stale")
        try
            Base.rename(mutex, aside)
            rm(aside; force=true)
        catch
        end
        return _link(tmp, mutex)
    finally
        rm(tmp; force=true)
    end
end

# A name `_aside_name` / `_write_unique` makes, or a reclaim mutex.
const _LEFTOVER_RE = r"\.(?:acq|stale|done|tmp)\.\d+\.[0-9a-f]{8}$|\.reclaim$"

# Remove temporaries and moved-aside copies in `dir` older than `older_than` seconds. They are
# removed within milliseconds unless the process that made them died; left alone they accumulate
# for the life of the vault. Returns how many were removed.
function _sweep_lock_leftovers(dir::AbstractString; older_than::Real=_LEFTOVER_AGE)::Int
    n = 0
    for f in (isdir(dir) ? readdir(dir) : String[])
        occursin(_LEFTOVER_RE, f) || continue
        p = joinpath(dir, f)
        _mtime_age(p) > older_than || continue
        try
            rm(p)
            n += 1
        catch
        end
    end
    return n
end

# Whether the lock at `path` is `owner`'s. The token carries a per-acquisition nonce and a lock's
# `owner=` line never changes, so a match is this acquisition's lock and not an earlier one.
function _owns_lock_at(path::AbstractString, owner::AbstractString)::Bool
    content = _read_lock(path)
    return content !== nothing && _has_owner_line(content, owner)
end

function _has_owner_line(content::AbstractString, owner::AbstractString)::Bool
    return any(==("owner=$(owner)"), eachsplit(content, '\n'))
end

# Refresh the heartbeat of the lock at `path`, through a descriptor on its inode. With `owner`,
# only that owner's lock, and only while `path` still names the inode we opened: a lock reclaimed
# since is someone else's file under the same name. Nothing is ever truncated: a failed write
# leaves the lock's other lines where they were.
function _beat_lock_at!(path::AbstractString, owner::Union{AbstractString,Nothing})::Bool
    io = try
        open(path, "r+")
    catch
        return false
    end
    try
        content = read(io, String)
        owner === nothing || _has_owner_line(content, owner) || return false
        _same_inode(io, path) || return false
        t = time()
        if startswith(content, "heartbeat_unix=") && ncodeunits(content) >= _HB_HEADER_BYTES
            seekstart(io)
            write(io, _hb_header(t))                 # the fixed-width header, in place
        else
            # Written before the header existed: its `heartbeat=` line is fixed width too, so it is
            # rewritten where it stands. The lock keeps its format; readers read it as before.
            r = findfirst(
                r"(?:^|\n)heartbeat=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\n|$)", content
            )
            r === nothing && return false
            at = content[first(r)] == '\n' ? first(r) : first(r) - 1
            seek(io, at)
            write(io, "heartbeat=" * Libc.strftime(_LOCAL_FMT, t))
        end
        flush(io)
        return true
    catch
        return false
    finally
        close(io)
    end
end

function _same_inode(io::IO, path::AbstractString)::Bool
    a = stat(io)
    b = stat(path)
    return b.inode != 0 && a.inode == b.inode && a.device == b.device
end

# Take the lock at `path` out of circulation iff it is `owner`'s. Returns the name it was moved
# to, or `nothing`. The owner is read first so that a non-owner does not move a live lock aside
# even for a moment; the move itself is then checked, since a reclaim can land between the two.
function _take_own_lock_aside!(path::AbstractString, owner::AbstractString)
    _owns_lock_at(path, owner) || return nothing
    moved = _move_aside_if(c -> _has_owner_line(c, owner), path, "done")
    return moved isa Symbol ? nothing : moved
end

function _release_lock_at!(path::AbstractString, owner::AbstractString)::Bool
    aside = _take_own_lock_aside!(path, owner)
    aside === nothing && return false
    rm(aside; force=true)
    return true
end

# The name this had before 0.8.9. Internal, but SweepRunner's tests release a held artifact lock
# with it, and a missing name there fails as a 600 s wait rather than as an error.
const _clear_lock_at! = _release_lock_at!

# ── the heartbeat ────────────────────────────────────────────────────────────────────────────────
#
# On Linux, a child `sh`. It opens the lock ONCE, read-only (so a lock released before it starts
# is not re-created), checks the owner and the header format through that descriptor, and from
# then on rewrites the fixed-width header through it. Writing via `/dev/fd/3` relies on Linux
# re-opening the file there with its own offset; BSD and macOS `fdescfs` share the descriptor's
# offset instead, and the header would never be rewritten, so they use the task below.
#
# It stops when the parent pid is gone, or when `path` no longer names the inode it holds
# (released or reclaimed). A reclaimer that moves a live lock aside and puts it back leaves the
# name empty for a moment, so the check is retried for half a second before the child gives up.
# A header of the wrong width is never written. Arguments go in as `$1..$5`, never spliced into
# the script, so no path or token needs quoting.
const _HEARTBEAT_SH = raw"""
pid=$1; interval=$2; lock=$3; owner=$4; width=$5
exec 3<"$lock" || exit 3
grep -qx "owner=$owner" /dev/fd/3 || exit 3
[ "$(head -c 15 /dev/fd/3)" = "heartbeat_unix=" ] || exit 2
held() {
    i=0
    while [ $i -lt 10 ]; do
        [ "$lock" -ef /dev/fd/3 ] && return 0
        i=$((i + 1)); sleep 0.05
    done
    return 1
}
while kill -0 "$pid" 2>/dev/null; do
    sleep "$interval"
    held || exit 0
    now=$(date +%s.%N 2>/dev/null)
    case "$now" in
        *N*|'') now="$(( $(date +%s) + 1 )).000000" ;;   # no %N: round UP, the safe direction
        *) now=${now%???} ;;                              # nanoseconds to microseconds
    esac
    line=$(printf 'heartbeat_unix=%s\nheartbeat=%s' "$now" "$(date '+%Y-%m-%dT%H:%M:%S')")
    [ ${#line} -eq $((width - 1)) ] || continue
    printf '%s\n' "$line" | dd of=/dev/fd/3 conv=notrunc bs="$width" count=1 2>/dev/null
done
"""

"""
    HeartbeatHandle

What [`start_heartbeat`](@ref) returns and [`stop_heartbeat`](@ref) takes. Ask
[`heartbeat_alive`](@ref) whether it is still beating.
"""
struct HeartbeatHandle
    path::String
    owner::String
    proc::Union{Base.Process,Nothing}      # the child `sh` (Linux)
    task::Union{Task,Nothing}              # the fallback task (elsewhere, or an old-format lock)
    stop::Threads.Atomic{Bool}
end

function _start_lock_heartbeat(
    path::AbstractString, owner::AbstractString, interval::Real; child::Bool=Sys.islinux()
)::HeartbeatHandle
    stop = Threads.Atomic{Bool}(false)
    # No period to beat at: an inert handle, and the lock ages out after `stale_after`.
    interval > 0 || return HeartbeatHandle(path, owner, nothing, nothing, stop)
    content = _read_lock(path)
    if child && content !== nothing && startswith(content, "heartbeat_unix=")
        cmd = `sh -c $_HEARTBEAT_SH sh $(getpid()) $(interval) $path $owner $(_HB_HEADER_BYTES)`
        proc = run(pipeline(cmd; stdout=devnull, stderr=devnull); wait=false)
        return HeartbeatHandle(path, owner, proc, nothing, stop)
    end
    # A task beats only while the holder yields; it is what there is without a Linux child.
    task = Threads.@spawn begin
        while !stop[]
            t = time()
            while !stop[] && time() - t < interval
                sleep(min(0.1, interval))
            end
            stop[] && break
            _beat_lock_at!(path, owner) || break
        end
    end
    return HeartbeatHandle(path, owner, nothing, task, stop)
end

"""
    heartbeat_alive(h::HeartbeatHandle) -> Bool

Whether the heartbeat is still beating. `false` for an inert handle (`interval <= 0`), after
[`stop_heartbeat`](@ref), and once it has given up because the lock was released or reclaimed —
or because it could not beat at all.
"""
function heartbeat_alive(h::HeartbeatHandle)::Bool
    h.proc !== nothing && return process_running(h.proc)
    h.task !== nothing && return !istaskdone(h.task)
    return false
end

"""
    stop_heartbeat(h::HeartbeatHandle)

Stop a heartbeat started by [`start_heartbeat`](@ref). Idempotent. The lock is left as it is:
release it with [`clear_running!`](@ref) or [`mark_done!`](@ref).

Warns if the heartbeat had already stopped while its lock was still `owner`'s: nothing kept that
lock fresh, so a sibling may have been, or may yet be, entitled to reclaim it.
"""
function stop_heartbeat(h::HeartbeatHandle)
    died = (h.proc !== nothing || h.task !== nothing) && !heartbeat_alive(h) && !h.stop[]
    h.stop[] = true
    if died && _owns_lock_at(h.path, h.owner)
        @warn "heartbeat had stopped while its lock was still held" h.path h.owner
    end
    if h.proc !== nothing
        try
            process_running(h.proc) && kill(h.proc)
            Base.wait(h.proc)
        catch
        end
    elseif h.task !== nothing
        try
            wait(h.task)
        catch
        end
    end
    return nothing
end
