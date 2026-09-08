# util/enumerate.jl — DataKey の列挙

"""
    keys(vault; status=:all) -> Vector{DataKey}

Enumerate `DataKey`s for this study.

- `status=:all`     — all keys (default)
- `status=:done`    — only keys with a `.done` file
- `status=:pending` — only keys without a `.done` file
"""
function keys(vault::Vault; status::Symbol=:all)::Vector{DataKey}
    all = ParamIO.expand(vault.spec)
    status == :all && return all
    status == :done && return filter(k -> is_done(vault, k), all)
    status == :pending && return filter(k -> !is_done(vault, k), all)
    return error("Unknown status :$status — use :all, :done, or :pending")
end

"""
    results(vault; status=:done, prefix="data") -> iterator of (key, payload)

Every point and what was stored for it, as `(DataKey, Dict)` pairs.

The reader side of a sweep is otherwise always the same three lines — enumerate, load, push — and
writing them out invites the two mistakes this closes. It defaults to `status=:done`, because
`load` on a pending key raises: `keys(vault)` returns everything, so the pairing has to say which
subset it means or the loop dies on the first key nobody has computed yet.

**Lazy.** A production sweep is thousands of JLD2 files and each payload can be large, so this
returns a generator rather than a `Vector`; `collect` it if the whole thing is wanted at once.

```julia
for (key, d) in DataVault.results(vault)
    push!(rows, (; T = d["kbT"], E = d["energy"]))
end
```
"""
function results(vault::Vault; status::Symbol=:done, prefix::AbstractString="data")
    return ((k, load(vault, k; prefix=prefix)) for k in keys(vault; status=status))
end
