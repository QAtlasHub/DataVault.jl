# util/log_toml.jl — discovery anchor for DataVault data
#
# log.toml は DataVault 出力の「凍結された discovery contract」です。
# 任意の未来バージョンの DataVault が、過去に書かれたデータを再発見・
# 再解釈するための唯一のアンカーとして機能します。
#
# 凍結契約 (どの DataVault バージョンでも変えてはならない):
#   1. {outdir}/.datavault/ ディレクトリが存在する
#   2. その中に *.log.toml ファイルがある (v1 では {project}/{run}.log.toml)
#   3. 各 *.log.toml には [meta].log_toml_version (整数) がある
#
# 上記 3 点さえ守られていれば、未来の DataVault は walkdir で *.log.toml を
# 列挙し、[meta].log_toml_version で reader を dispatch して、
# その世代のレイアウト (data_dir / status_dir / path_keys 等) を取り出せる。
#
# 注意: 過去バージョンの reader は絶対に消さないこと。新バージョンを足すときは
# LOG_TOML_READERS に新しいエントリを追加するだけ。古い reader を残すことが
# 過去データの読み戻し可能性を保証する。

"""現在の writer が出すスキーマバージョン。新フォーマットを追加するたびに +1"""
const LOG_TOML_VERSION = 1

"""凍結: discovery anchor のディレクトリ名。永遠に変えない"""
const DATAVAULT_DIR_NAME = ".datavault"

"""log.toml v1 が保持する全フィールド"""
struct LogTomlV1
    log_toml_version::Int
    datavault_version::String
    datavault_git_hash::String
    created_at::String

    project_name::String
    config::String

    run::String

    data_dir::String
    status_dir::String
    bin_dir::String
    ledger::String
    config_snapshot::String

    path_scheme::String
    path_formatter::String
    path_keys::Vector{String}

    julia_version::String
    hostname::String
end

"""
    read_log_toml(path) -> LogTomlV1 (or future LogTomlV2, …)

Read a log.toml file from `path`. Dispatches on `[meta].log_toml_version`
via `LOG_TOML_READERS`. The returned struct depends on the file's version.

Throws an explicit error if:
- the file does not exist
- `[meta]` envelope is missing or malformed
- `log_toml_version` is unknown to this DataVault build
"""
function read_log_toml(path::AbstractString)
    isfile(path) || error("log.toml not found: $path")
    parsed = TOML.parsefile(path)
    haskey(parsed, "meta") || error("Invalid log.toml: missing [meta] envelope at $path")
    haskey(parsed["meta"], "log_toml_version") ||
        error("Invalid log.toml: missing [meta].log_toml_version at $path")
    v = parsed["meta"]["log_toml_version"]
    v isa Integer ||
        error("Invalid log.toml: [meta].log_toml_version must be an integer at $path")
    reader = get(LOG_TOML_READERS, v, nothing)
    reader === nothing && error(
        "Unknown log_toml_version=$v at $path. " *
        "This file was written by a newer DataVault. " *
        "Please upgrade DataVault to read it.",
    )
    return reader(parsed, path)
end

# ── v1 reader ────────────────────────────────────────────────────────────────

function _read_log_toml_v1(parsed::Dict, path::AbstractString)::LogTomlV1
    function _need(d::Dict, k::AbstractString, where::AbstractString)
        haskey(d, k) || error("Invalid log.toml v1: missing [$where].$k at $path")
        return d[k]
    end

    meta = _need(parsed, "meta", "")
    study = _need(parsed, "study", "")
    run = _need(parsed, "run", "")
    layout = _need(parsed, "layout", "")
    pathb = _need(parsed, "path", "")
    prov = _need(parsed, "provenance", "")

    return LogTomlV1(
        _need(meta, "log_toml_version", "meta"),
        _need(meta, "datavault_version", "meta"),
        get(meta, "datavault_git_hash", "unknown"),
        _need(meta, "created_at", "meta"),
        _need(study, "project_name", "study"),
        _need(study, "config", "study"),
        _need(run, "name", "run"),
        _need(layout, "data_dir", "layout"),
        _need(layout, "status_dir", "layout"),
        _need(layout, "bin_dir", "layout"),
        _need(layout, "ledger", "layout"),
        _need(layout, "config_snapshot", "layout"),
        _need(pathb, "scheme", "path"),
        _need(pathb, "formatter", "path"),
        Vector{String}(_need(pathb, "keys", "path")),
        _need(prov, "julia_version", "provenance"),
        _need(prov, "hostname", "provenance"),
    )
end

"""
Reader registry: log_toml_version → reader function.

新しいスキーマを追加するときは:
  1. 新しい struct LogTomlVN と _read_log_toml_vN を定義
  2. このレジストリに `N => _read_log_toml_vN` を追加
  3. 古いエントリは絶対に消さない

これにより、過去どのバージョンで書かれた log.toml でも、現役の DataVault が
読み戻せることを保証する。
"""
const LOG_TOML_READERS = Dict{Int,Function}(1 => _read_log_toml_v1)

# ── discovery ────────────────────────────────────────────────────────────────

"""
    find_log_tomls(outdir) -> Vector{String}

Recursively scan `{outdir}/.datavault/` for `*.log.toml` files and return
their absolute paths. The discovery contract (the directory name and the
`.log.toml` suffix) is frozen across DataVault versions, so this works for
data written by any past or future version.
"""
function find_log_tomls(outdir::AbstractString)::Vector{String}
    dv_dir = joinpath(outdir, DATAVAULT_DIR_NAME)
    isdir(dv_dir) || return String[]
    paths = String[]
    for (root, _, files) in walkdir(dv_dir)
        for f in files
            endswith(f, ".log.toml") && push!(paths, joinpath(root, f))
        end
    end
    sort!(paths)
    return paths
