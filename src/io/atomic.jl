# io/atomic.jl — NFS-safe な原子的書き込み

"""
    _atomic_jld2_write(path, data) -> String

Write `data` (a `Dict`) to `path` atomically by writing to a per-task,
per-pid temporary file first and then `mv`ing it into place. Safe against
concurrent writers across processes (NFS) and across tasks within one process.

Returns the SHA-256 (hex) of the bytes written, read from the temporary file after it is closed
and before it is moved into place: the digest names exactly what this call published under
`path`, whatever touches `path` afterwards.
"""
function _atomic_jld2_write(path::String, data::Dict)::String
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
        digest = bytes2hex(open(sha256, tmp))
        mv(tmp, path; force=true)
        return digest
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
    catch
        "unknown"
    end
end

"""
    _git_observe(ref_path) -> (; commit, object_format)

The full HEAD of the git repo containing `ref_path` and the repo's object format (`"sha1"` or
`"sha256"`), each `"unknown"` when git cannot say. This is an observation of the working tree
at the moment it is called; it does not say which code a process had loaded.
"""
function _git_observe(ref_path::String)
    dir = isdir(ref_path) ? ref_path : dirname(ref_path)
    read_git(args) =
        try
            strip(read(pipeline(`git -C $dir $args`; stderr=devnull), String))
        catch
            "unknown"
        end
    commit = read_git(`rev-parse HEAD`)
    occursin(r"^([0-9a-f]{40}|[0-9a-f]{64})$", commit) || (commit = "unknown")
    format = read_git(`rev-parse --show-object-format`)
    format in ("sha1", "sha256") || (format = "unknown")
    return (; commit=String(commit), object_format=String(format))
end
