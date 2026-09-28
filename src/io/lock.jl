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

# `heartbeat_unix=` + 17 (10 integer digits until 2286, a point, 6 decimals) and `heartbeat=` + 19.
const _HB_HEADER_BYTES = 63

function _hb_header(t::Float64=time())::String
    h =
        "heartbeat_unix=" *
        @sprintf("%017.6f", t) *
        "\n" *
        "heartbeat=" *
        Libc.strftime("%Y-%m-%dT%H:%M:%S", t) *
        "\n"
    ncodeunits(h) == _HB_HEADER_BYTES ||
        error("heartbeat header is not fixed width: $(repr(h))")
    return h
end

function _lock_body(owner::AbstractString, t::Float64=time())::String
    started = Libc.strftime("%Y-%m-%dT%H:%M:%S", t)
    body = _hb_header(t) * "pid=$(getpid())\nstarted=$(started)\n"
    isempty(owner) || (body *= "owner=$(owner)\n")
    return body
end

# Seconds since the lock's last heartbeat, or `nothing` when there is no file to read.
function _lock_age(path::AbstractString)::Union{Float64,Nothing}
    content = try
        read(path, String)
    catch
        return nothing
    end
    return _lock_age(path, content)
end

function _lock_age(path::AbstractString, content::AbstractString)::Float64
    for line in eachsplit(content, '\n')
        startswith(line, "heartbeat_unix=") || continue
        t = tryparse(Float64, line[16:end])
        (t === nothing || !isfinite(t)) && break
        return _age_or_fallback(path, time() - t)
    end
    # Written before `heartbeat_unix=`: local time, whole seconds, the reader's zone assumed.
    for line in eachsplit(content, '\n')
        startswith(line, "heartbeat=") || continue
        hb = tryparse(DateTime, line[11:end], dateformat"yyyy-mm-ddTHH:MM:SS")
        hb === nothing && break
        return _age_or_fallback(path, Dates.value(Dates.now() - hb) / 1000.0)
    end
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
        seen = try
            read(path, String)
        catch
            return _link(fresh, path) ? :ok : :busy
        end
        # Judged again under the mutex: the holder may have beaten, or the lock been replaced.
        _lock_age(path, seen) <= stale_after && return :busy

        aside = _aside_name(path, "stale")
        try
            Base.rename(path, aside)
        catch
            return _link(fresh, path) ? :ok : :busy        # removed meanwhile
        end
        moved = try
            read(aside, String)
        catch
            ""
        end
        if moved != seen
            # Between the read and the move, the holder beat (it is alive) or the lock was released
            # and taken afresh. Either way what moved is not what was judged stale: put it back.
            # Should that fail, someone took the name in the gap; the lock we moved then belongs to
            # a holder that finds out through its owner check, and we still do not take the key.
            _link(aside, path)
            rm(aside; force=true)
            return :busy
        end
        rm(aside; force=true)
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

# Whether the lock at `path` is `owner`'s. The token carries a per-acquisition nonce and a lock's
# `owner=` line never changes, so a match is this acquisition's lock and not an earlier one.
function _owns_lock_at(path::AbstractString, owner::AbstractString)::Bool
    content = try
        read(path, String)
    catch
        return false
    end
    return _has_owner_line(content, owner)
end

function _has_owner_line(content::AbstractString, owner::AbstractString)::Bool
    return any(==("owner=$(owner)"), eachsplit(content, '\n'))
end

# Refresh the heartbeat of the lock at `path`, through a descriptor on its inode. With `owner`,
# only that owner's lock, and only while `path` still names the inode we opened: a lock reclaimed
# since is someone else's file under the same name.
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
        header = _hb_header()
        seekstart(io)
        if startswith(content, "heartbeat_unix=") && ncodeunits(content) >= _HB_HEADER_BYTES
            write(io, header)                       # the fixed-width header, in place
        else
            # A lock written before the header existed: rewrite it whole, with one, on this inode.
            rest = filter(
                l -> !isempty(l) && !startswith(l, "heartbeat"), split(content, '\n')
            )
            truncate(io, 0)
            write(io, header * join(rest, "\n") * (isempty(rest) ? "" : "\n"))
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
    aside = _aside_name(path, "done")
    try
        Base.rename(path, aside)
    catch
        return nothing
    end
    content = try
        read(aside, String)
    catch
        ""
    end
    _has_owner_line(content, owner) && return aside
    _link(aside, path)                              # not ours after all: put it back
    rm(aside; force=true)
    return nothing
end

function _release_lock_at!(path::AbstractString, owner::AbstractString)::Bool
    aside = _take_own_lock_aside!(path, owner)
    aside === nothing && return false
    rm(aside; force=true)
    return true
end

# ── the heartbeat child ──────────────────────────────────────────────────────────────────────────
#
# Opens the lock ONCE, checks the owner on that descriptor, and from then on rewrites the fixed-
# width header through it. It stops when the parent pid is gone, or when `path` no longer names
# the inode it holds (released or reclaimed). Arguments go in as `$1..$4`, never spliced into the
# script, so no path or token needs quoting.
const _HEARTBEAT_SH = raw"""
pid=$1; interval=$2; lock=$3; owner=$4
exec 3<>"$lock" || exit 0
grep -qx "owner=$owner" <&3 || exit 0
while kill -0 "$pid" 2>/dev/null; do
    sleep "$interval"
    [ "$lock" -ef /dev/fd/3 ] || exit 0
    now=$(date +%s.%N 2>/dev/null)
    case "$now" in
        *N*|'') now="$(( $(date +%s) + 1 )).000000" ;;   # no %N: round UP, the safe direction
        *) now=${now%???} ;;                              # nanoseconds to microseconds
    esac
    printf 'heartbeat_unix=%s\nheartbeat=%s\n' "$now" "$(date '+%Y-%m-%dT%H:%M:%S')" |
        dd of=/dev/fd/3 conv=notrunc bs=63 count=1 2>/dev/null
done
"""

"""
    HeartbeatHandle

What [`start_heartbeat`](@ref) returns and [`stop_heartbeat`](@ref) takes.
"""
struct HeartbeatHandle
    proc::Union{Base.Process,Nothing}
end

function _start_lock_heartbeat(path::AbstractString, owner::AbstractString, interval::Real)
    # No `sh` on Windows, and no period to beat at for `interval <= 0` (`sleep` would fail at once
    # and the loop spin): an inert handle, and the lock ages out after `stale_after`.
    (Sys.iswindows() || interval <= 0) && return HeartbeatHandle(nothing)
    cmd = `sh -c $_HEARTBEAT_SH sh $(getpid()) $(interval) $path $owner`
    return HeartbeatHandle(run(pipeline(cmd; stdout=devnull, stderr=devnull); wait=false))
end

"""
    stop_heartbeat(h::HeartbeatHandle)

Stop a heartbeat started by [`start_heartbeat`](@ref). Idempotent. The lock is left as it is:
release it with [`clear_running!`](@ref) or [`mark_done!`](@ref).
"""
function stop_heartbeat(h::HeartbeatHandle)
    p = h.proc
    p === nothing && return nothing
    try
        process_running(p) && kill(p)
        Base.wait(p)
    catch
    end
    return nothing
end
