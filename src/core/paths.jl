# core/paths.jl — Vault のパス解決ヘルパ
#
# レイアウト:
#   {outdir}/data/{project_name}/{run}/{params}/data_sample{NNN}.jld2
#   {outdir}/bin/{project_name}/{run}/{params}/checkpoint_sample{NNN}.jld2
#   {outdir}/status/{project_name}/{run}/{params}/sample_{NNN}.done
#   {outdir}/figure/{project_name}/{run}/...
#
# 1 つの study (= project_name) は複数の run を持てる。
# log.toml の [layout] セクションがこの規約を記録する。

# ── 「この run が住むディレクトリ」 ─────────────────────────────────────────────
# log.toml writer / snapshot / ledger / cleanup から再利用する。

_run_data_dir(vault::Vault)::String =
    joinpath(vault.outdir, "data", vault.spec.study.project_name, vault.run)

_run_status_dir(vault::Vault)::String =
    joinpath(vault.outdir, "status", vault.spec.study.project_name, vault.run)

_run_bin_dir(vault::Vault)::String =
    joinpath(vault.outdir, "bin", vault.spec.study.project_name, vault.run)

_run_figure_dir(vault::Vault)::String =
    joinpath(vault.outdir, "figure", vault.spec.study.project_name, vault.run)

# ── パラメータパス ────────────────────────────────────────────────────────────

function _param_path(vault::Vault, key::DataKey)::String
    return vault.path_formatter(key, vault.spec.path_keys)
end

# ── データ ────────────────────────────────────────────────────────────────────

function _data_dir(vault::Vault, key::DataKey)::String
    return joinpath(_run_data_dir(vault), _param_path(vault, key))
end

function _data_file(vault::Vault, key::DataKey; prefix::AbstractString="data")::String
    return joinpath(
        _data_dir(vault, key), @sprintf("%s_sample%03d.jld2", prefix, key.sample)
    )
end

# ── チェックポイント ──────────────────────────────────────────────────────────

function _bin_dir(vault::Vault, key::DataKey)::String
    return joinpath(_run_bin_dir(vault), _param_path(vault, key))
end

function _bin_file(vault::Vault, key::DataKey; prefix::AbstractString="checkpoint")::String
    return joinpath(
        _bin_dir(vault, key), @sprintf("%s_sample%03d.jld2", prefix, key.sample)
    )
end

# ── ステータス ────────────────────────────────────────────────────────────────

function _status_dir(vault::Vault, key::DataKey)::String
    return joinpath(_run_status_dir(vault), _param_path(vault, key))
end

function _done_file(vault::Vault, key::DataKey)::String
    return joinpath(_status_dir(vault, key), @sprintf("sample_%03d.done", key.sample))
end

function _running_file(vault::Vault, key::DataKey)::String
    return joinpath(_status_dir(vault, key), @sprintf("sample_%03d.running", key.sample))
end

# ── public path API ───────────────────────────────────────────────────────────
#
# The layout above is DataVault's to own, and until now there was no way to ask for it: every
# accessor was `_`-prefixed, so a consumer that needed a key's directory had to rebuild
# `joinpath(outdir, "data", project, run, format_path(key, path_keys))` by hand. Twelve benchmark
# scripts in this fleet do exactly that, which is why they render float path segments with the
# legacy `%.2f` no matter what `[datavault] float_format` says — a hand-built path cannot see the
# vault's scheme. These five are the same functions, exported.

"""
    param_path(vault, key) -> String

The directory segment `key` gets under this vault's path scheme — one component, no parents.

Which scheme that is comes from the vault, not from the caller: see [`Vault`](@ref). Rebuilding
this string from `ParamIO.format_path` instead is what silently pins a consumer to the legacy
`fixed2` rendering.
"""
param_path(vault::Vault, key::DataKey)::String = _param_path(vault, key)

"""
    data_dir(vault, key) -> String

Directory holding `key`'s payloads, `{outdir}/data/{project}/{run}/{param_path}`. Reach for this
when writing something alongside the payload — a snapshot, a log, a figure this key owns — so it
lands where `load` will look.
"""
data_dir(vault::Vault, key::DataKey)::String = _data_dir(vault, key)

"""
    data_file(vault, key; prefix="data") -> String

Path of `key`'s payload file inside [`data_dir`](@ref). `prefix` selects a parallel series stored
beside the default one.
"""
data_file(vault::Vault, key::DataKey; prefix::AbstractString="data")::String =
    _data_file(vault, key; prefix=prefix)

"""
    status_dir(vault, key) -> String

Directory holding `key`'s `.done` / `.running` markers. The markers themselves are
[`is_done`](@ref) and [`is_running`](@ref)'s business; this is for a caller that needs the
directory itself.
"""
status_dir(vault::Vault, key::DataKey)::String = _status_dir(vault, key)

"""
    bin_dir(vault, key) -> String

Directory holding `key`'s checkpoints, the counterpart of [`data_dir`](@ref) under `bin/`.
"""
bin_dir(vault::Vault, key::DataKey)::String = _bin_dir(vault, key)
