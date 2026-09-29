using Dates

isdefined(@__MODULE__, :FIXTURES) || (const FIXTURES = joinpath(@__DIR__, "fixtures"))
isdefined(@__MODULE__, :CONFIG) || (const CONFIG = joinpath(FIXTURES, "study.toml"))

"""
test_concurrency_safety.jl — concurrency / robustness fixes

- `save!` uses a per-task tmp name, so concurrent writers to one key in the
  same process can't `mv` each other's half-written tmp file (corruption).
- a future-dated heartbeat never yields a negative age, so NFS clock skew can't
  make a `.running` lock look perpetually fresh (immortal / never reclaimable).
- `ledger.csv` quotes cells, so a comma in `tag_value` round-trips instead of
  shifting every later column.
"""

@testset "save!: concurrent writers to one key don't corrupt" begin
    # This race only manifests with >= 2 OS threads — single-threaded, the
    # spawned tasks never interleave between `jldopen` and `mv`. Run with
    # `julia -t auto` / JULIA_NUM_THREADS to actually exercise it (CI sets it).
    Threads.nthreads() < 2 &&
        @warn "concurrent-save! test is only meaningful with >=2 threads (got $(Threads.nthreads()))"
    outdir = mktempdir()
    try
        vault = Vault(CONFIG; outdir=outdir)
        key = DataVault.keys(vault)[1]
        # Each writer stores DISTINCT data, so the final file must be exactly
        # one writer's complete payload — not a torn/unreadable file, and not a
        # merge of two writers' keys.
        @sync for i in 1:50
            Threads.@spawn DataVault.save!(vault, key, Dict{String,Any}("w" => i))
        end
        d = DataVault.load(vault, key)           # must load cleanly (not truncated)
        @test haskey(d, "w") && length(d) == 1   # exactly one writer's keys (no merge)
        @test 1 <= d["w"] <= 50                  # and a valid writer's value
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "heartbeat: future timestamp never yields negative age (no immortal lock)" begin
    mktempdir() do dir
        p = joinpath(dir, "k.running")
        for ahead in (Dates.Second(60), Dates.Hour(10))   # within-skew and beyond-skew
            future = Dates.now() + ahead
            write(p, "heartbeat=" * Dates.format(future, "yyyy-mm-ddTHH:MM:SS") * "\n")
            @test DataVault._running_age_secs(p) >= 0.0
        end
    end
end

@testset "ledger CSV: comma in tag_value round-trips" begin
    outdir = mktempdir()
    try
        vault = Vault(CONFIG; outdir=outdir)
        key = DataVault.keys(vault)[1]
        DataVault.save!(vault, key, Dict{String,Any}("x" => 1))
        DataVault.mark_done!(vault, key; tag_value="[1, 2, 3]")
        DataVault.build_ledger(vault)
        rows = DataVault.load_ledger(vault)
        @test length(rows) == 1
        @test rows[1]["tag_value"] == "[1, 2, 3]"
    finally
        rm(outdir; recursive=true, force=true)
    end
end
