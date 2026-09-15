# reporting/figure.jl — figure provenance (meta.toml)

"""
    record_figure(vault; study, scripts=Dict())

Write `meta.toml` under `out/figure/{study}/`.

`scripts` is an optional `Dict{String,String}` mapping label → path,
e.g. `Dict("plot_energy" => "scripts/analysis/plot_energy.jl")`.
"""
function record_figure(
    vault::Vault; study::AbstractString, scripts::Dict{String,String}=Dict{String,String}()
)
    _refuse_if_readonly(vault, "record_figure")
    figure_dir = joinpath(vault.outdir, "figure", study)
    mkpath(figure_dir)

    config_rel = relpath(vault.config_path, figure_dir)
    data_rel = relpath(joinpath(vault.outdir, "data", study), figure_dir)
    git_hash = _git_hash(vault.config_path)

    meta = Dict(
        "source" => Dict(
            "config" => config_rel,
            "data_dir" => data_rel,
            "git_hash" => git_hash,
            "generated_at" => string(Dates.today()),
        ),
        "scripts" => scripts,
    )

    meta_path = joinpath(figure_dir, "meta.toml")
    open(meta_path, "w") do io
        return TOML.print(io, meta)
    end
    return meta_path
end

# ── figure archive (append-only version chain) ──────────────────────────────
#
# live path:     outdir/figure/<project>/<run>/<subdir>/<name>
# archive path:  outdir/figure/<project>/<run>/archive/<tag>/<subdir>/<name>
# manifest:      outdir/figure/<project>/<run>/figures.toml
#
# A new archive entry is appended on every `archive_figure!` call.  If the
# incoming file has the same SHA-1 as any prior archived version, the
# existing archive file is reused (content dedup) and only the manifest
# gets a new entry.  The live file itself is never modified by DataVault.

const _FIGURES_TOML_NAME = "figures.toml"

function _figures_run_dir(vault::Vault)::String
    return _run_figure_dir(vault)
end

function _figures_toml_path(vault::Vault)::String
    return joinpath(_figures_run_dir(vault), _FIGURES_TOML_NAME)
end

function _sha1_of_file(path::AbstractString)::String
    open(path, "r") do io
        return bytes2hex(SHA.sha1(io))
    end
end

function _load_figures_toml(vault::Vault)::Dict{String,Any}
    path = _figures_toml_path(vault)
    isfile(path) || return Dict{String,Any}("figures" => Vector{Dict{String,Any}}())
    raw = try
        TOML.parsefile(path)
    catch
        Dict{String,Any}()
    end
    figs = get(raw, "figures", nothing)
    figs isa AbstractVector || (figs = Vector{Dict{String,Any}}())
    return Dict{String,Any}("figures" => Vector{Dict{String,Any}}(figs))
end

function _save_figures_toml(vault::Vault, data::Dict{String,Any})
    path = _figures_toml_path(vault)
    mkpath(dirname(path))
    _atomic_toml_write(path, data)
    return path
end

function _archive_tag(vault::Vault, live_path::AbstractString)::String
    # Include a nanosecond suffix so concurrent/fast repeat calls do not
    # collide on identical human-readable timestamps.
    ts = Dates.format(Dates.now(), "yyyy-mm-ddTHHMMSS")
    ns = string(time_ns() % 1000000; pad=6)
    gh = _git_hash(live_path)
    isempty(gh) && (gh = "unknown")
    return string(ts, "-", ns, "_", gh)
end

function _find_existing_archive_by_hash(
    fig_entry::Dict{String,Any}, content_hash::String
)::Union{Nothing,String}
    versions = get(fig_entry, "versions", nothing)
    versions isa AbstractVector || return nothing
    needle = "sha1:" * content_hash
    for v in versions
        v isa AbstractDict || continue
        if String(get(v, "content_hash", "")) == needle
            ap = String(get(v, "archive_path", ""))
            isempty(ap) && continue
            return ap
        end
    end
    return nothing
end

function _find_or_create_entry!(
    data::Dict{String,Any}, name::AbstractString, subdir::AbstractString
)::Dict{String,Any}
    list = data["figures"]::Vector{Dict{String,Any}}
    for e in list
        if String(get(e, "name", "")) == String(name) &&
            String(get(e, "subdir", "")) == String(subdir)
            return e
        end
    end
    entry = Dict{String,Any}(
        "name" => String(name),
        "subdir" => String(subdir),
        "versions" => Vector{Dict{String,Any}}(),
    )
    push!(list, entry)
    return entry
end

