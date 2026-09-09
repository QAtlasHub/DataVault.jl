# core/vault.jl — Vault struct と constructor

"""
    Vault

Handle for a single (study, run) pair.
Wraps a `ConfigSpec` and resolves file paths under `outdir`.

# Fields

- `config_path`: absolute path to the source config TOML
- `spec`:        parsed `ParamIO.ConfigSpec` (study, path_keys, paramsets)
- `outdir`:      absolute root path under which `data/`, `status/`, `bin/`,
                 `figure/`, and `.datavault/` live
- `run`:         named campaign / phase within the study. Defaults to
                 `"default"`. Use distinct names to keep multi-phase
                 explorations separate (e.g. `"phase1"`, `"phase2_refined"`)
- `path_formatter`: function `(DataKey, path_keys) -> String`

# outdir resolution

Priority: constructor argument > `ENV["DATAVAULT_OUTDIR"]` > config value.

# Multi-run usage

A study (= one `project_name`) may contain multiple runs. Each run gets its
own data / status / bin / figure subtree under `{outdir}/{layer}/{project}/{run}/`
and its own discovery anchor at `{outdir}/.datavault/{project}/{run}.log.toml`.

```julia
v1 = Vault("configs/linear_response.toml"; run="phase1",         outdir="out/")
v2 = Vault("configs/linear_response.toml"; run="phase2_refined", outdir="out/")
```

Multiple parallel jobs can share the same `(project, run)`: each job touches
different `DataKey`s, and the log.toml upsert is idempotent and atomic.

# Path naming

The config decides. `[datavault] float_format = "auto"` gives each swept float axis the
precision its own value set needs, so distinct values get distinct directories; the default
`"fixed2"` renders every float with `%.2f`, under which `0.006` and `0.008` share a directory
and one result overwrites the other.

An existing run's scheme WINS over the config: `log.toml` records what a run was actually
written with, and changing the config afterwards must not move data that is already on disk.
The mismatch is reported; use a different `run` name to start a tree under the new scheme.

Pass `path_formatter` to override both:

    formatter(key::DataKey, path_keys::Vector{String}) -> String

A formatter given this way cannot be reproduced from log.toml alone, so DataVault warns.

# Path collision check

Construction warns when two DISTINCT parameter points format to ONE directory — they would
overwrite each other while the ledger reports both as done. One deduplicated pass over the
expanded grid: on the largest sweep in this fleet (90k keys, 900 distinct points) it adds
~150 ms warm, and ~1 s on the first call in a session, which is compilation. `check_paths=false`
skips it; `attach` and `open_all` already pass it, being reads rather than writes.
"""
struct Vault
    config_path::String
    spec::ParamIO.ConfigSpec
    outdir::String
    run::String
    path_formatter::Function
end

"""
    AutoPathFormatter(axis_formats)

The `path_formatter` behind `[datavault] float_format = "auto"`. Holds the per-axis float
precision `ParamIO.build_axis_formats` derives from the sweep's whole value set, which is what
makes distinct values of a swept float axis land in distinct directories.

Built by `Vault`; callers do not normally construct one.
"""
struct AutoPathFormatter <: Function
    axis_formats::Dict{String,ParamIO.AxisFloatFmt}
end

(f::AutoPathFormatter)(key, path_keys) = ParamIO.format_path(key, path_keys, f.axis_formats)

# The name log.toml records. "default" rather than "fixed2" because files written before auto
# mode existed already say "default", and this value is read back to decide a run's scheme.
_path_scheme(f::Function) = f === ParamIO.format_path ? "default" : "custom"
_path_scheme(::AutoPathFormatter) = "auto"

# The function log.toml names. `nameof` is only reached for a caller-supplied formatter; the two
# built-in schemes name themselves, so an anonymous closure's "#3#4" never stands for one of them.
function _formatter_name(f::Function)
    return f === ParamIO.format_path ? "ParamIO.format_path" : string(nameof(f))
end
_formatter_name(::AutoPathFormatter) = "ParamIO.format_path(auto)"

# What the config asks for, in the same vocabulary.
_declared_scheme(spec) = spec.float_format == "auto" ? "auto" : "default"

function _build_formatter(scheme::AbstractString, spec)
    return if scheme == "auto"
        AutoPathFormatter(ParamIO.build_axis_formats(spec))
    else
        ParamIO.format_path
    end
end

