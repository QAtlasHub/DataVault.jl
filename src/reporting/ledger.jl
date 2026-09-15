# reporting/ledger.jl — .done を集約して ledger.csv を生成

"""
    build_ledger(vault) -> String

Scan all `.done` files and write `ledger.csv` under the project data directory.
Returns the path to the written file.
"""
function build_ledger(vault::Vault)::String
    _refuse_if_readonly(vault, "build_ledger")
    done_keys = keys(vault; status=:done)::Vector{DataKey}

    run_dir = _run_data_dir(vault)
    ledger_path = joinpath(run_dir, "ledger.csv")
    mkpath(run_dir)

    if isempty(done_keys)
        write(ledger_path, "")
        return ledger_path
    end

    # Build rows
    param_cols = sort(collect(Base.keys(first(done_keys).params)))
    meta_cols = ["sample", "run_id", "git_hash", "completed_at", "tag_value", "status"]
    all_cols = vcat(param_cols, meta_cols)

    rows = Vector{Dict{String,String}}()
    for key in done_keys
        done_data = _parse_done_file(_done_file(vault, key))
        row = Dict{String,String}()
        for c in param_cols
            row[c] = string(get(key.params, c, ""))
        end
        row["sample"] = string(key.sample)
        row["run_id"] = get(done_data, "jobid", "")
        row["git_hash"] = get(done_data, "git_hash", "")
        row["completed_at"] = get(done_data, "completed", "")
        row["tag_value"] = get(done_data, "tag_value", "")
        row["status"] = "done"
        push!(rows, row)
    end

    open(ledger_path, "w") do io
        println(io, join((_csv_escape(c) for c in all_cols), ","))
        for row in rows
            println(io, join((_csv_escape(get(row, c, "")) for c in all_cols), ","))
        end
    end

    return ledger_path
end

# Quote a CSV cell if it contains a comma or a double-quote (inner quotes are
# doubled, RFC4180-style). Newlines are flattened to spaces so the line-based
# reader (`_read_ledger_csv`) stays correct; ledger cells (e.g. `tag_value`)
# are single-line values in practice. Without this, a `tag_value` like
# `"[1, 2]"` shifts every later column and the reader mis-associates values.
function _csv_escape(s::AbstractString)::String
    t = replace(String(s), '\n' => ' ', '\r' => ' ')
    if occursin(',', t) || occursin('"', t)
        return string('"', replace(t, '"' => "\"\""), '"')
    end
    return t
end

function _parse_done_file(path::String)::Dict{String,String}
    result = Dict{String,String}()
    isfile(path) || return result
    for line in eachline(path)
        idx = findfirst('=', line)
        idx === nothing && continue
        result[line[1:(idx - 1)]] = line[(idx + 1):end]
    end
    return result
end
