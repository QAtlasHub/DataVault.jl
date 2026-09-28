# util/cleanup.jl — 残存した .running ファイルの掃除

"""
    cleanup_stale(vault; stale_after=600.0) -> Int

Remove `.running` sentinel files whose heartbeat is older than
`stale_after` seconds. Returns the number of files removed.

The heartbeat is read from the file content: `heartbeat_unix=` when present,
else the older `heartbeat=` line, else the file's mtime.

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

# The age of a `.running` file in seconds (`Inf` when it is gone). Kept under this name for the
# callers that have it; the reading itself is `_lock_age` in `io/lock.jl`. `now_dt` is unused:
# age now comes from `heartbeat_unix=`, which does not depend on the reader's clock zone.
function _running_age_secs(path::String, now_dt::DateTime)::Float64
    age = _lock_age(path)
    return age === nothing ? Inf : age
end
