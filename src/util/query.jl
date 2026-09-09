# util/query.jl — programmatic read-oriented API for DataVault databases
#
# High-level primitives for discovering and attaching to previously written
# studies. Built on top of log.toml discovery (see util/log_toml.jl).
#
# Typical usage from an analysis / figure script:
#
#     for study in DataVault.open_all(outdir)
#         study.info.project_name == "linear_response" || continue
#         for key in DataVault.keys(study.vault; status=:done)
#             data = DataVault.load(study.vault, key)
#             # plot / analyze
#         end
#     end
#
# Attached vaults are normal writable `Vault`s: attaching effectively
# re-registers the current DataVault version with the existing log.toml.
# This lets you seamlessly resume computation — `mark_done!`, `save!`,
# `build_ledger`, etc. all work on attached vaults.

"""
    AttachedStudy

A bundle of (`vault`, log.toml `info`, `log_path`) produced by `open_all`.
Iterate over these to process every study under an outdir.
"""
struct AttachedStudy
    vault::Vault
    info::LogTomlV1
    log_path::String
end

"""
    attach(log_path) -> Vault
    attach(outdir; project, run="default") -> Vault

Attach to a previously written (study, run) and return a `Vault`.

The first form takes the absolute path to a `log.toml` file directly.
The second form uses the frozen discovery contract — given an `outdir`,
a `project` name, and a `run` name, it resolves the log.toml at
`{outdir}/.datavault/{project}/{run}.log.toml` and attaches to it.
The two forms are distinguished by whether `project` is supplied.

Config resolution order:
  1. `{outdir}/{layout.config_snapshot}` — the frozen snapshot taken at
     initial construction; preferred because it is stable under moves and
     is colocated with the data.
  2. `log.toml[study].config` — the original absolute path recorded at
     construction; used as a fallback with a warning.
  3. Error if neither is available.

The returned `Vault` is fully writable. Its constructor will idempotently
upsert the log.toml, refreshing `[meta].datavault_version` and
`datavault_git_hash`. `created_at` is preserved.
"""
function attach(
    path::AbstractString;
    project::Union{AbstractString,Nothing}=nothing,
    run::AbstractString="default",
)::Vault
    log_path = if project === nothing
        path
    else
        candidate = joinpath(path, DATAVAULT_DIR_NAME, project, "$(run).log.toml")
        isfile(candidate) || error(
            "No log.toml for project='$project' run='$run' under $path. " *
            "Expected: $candidate",
        )
        candidate
    end
    info = read_log_toml(log_path)
    outdir = _infer_outdir(log_path)
    config_path = _resolve_config_for_attach(info, outdir)
    # No grid scan: `check_paths` asks "will this sweep overwrite itself", which is a question
    # about writing. Attaching is a read, and `open_all` attaches once per run — a colliding
    # study would otherwise re-warn on every discovery, forever.
    return Vault(config_path; run=info.run, outdir=outdir, check_paths=false)
end

"""
    open_all(outdir::AbstractString) -> Vector{AttachedStudy}

Discover every `*.log.toml` under `{outdir}/.datavault/` and attach to each.
Broken log.toml files (unknown version, missing envelope, etc.) are logged
as warnings and skipped so that iteration over a partially-corrupted
outdir still yields the healthy studies.
"""
function open_all(outdir::AbstractString)::Vector{AttachedStudy}
    result = AttachedStudy[]
    for log_path in find_log_tomls(outdir)
        attached = try
            info = read_log_toml(log_path)
            inferred = _infer_outdir(log_path)
            config_path = _resolve_config_for_attach(info, inferred)
            vault = Vault(config_path; run=info.run, outdir=inferred, check_paths=false)
            AttachedStudy(vault, info, log_path)
        catch e
            @warn "Failed to attach log.toml — skipping" path = log_path exception = e
            continue
        end
        push!(result, attached)
    end
    return result
end

"""
    load_ledger(vault::Vault) -> Vector{Dict{String,String}}

Read `ledger.csv` for this vault's (study, run) and return it as a vector
of row dicts (`column_name => string_value`). Returns `Dict{String,String}[]`
if the ledger file does not exist or is empty.

Values are returned as strings; callers are responsible for type
conversion. The parser assumes DataVault's output format (simple
comma-separated, no quoting, no embedded commas).

Use `build_ledger(vault)` first if you want a fresh ledger reflecting the
latest `.done` files.
"""
function load_ledger(vault::Vault)::Vector{Dict{String,String}}
    path = joinpath(_run_data_dir(vault), "ledger.csv")
    return _read_ledger_csv(path)
end