"""
    archive_figure!(vault::Vault, live_path::AbstractString;
                    generator_script::Union{Nothing,AbstractString}=nothing,
                    metadata::AbstractDict=Dict{String,Any}(),
                    subdir::AbstractString="") -> String

Snapshot `live_path` into the run's figure archive and append a version
entry to `figures.toml`.  `live_path` itself is not modified.

- `subdir` is the relative directory under the run's figure dir
  (e.g. `"phase1"`); use `""` for files sitting directly under `<run>/`.
- `generator_script` is recorded verbatim (typically `@__FILE__`).
- `metadata` is merged into the version entry (free-form).
- Content dedup: if a prior archive has the same SHA-1, the new version
  entry points at that existing archive file instead of copying again.

Returns the absolute path of the archived file (old or new).  Marks the
new entry `is_current = true` and flips every older sibling to `false`.
"""
function archive_figure!(
    vault::Vault,
    live_path::AbstractString;
    generator_script::Union{Nothing,AbstractString}=nothing,
    metadata::AbstractDict=Dict{String,Any}(),
    subdir::AbstractString="",
)::String
    isfile(live_path) || error("archive_figure!: live_path not found: $live_path")

    name = basename(live_path)
    run_dir = _figures_run_dir(vault)
    mkpath(run_dir)

    content_hash = _sha1_of_file(live_path)
    tag = _archive_tag(vault, live_path)

    data = _load_figures_toml(vault)
    entry = _find_or_create_entry!(data, name, subdir)

    existing_archive = _find_existing_archive_by_hash(entry, content_hash)

    archive_rel_dir = joinpath("archive", tag, subdir)
    archive_rel = joinpath(archive_rel_dir, name)
    archive_abs = joinpath(run_dir, archive_rel)

    if existing_archive !== nothing
        # Reuse on-disk file; just add a manifest entry pointing at it.
        archive_rel = existing_archive
        archive_abs = joinpath(run_dir, archive_rel)
    else
        mkpath(joinpath(run_dir, archive_rel_dir))
        cp(live_path, archive_abs; force=false)
    end

    # Flip all prior sibling versions to is_current=false.
    versions = get!(entry, "versions", Vector{Dict{String,Any}}())
    for v in versions
        v["is_current"] = false
    end

    version_entry = Dict{String,Any}(
        "generated_at" => Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS"),
        "git_hash" => _git_hash(live_path),
        "generator" => generator_script === nothing ? "" : String(generator_script),
        "archive_path" => archive_rel,
        "size_bytes" => filesize(live_path),
        "content_hash" => "sha1:" * content_hash,
        "is_current" => true,
        "tag" => tag,
        "metadata" => Dict{String,Any}(string(k) => v for (k, v) in metadata),
    )
    push!(versions, version_entry)

    _save_figures_toml(vault, data)
    return archive_abs
end

"""
    list_figure_history(vault::Vault; name::Union{Nothing,AbstractString}=nothing)
        -> Vector{NamedTuple}

Return version entries from `figures.toml`.  If `name` is given, only that
figure's versions are returned.  Each element:

    (; name, subdir, generated_at, git_hash, generator, archive_path,
       size_bytes, content_hash, is_current, tag, metadata)
"""
function list_figure_history(
    vault::Vault; name::Union{Nothing,AbstractString}=nothing
)::Vector{NamedTuple}
    data = _load_figures_toml(vault)
    out = Vector{NamedTuple}()
    for entry in data["figures"]::Vector{Dict{String,Any}}
        nm = String(get(entry, "name", ""))
        name === nothing || nm == String(name) || continue
        sub = String(get(entry, "subdir", ""))
        for v in get(entry, "versions", Vector{Dict{String,Any}}())
            md = get(v, "metadata", Dict{String,Any}())
            push!(
                out,
                (;
                    name=nm,
                    subdir=sub,
                    generated_at=String(get(v, "generated_at", "")),
                    git_hash=String(get(v, "git_hash", "")),
                    generator=String(get(v, "generator", "")),
                    archive_path=String(get(v, "archive_path", "")),
                    size_bytes=Int(get(v, "size_bytes", 0)),
                    content_hash=String(get(v, "content_hash", "")),
                    is_current=Bool(get(v, "is_current", false)),
                    tag=String(get(v, "tag", "")),
                    metadata=Dict{String,Any}(string(k) => val for (k, val) in md),
                ),
            )
        end
    end
    return out
end

"""
    restore_figure!(vault::Vault, name::AbstractString, archive_tag::AbstractString;
                    subdir::AbstractString="") -> String

Replace the live figure `<run>/<subdir>/<name>` with the archived version
identified by `archive_tag`.  The current live file is first archived (via
`archive_figure!`) so the restoration is reversible.

Throws if the archive_tag does not exist for this (name, subdir).  Returns
the absolute live path.
"""
function restore_figure!(
    vault::Vault,
    name::AbstractString,
    archive_tag::AbstractString;
    subdir::AbstractString="",
)::String
    run_dir = _figures_run_dir(vault)
    live = joinpath(run_dir, subdir, name)

    # Archive current live first (reversibility).
    if isfile(live)
        archive_figure!(
            vault, live; subdir=subdir, metadata=Dict("reason" => "restore_snapshot")
        )
    end

    # Locate requested archive.
    data = _load_figures_toml(vault)
    target_rel = ""
    for entry in data["figures"]::Vector{Dict{String,Any}}
        String(get(entry, "name", "")) == String(name) || continue
        String(get(entry, "subdir", "")) == String(subdir) || continue
        for v in get(entry, "versions", Vector{Dict{String,Any}}())
            if String(get(v, "tag", "")) == String(archive_tag)
                target_rel = String(get(v, "archive_path", ""))
                break
            end
        end
    end
    isempty(target_rel) &&
        error("restore_figure!: no archive tagged $archive_tag for $subdir/$name")

    target_abs = joinpath(run_dir, target_rel)
    isfile(target_abs) || error("restore_figure!: archive file missing: $target_abs")

    mkpath(dirname(live))
    cp(target_abs, live; force=true)

    # Flip is_current flags in the manifest so the restored snapshot wins.
    for entry in data["figures"]::Vector{Dict{String,Any}}
        String(get(entry, "name", "")) == String(name) || continue
        String(get(entry, "subdir", "")) == String(subdir) || continue
        for v in get(entry, "versions", Vector{Dict{String,Any}}())
            v["is_current"] = String(get(v, "tag", "")) == String(archive_tag)
        end
    end
    _save_figures_toml(vault, data)
    return live
end
