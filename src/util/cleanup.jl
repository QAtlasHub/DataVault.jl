# util/cleanup.jl — 残存した .running ファイルの掃除

"""
    cleanup_stale(vault; stale_after=600.0) -> Int

Remove `.running` sentinel files whose heartbeat is older than
`stale_after` seconds. Returns the number of files removed.

The heartbeat is read from the file content: `heartbeat_unix=` when present,
else the older `heartbeat=` line, else the file's mtime.

Pass `stale_after=0.0` to remove all `.running` files unconditionally
(the pre-v0.4.1 behaviour).

It also removes what a process killed in the middle of a lock step leaves
beside the locks — `<lock>.acq.<pid>.<hex>` and the other temporaries, an
abandoned `<lock>.reclaim` — once they are a minute old. Those live for
milliseconds otherwise, and are not counted in the return value.
"""
function cleanup_stale(vault::Vault; stale_after::Real=600.0)::Int
    _refuse_if_readonly(vault, "cleanup_stale")
    status_base = _run_status_dir(vault)
    isdir(status_base) || return 0

    threshold = Float64(stale_after)
    count = 0
    for (root, _, files) in walkdir(status_base)
        _sweep_lock_leftovers(root)
        for f in files
            endswith(f, ".running") || continue
            fp = joinpath(root, f)
            _running_age_secs(fp) > threshold || continue
            rm(fp; force=true)
            count += 1
        end
    end
    return count
end

# The age of a `.running` file in seconds (`Inf` when it is gone). The reading itself is
# `_lock_age` in `io/lock.jl`.
function _running_age_secs(path::String)::Float64
    age = _lock_age(path)
    return age === nothing ? Inf : age
end
