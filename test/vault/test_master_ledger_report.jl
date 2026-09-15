# master_ledger_report (#16): whether the sources build_master_ledger merged were the same shape.

using DataVault, ParamIO, Test, Logging

const _MLR_FIX = joinpath(@__DIR__, "fixtures")

function _seed!(outdir, config, run, n)
    v = Vault(config; run=run, outdir=outdir)
    for k in DataVault.keys(v)[1:n]
        DataVault.save!(v, k, Dict("x" => 1.0))
        mark_done!(v, k)
    end
    build_ledger(v)
    return v
end

function _warnings(f)
    return (
        l=Test.TestLogger(; min_level=Logging.Warn);
        Logging.with_logger(f, l);
        filter(r -> r.level == Logging.Warn, l.logs)
    )
end

@testset "master_ledger_report: same key space across runs is ok" begin
    outdir = mktempdir()
    try
        _seed!(outdir, joinpath(_MLR_FIX, "study.toml"), "phase1", 3)
        _seed!(outdir, joinpath(_MLR_FIX, "study.toml"), "phase2", 2)

        r = master_ledger_report(outdir)
        @test r.ok
        @test length(r.rows) == 5
        @test length(r.sources) == 2
        @test all(s -> isempty(s.missing), r.sources)
        @test isempty(r.collisions)
        @test "system.N" in r.columns && "model.g" in r.columns
        @test sum(s -> s.nrows, r.sources) == length(r.rows)

        # And nothing is warned about, so the warning below is the condition and not the verb.
        @test isempty(_warnings(() -> build_master_ledger(outdir)))
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "master_ledger_report: disjoint key spaces are reported, per source" begin
    outdir = mktempdir()
    try
        _seed!(outdir, joinpath(_MLR_FIX, "study.toml"), "phase1", 3)
        _seed!(outdir, joinpath(_MLR_FIX, "study_other_axes.toml"), "phase1", 2)

        r = master_ledger_report(outdir)
        @test !r.ok
        @test length(r.rows) == 5
        @test length(r.sources) == 2

        by = Dict(s.project_name => s for s in r.sources)
        @test "system.N" in by["other_study"].missing      # other_study has no N
        @test "system.M" in by["test_study"].missing       # test_study has no M
        @test "system.N" in r.columns && "system.M" in r.columns

        # The rows really are ragged, which is the consequence being reported.
        @test any(row -> !haskey(row, "system.N"), r.rows)
        @test any(row -> !haskey(row, "system.M"), r.rows)

        w = _warnings(() -> build_master_ledger(outdir))
        @test length(w) == 1
        @test occursin("do not share a column set", w[1].message)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "master_ledger_report: a param column shadowed by a meta column is named" begin
    # `run` is both a legal param name and a column the merge writes. Today the merge wins and the
    # param value is gone from every row, with nothing said.
    outdir = mktempdir()
    try
        v = _seed!(outdir, joinpath(_MLR_FIX, "study_run_column.toml"), "r1", 2)
        raw = load_ledger(v)
        @test Set(row["run"] for row in raw) == Set(["7", "9"])   # the param's own values

        r = master_ledger_report(outdir)
        @test !r.ok
        @test length(r.collisions) == 1
        @test r.collisions[1].column == "run"
        @test r.collisions[1].project_name == "collide_study"

        # The corruption itself: the param value is not in the merged rows.
        @test all(row -> row["run"] == "r1", r.rows)

        w = _warnings(() -> build_master_ledger(outdir))
        @test any(x -> occursin("overwrote a ledger column", x.message), w)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "master_ledger_report: rows agree with build_master_ledger" begin
    outdir = mktempdir()
    try
        _seed!(outdir, joinpath(_MLR_FIX, "study.toml"), "phase1", 3)
        _seed!(outdir, joinpath(_MLR_FIX, "study_other_axes.toml"), "phase1", 2)
        r = master_ledger_report(outdir)
        m = with_logger(NullLogger()) do
            build_master_ledger(outdir)
        end
        @test m == r.rows
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "master_ledger_report: an empty outdir is ok and empty" begin
    outdir = mktempdir()
    try
        r = master_ledger_report(outdir)
        @test r.ok
        @test isempty(r.rows) && isempty(r.sources) && isempty(r.columns)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "master_ledger_report: reading does not write the runs it reads" begin
    # open_all(; readonly=true) underneath: a report is a read, and must not refresh the log.toml
    # of every run it discovers.
    outdir = mktempdir()
    try
        _seed!(outdir, joinpath(_MLR_FIX, "study.toml"), "phase1", 2)
        log = joinpath(outdir, ".datavault", "test_study", "phase1.log.toml")
        before = read(log, String)
        master_ledger_report(outdir)
        @test read(log, String) == before
    finally
        rm(outdir; recursive=true, force=true)
    end
end