function Vault(
    config_path::AbstractString;
    run::AbstractString="default",
    outdir::Union{AbstractString,Nothing}=nothing,
    path_formatter::Union{Function,Nothing}=nothing,
    check_paths::Bool=true,
)
    spec = ParamIO.load(config_path)

    resolved = if outdir !== nothing
        string(outdir)
    elseif haskey(ENV, "DATAVAULT_OUTDIR")
        ENV["DATAVAULT_OUTDIR"]
    else
        spec.study.outdir
    end
    resolved = abspath(resolved)

    formatter = _resolve_formatter(path_formatter, spec, resolved, string(run))

    vault = Vault(abspath(config_path), spec, resolved, string(run), formatter)

    # log.toml upsert is the discovery anchor and validates path_keys against
    # any pre-existing entry — must run first so a conflicting run name fails
    # before we touch the data subtree.
    _save_log_toml(vault)
    _save_config_snapshot(vault)
    check_paths && _warn_on_path_collisions(vault)
    return vault
end

# Which scheme this (project, run) was actually written with, or `nothing` if it is new.
# A log.toml that exists but cannot be read is reported rather than treated as absent: silence
# here would resolve the scheme from the config and move an existing run's data.
function _recorded_scheme(
    outdir::AbstractString, project::AbstractString, run::AbstractString
)
    log_path = _log_toml_path(outdir, project, run)
    isfile(log_path) || return nothing
    try
        return read_log_toml(log_path).path_scheme
    catch e
        e isa InterruptException && rethrow()
        @warn "log.toml unreadable — falling back to the config's path scheme, which may not be the one this run's data was written with" log_path exception =
            e
        return nothing
    end
end

# Precedence: an explicit `path_formatter=` beats everything; else the scheme this run was
# written with; else what the config declares.
function _resolve_formatter(
    explicit::Union{Function,Nothing}, spec, outdir::AbstractString, run::AbstractString
)
    explicit === nothing || return explicit

    declared = _declared_scheme(spec)
    recorded = _recorded_scheme(outdir, spec.study.project_name, run)
    recorded === nothing && return _build_formatter(declared, spec)

    if recorded == "custom"
        @warn "This run was written with a custom path_formatter, which log.toml cannot reproduce — pass `path_formatter=` to read it back" run declared_scheme =
            declared
        return _build_formatter(declared, spec)
    end
    if recorded != declared
        @warn "Config declares a different path scheme than this run was written with; keeping the run's own scheme so existing data stays reachable. Use a different `run` name to sweep under the new one." run recorded_scheme =
            recorded config_scheme = declared
    end
    return _build_formatter(recorded, spec)
end

# Two DISTINCT parameter points that format to ONE directory overwrite each other, and the
# ledger still reports both as done. Checked here because this is where the formatter and the
# grid first meet. One pass over the expanded grid, deduplicated on the path keys: ~150 ms warm
# on the largest sweep in this fleet (90k keys, 900 distinct points), ~1 s on a session's first
# call. Pass `check_paths=false` to skip it.
function _warn_on_path_collisions(vault::Vault)
    claims = try
        seen = Set{Any}()
        claims = Dict{String,Vector{Any}}()
        for key in ParamIO.expand(vault.spec)
            sig = Tuple(get(key.params, pk, nothing) for pk in vault.spec.path_keys)
            sig in seen && continue
            push!(seen, sig)
            push!(get!(claims, _param_path(vault, key), Any[]), sig)
        end
        claims
    catch e
        e isa InterruptException && rethrow()
        @warn "Could not check the grid for path collisions — this is NOT a clean result" run =
            vault.run exception = e
        return nothing
    end

    collisions = sort!([(p, sigs) for (p, sigs) in claims if length(sigs) > 1]; by=first)
    isempty(collisions) && return nothing

    lost = sum(length(s) - 1 for (_, s) in collisions)
    examples = join(
        ["  \"$p\" <- $(join(sigs, ", "))" for (p, sigs) in first(collisions, 3)], "\n"
    )
    @warn """
    $(length(collisions)) directories are claimed by more than one parameter point under the \
    "$(_path_scheme(vault.path_formatter))" path scheme. $lost point(s) will be overwritten by \
    another, and the ledger will still report every one of them as done.

    $examples$(length(collisions) > 3 ? "\n  … and $(length(collisions) - 3) more" : "")

    Fix by giving the colliding axis its own precision — `[datavault] float_format = "auto"` \
    under a NEW run name — or by adding the axis that separates them to `path_keys`.""" run =
        vault.run project = vault.spec.study.project_name
    return nothing
end
