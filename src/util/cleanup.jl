# util/cleanup.jl — 残存した .running ファイルの掃除

"""
    cleanup_stale(vault; stale_after=600.0) -> Int

Remove `.running` sentinel files whose `heartbeat=` timestamp is older than
`stale_after` seconds. Returns the number of files removed.

The heartbeat is read from the file content (written by [`mark_running!`](@ref)
and updated by [`touch_running!`](@ref)). If the heartbeat cannot be parsed,
the file's mtime is used as a fallback.

Pass `stale_after=0.0` to remove all `.running` files unconditionally
(the pre-v0.4.1 behaviour).
"""
function cleanup_stale(vault::Vault; stale_after::Real=600.0)::Int
    _refuse_if_readonly(vault, "cleanup_stale")
    status_base = _run_status_dir(vault)
    isdir(status_base) || return 0

    threshold = Float64(stale_after)
    now_dt = Dates.now()
    count = 0
    for (root, _, files) in walkdir(status_base)
        for f in files
            endswith(f, ".running") || continue
            fp = joinpath(root, f)
            _running_age_secs(fp, now_dt) > threshold || continue
            rm(fp; force=true)
            count += 1
        end
    end
    return count
end

# Future heartbeats within this margin (seconds) are attributed to multi-host
# NFS clock skew and treated as "fresh"; beyond it the timestamp is considered
# corrupt and we fall back to the local mtime.
const _HEARTBEAT_FUTURE_SKEW = 300.0

# Read the `heartbeat=` timestamp from a .running file and return age in
# seconds. Falls back to file mtime if the timestamp cannot be parsed, or if it
# is implausibly future-dated (a negative age would otherwise make the lock
# look perpetually fresh — i.e. a key that can never be reclaimed).
function _running_age_secs(path::String, now_dt::DateTime)::Float64
    try
        for line in eachline(path)
            if startswith(line, "heartbeat=")
                hb = Dates.DateTime(line[11:end], "yyyy-mm-ddTHH:MM:SS")
                age = Dates.value(now_dt - hb) / 1000.0  # ms → s
                if age >= 0.0
                    return age
                elseif age > -_HEARTBEAT_FUTURE_SKEW
                    return 0.0          # small clock skew → treat as fresh
                end
                break                   # implausibly future-dated → mtime fallback
            end
        end
    catch
    end
    # Fallback: file mtime (parse failure or corrupt future heartbeat)
    return time() - mtime(path)
end
