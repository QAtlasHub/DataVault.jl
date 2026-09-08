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

The reader side of a sweep is otherwise always the same three lines — enumerate, load, push.

Not exported, like [`keys`](@ref) beside it: call it as `DataVault.results(vault)`.

`status` defaults to `:done` rather than to `keys`' `:all`, because `load` raises on a key nobody
has computed. A pairing that inherited `:all` would die on the first pending key, which is the
state a sweep is in for most of its life.

It is lazy — a generator, not a `Vector`. A production sweep is thousands of JLD2 files and a
payload can be large, so reading one point must not force the rest. `collect` it when the whole
thing is wanted.

```julia
for (key, d) in DataVault.results(vault)
    push!(rows, (; T = d["kbT"], E = d["energy"]))
end
```
"""
function results(vault::Vault; status::Symbol=:done, prefix::AbstractString="data")
    return ((k, load(vault, k; prefix=prefix)) for k in keys(vault; status=status))
end
