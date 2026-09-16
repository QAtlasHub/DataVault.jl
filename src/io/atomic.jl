# io/atomic.jl — NFS-safe な原子的書き込み

# Replace `dst` with `src` in one step, or not at all. `mv(src, dst; force=true)` is NOT that
# before Julia 1.12: it unlinks `dst` FIRST and then renames, so a crash in the gap leaves `dst`
# ABSENT rather than holding either version, and a concurrent reader can observe it missing. This
# package supports 1.11. Returns whether the rename landed.
_rename_into_place(src::AbstractString, dst::AbstractString)::Bool =
    ccall(:rename, Cint, (Cstring, Cstring), src, dst) == 0

"""
    _atomic_jld2_write(path, data)

Write `data` (a `Dict`) to `path` atomically by writing to a per-task,
per-pid temporary file first and then `rename(2)`ing it into place. Safe against
concurrent writers across processes (NFS) and across tasks within one process.
"""
function _atomic_jld2_write(path::String, data::Dict)
    # Per-task unique suffix: pid alone collides when two tasks in the SAME
    # process write the same key (e.g. under Threads), letting one task `mv` a
    # tmp file another is still writing. Mirrors `_atomic_toml_write`.
    tmp = string(path, ".tmp.", getpid(), ".", objectid(current_task()), ".", time_ns())
    try
        jldopen(tmp, "w") do f
            for (k, v) in data
                f[string(k)] = v
            end
        end
        _rename_into_place(tmp, path) ||
            error("rename($tmp, $path) failed: ", Base.Libc.strerror(Base.Libc.errno()))
    catch e
        isfile(tmp) && rm(tmp; force=true)
        rethrow(e)
    end
end

"""
    _git_hash(ref_path) -> String

Return the short HEAD hash of the git repo containing `ref_path`,
or `"unknown"` if not in a repo.
"""
function _git_hash(ref_path::String)::String
    dir = isdir(ref_path) ? ref_path : dirname(ref_path)
    try
        strip(read(pipeline(`git -C $dir rev-parse --short HEAD`; stderr=devnull), String))
    catch e
        e isa InterruptException && rethrow()
        "unknown"
    end
end