end

# ── writer ───────────────────────────────────────────────────────────────────

const _DATAVAULT_README = """
# .datavault/

**このディレクトリを削除しないでください。**

DataVault はこのディレクトリ内の `*.log.toml` ファイルを、`outdir` 配下に
ある全 study データの discovery anchor として使用します。
DataVault のすべてのバージョンが次の凍結契約に依存しています:

  1. `{outdir}/.datavault/` というディレクトリが存在する
  2. 各 (study, run) ペアが `{project_name}/{run_name}.log.toml` を持つ
  3. 各 `*.log.toml` には `[meta].log_toml_version`（整数）がある

このディレクトリ内のファイルを削除・改名すると、DataVault がデータを
永久に追跡できなくなる可能性があります。バックアップではこのディレクトリ
を内容ごとそのまま保全してください。

このファイル (README.md) は DataVault が初回のみ自動生成しますが、
以降は人間の編集を尊重して上書きしません。自由に追記して構いません。
"""

"""
    _save_log_toml(vault) -> String

Idempotent upsert of log.toml at `.datavault/{project_name}/{run}.log.toml`.

Behavior:
- Ensures `.datavault/` exists and writes README.md if missing.
- If the target log.toml is absent: writes a fresh one with current timestamp.
- If present with the **same** path_keys: preserves `created_at`, refreshes
  `datavault_version` / `datavault_git_hash` / layout fields.
- If present with **different** path_keys: throws an explicit error to
  prevent silent corruption of the run identity.

Atomic: writes via tmp + rename so concurrent jobs cannot leave a partial file.
"""
# Where a (project, run)'s log.toml lives. Also called BEFORE the Vault exists, to read back
# the path scheme a run was written with.
function _log_toml_path(
    outdir::AbstractString, project::AbstractString, run::AbstractString
)::String
    return joinpath(outdir, DATAVAULT_DIR_NAME, project, "$(run).log.toml")
end

function _save_log_toml(vault::Vault)::String
    project = vault.spec.study.project_name
    dv_dir = joinpath(vault.outdir, DATAVAULT_DIR_NAME)
    log_path = _log_toml_path(vault.outdir, project, vault.run)

    _ensure_datavault_readme(dv_dir)
    mkpath(dirname(log_path))

    scheme_name = _path_scheme(vault.path_formatter)
    formatter_name = _formatter_name(vault.path_formatter)
    # "auto" IS reproducible — log.toml names the scheme and the config carries the value set it
    # is derived from. Only a caller-supplied function is not.
    if scheme_name == "custom"
        @warn "Custom path_formatter — path scheme is not reproducible from log.toml alone" run =
            vault.run
    end

    created_at = if isfile(log_path)
        existing = read_log_toml(log_path)
        if existing.path_keys != vault.spec.path_keys
            error(
                "log.toml conflict at $log_path: existing path_keys=" *
                "$(existing.path_keys) differ from current path_keys=" *
                "$(vault.spec.path_keys). " *
                "If this is a new parameter exploration, use a different run name.",
            )
        end
        existing.created_at
    else
        Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    end

    layout = Dict(
        "data_dir" => relpath(_run_data_dir(vault), vault.outdir),
        "status_dir" => relpath(_run_status_dir(vault), vault.outdir),
        "bin_dir" => relpath(_run_bin_dir(vault), vault.outdir),
        "ledger" => relpath(joinpath(_run_data_dir(vault), "ledger.csv"), vault.outdir),
        "config_snapshot" =>
            relpath(joinpath(_run_data_dir(vault), "config_snapshot.toml"), vault.outdir),
    )

    payload = Dict(
        "meta" => Dict(
            "log_toml_version" => LOG_TOML_VERSION,
            "datavault_version" => _datavault_pkg_version(),
            "datavault_git_hash" => _datavault_git_hash(),
            "created_at" => created_at,
        ),
        "study" => Dict("project_name" => project, "config" => vault.config_path),
        "run" => Dict("name" => vault.run),
        "layout" => layout,
        "path" => Dict(
            "scheme" => scheme_name,
            "formatter" => formatter_name,
            "keys" => vault.spec.path_keys,
        ),
        "provenance" =>
            Dict("julia_version" => string(VERSION), "hostname" => gethostname()),
    )

    _atomic_toml_write(log_path, payload)
    return log_path
end

function _ensure_datavault_readme(dv_dir::AbstractString)
    mkpath(dv_dir)
    readme = joinpath(dv_dir, "README.md")
    return isfile(readme) || write(readme, _DATAVAULT_README)
end

function _atomic_toml_write(path::AbstractString, data::Dict)
    mkpath(dirname(path))
    # Per-task unique suffix so concurrent writers within the same process
    # do not collide on the tmp file (pid alone is not enough under Threads).
    tmp = string(path, ".tmp.", getpid(), ".", objectid(current_task()), ".", time_ns())
    try
        open(tmp, "w") do io
            return TOML.print(io, data)
        end
        mv(tmp, path; force=true)
    catch e
        isfile(tmp) && rm(tmp; force=true)
        rethrow(e)
    end
end

function _datavault_pkg_version()::String
    dir = pkgdir(DataVault)
    dir === nothing && return "unknown"
    project_path = joinpath(dir, "Project.toml")
    isfile(project_path) || return "unknown"
    try
        return get(TOML.parsefile(project_path), "version", "unknown")
    catch
        return "unknown"
    end
end

function _datavault_git_hash()::String
    dir = pkgdir(DataVault)
    dir === nothing && return "unknown"
    try
        return strip(
            read(pipeline(`git -C $dir rev-parse --short HEAD`; stderr=devnull), String)
        )
    catch
        return "unknown"
    end
end