"""
    build_master_ledger(outdir::AbstractString) -> Vector{Dict{String,String}}

Aggregate every ledger under `outdir` into a single flat sequence of row
dicts. Each row has its original ledger columns plus the following meta
columns prepended conceptually (the dict is unordered):

  - `project_name`
  - `run`
  - `datavault_version`
  - `log_toml` (outdir-relative path to the originating log.toml)

Studies whose ledger.csv does not yet exist contribute zero rows but are
still attached (their metadata appears via `open_all` if you want both).

For cross-outdir aggregation (e.g. scanning a whole Vault tree), call
this per outdir and concatenate — DataVault itself is intentionally
unaware of any higher-level layout like Vault's `apps/lib/dev` layers.
"""
function build_master_ledger(outdir::AbstractString)::Vector{Dict{String,String}}
    rows = Vector{Dict{String,String}}()
    for attached in open_all(outdir)
        local_rows = load_ledger(attached.vault)
        isempty(local_rows) && continue
        log_rel = relpath(attached.log_path, outdir)
        for row in local_rows
            merged = copy(row)
            merged["project_name"] = attached.info.project_name
            merged["run"] = attached.info.run
            merged["datavault_version"] = attached.info.datavault_version
            merged["log_toml"] = log_rel
            push!(rows, merged)
        end
    end
    return rows
end

# ── helpers ───────────────────────────────────────────────────────────────────

"""
Infer outdir from a log.toml path. The frozen discovery contract puts
log.toml at `{outdir}/.datavault/{project}/{run}.log.toml`, so three
dirname pops recover the outdir. Also validates the `.datavault/` parent
to catch paths that don't match the contract.
"""
function _infer_outdir(log_path::AbstractString)::String
    # {outdir}/.datavault/{project}/{run}.log.toml
    project_dir = dirname(log_path)      # .../.datavault/{project}
    datavault_dir = dirname(project_dir)  # .../.datavault
    basename(datavault_dir) == DATAVAULT_DIR_NAME || error(
        "log.toml at $log_path is not under a $(DATAVAULT_DIR_NAME)/ directory; " *
        "cannot infer outdir via the discovery contract",
    )
    return dirname(datavault_dir)
end

function _resolve_config_for_attach(info::LogTomlV1, outdir::AbstractString)::String
    snapshot_abs = joinpath(outdir, info.config_snapshot)
    if isfile(snapshot_abs)
        return snapshot_abs
    end
    if isfile(info.config)
        @warn "config_snapshot.toml missing — falling back to recorded absolute config path" snapshot =
            snapshot_abs config = info.config
        return info.config
    end
    return error(
        "Cannot attach: neither config_snapshot.toml ($snapshot_abs) nor " *
        "recorded config ($(info.config)) is available.",
    )
end

"""
Minimal CSV reader for DataVault's ledger.csv output. Handles RFC4180-style
quoted fields (a field wrapped in `"..."` may contain commas; an inner `"` is
written `""`), matching what `build_ledger`/`_csv_escape` emit. Embedded
newlines are not supported (the writer flattens them to spaces), so parsing
stays line-based.
"""
function _read_ledger_csv(path::AbstractString)::Vector{Dict{String,String}}
    isfile(path) || return Dict{String,String}[]
    filesize(path) == 0 && return Dict{String,String}[]
    lines = readlines(path)
    isempty(lines) && return Dict{String,String}[]
    header = _split_csv_line(lines[1])
    rows = Vector{Dict{String,String}}()
    for raw in @view lines[2:end]
        isempty(raw) && continue
        values = _split_csv_line(raw)
        row = Dict{String,String}()
        for (i, col) in enumerate(header)
            row[col] = i ≤ length(values) ? values[i] : ""
        end
        push!(rows, row)
    end
    return rows
end

# Split one CSV line into fields, honoring RFC4180 quoting: a field may be
# wrapped in double-quotes to contain commas, and an inner `"` is written `""`.
function _split_csv_line(line::AbstractString)::Vector{String}
    fields = String[]
    buf = IOBuffer()
    inquotes = false
    chars = collect(line)
    n = length(chars)
    k = 1
    while k ≤ n
        c = chars[k]
        if inquotes
            if c == '"'
                if k < n && chars[k + 1] == '"'
                    print(buf, '"')
                    k += 1
                else
                    inquotes = false
                end
            else
                print(buf, c)
            end
        elseif c == '"'
            inquotes = true
        elseif c == ','
            push!(fields, String(take!(buf)))
        else
            print(buf, c)
        end
        k += 1
    end
    push!(fields, String(take!(buf)))
    return fields
end
