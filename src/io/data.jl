# io/data.jl — JLD2 データ・チェックポイントの読み書き

"""
    DataVault.load(vault, key; prefix="data") -> Dict

Load the JLD2 data file for `key`. Returns the stored dict.
Raises an error if the file does not exist.

Absence is the common case when walking a run that is still being acquired, and a `try`/`catch`
around this is the expensive way to ask: guard with [`is_done`](@ref), or use [`tryload`](@ref),
which returns `nothing` instead of raising.
"""
function load(vault::Vault, key::DataKey; prefix::AbstractString="data")::Dict
    path = _data_file(vault, key; prefix=prefix)
    isfile(path) || error("Data file not found: $path")
    return JLD2.load(path)
end

"""
    read_done(vault, key) -> Dict{String,String}

The fields of `key`'s `.done` marker, or an empty dict when there is none. Every version-2 field
is present in a version-2 marker (as `unknown` when it could not be known); a version-1 marker has
no `done_version`.
"""
read_done(vault::Vault, key::DataKey)::Dict{String,String} =
    _parse_done_file(_done_file(vault, key))

"""
    load_recorded(vault, key; prefix="data") -> (data, record)

Load `key`'s result the way a report should: copy the file once, hash the copy, load the copy. The
digest then names exactly the bytes `data` came from — a file replaced while it is being read
cannot yield the digest of one version and the data of another.

`record` is `(; key, file, read_sha256, result_sha256, observation, completed_at, done_version)`:
`key` is `canonical(key)`, `file` is relative to the outdir, `read_sha256` is what was read, and
the rest is what the `.done` marker recorded when the key was computed (`"unknown"` when it did not
say). `read_sha256 != result_sha256` means the bytes read are not the bytes that computation wrote.
"""
function load_recorded(vault::Vault, key::DataKey; prefix::AbstractString="data")
    path = _data_file(vault, key; prefix=prefix)
    isfile(path) || error("Data file not found: $path")
    snapshot = tempname()
    try
        cp(path, snapshot)                          # the one read of the published file
        sha = bytes2hex(open(sha256, snapshot))
        data = JLD2.load(snapshot)
        done = read_done(vault, key)
        field(k) = get(done, k, "unknown")
        record = (;
            key=ParamIO.canonical(key),
            file=relpath(path, vault.outdir),
            read_sha256=sha,
            result_sha256=field("result_sha256"),
            observation=field("observation"),
            completed_at=field("completed_at"),
            done_version=get(done, "done_version", isempty(done) ? "unknown" : "1"),
        )
        return data, record
    finally
        rm(snapshot; force=true)
    end
end

"""
    DataVault.tryload(vault, key; prefix="data") -> Union{Dict,Nothing}

The stored dict for `key`, or `nothing` when there is no file. [`load`](@ref) with absence as a
value rather than an exception, for the scan-a-partial-vault case.

Only absence is a `nothing`: a file that exists and cannot be read still raises, so a corrupt
payload is not reported as a missing one.
"""
function tryload(
    vault::Vault, key::DataKey; prefix::AbstractString="data"
)::Union{Dict,Nothing}
    path = _data_file(vault, key; prefix=prefix)
    isfile(path) || return nothing
    return JLD2.load(path)
end

"""
    DataVault.save!(vault, key, data; prefix="data") -> (; file, sha256)

Atomically write `data` (a Dict) to the JLD2 data file for `key`.
Uses a tmp file + rename pattern safe on NFS.
Does NOT automatically mark done — call `mark_done!` explicitly, and pass it what this returns
(`mark_done!(vault, key; result=save!(…))`) so the `.done` marker names the bytes that were
written: `sha256` is taken from the temporary file before the rename, not from `file` afterwards.
"""
function save!(vault::Vault, key::DataKey, data::Dict; prefix::AbstractString="data")
    _refuse_if_readonly(vault, "save!")
    path = _data_file(vault, key; prefix=prefix)
    mkpath(dirname(path))
    sha = _atomic_jld2_write(path, data)
    return (; file=path, sha256=sha)
end

"""
    DataVault.load_bin(vault, key; prefix="checkpoint") -> Dict

Load a binary checkpoint file. Raises an explicit error if not present
(checkpoints may exist only on HPC).
"""
function load_bin(vault::Vault, key::DataKey; prefix::AbstractString="checkpoint")::Dict
    path = _bin_file(vault, key; prefix=prefix)
    isfile(path) || error(
        "Checkpoint not found: $path\n" *
        "(Checkpoints may exist only on HPC. Check your outdir or sync first.)",
    )
    return JLD2.load(path)
end

"""
    DataVault.save_bin!(vault, key, data; prefix="checkpoint")

Atomically write a binary checkpoint.
"""
function save_bin!(
    vault::Vault, key::DataKey, data::Dict; prefix::AbstractString="checkpoint"
)
    _refuse_if_readonly(vault, "save_bin!")
    path = _bin_file(vault, key; prefix=prefix)
    mkpath(dirname(path))
    _atomic_jld2_write(path, data)
    return nothing
end
