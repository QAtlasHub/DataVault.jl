# readonly=true — reading a run without committing its key space, and tryload.

using DataVault, ParamIO, Test, TOML

const _RO_CONFIG = joinpath(@__DIR__, "fixtures", "study.toml")

_log_path(outdir) = joinpath(outdir, ".datavault", "test_study", "default.log.toml")

@testset "readonly: construction leaves no mark on a run that has never executed" begin
    outdir = mktempdir()
    try
        before = sort(collect(walkdir(outdir))[1][3])
        v = Vault(_RO_CONFIG; outdir=outdir, readonly=true)
        @test v.readonly
        @test !isfile(_log_path(outdir))
        @test !isdir(joinpath(outdir, ".datavault"))
        @test !isfile(
            joinpath(outdir, "data", "test_study", "default", "config_snapshot.toml")
        )
        # The control: the same construction WITHOUT readonly does write, so the assertion above
        # is not passing because nothing writes here anyway.
        Vault(_RO_CONFIG; outdir=outdir)
        @test isfile(_log_path(outdir))
        @test before == String[]
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "readonly: a run with no log.toml is usable, not refused" begin
    outdir = mktempdir()
    try
        v = Vault(_RO_CONFIG; outdir=outdir, readonly=true)
        ks = DataVault.keys(v)
        @test !isempty(ks)
        @test count(k -> !is_done(v, k), ks) == length(ks)
        @test !isfile(_log_path(outdir))
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "readonly: an existing log.toml is still validated" begin
    outdir = mktempdir()
    try
        Vault(_RO_CONFIG; outdir=outdir)            # writes the anchor
        recorded = read(_log_path(outdir), String)

        # Same spec: accepted, and the file is untouched byte for byte (the writing path would
        # refresh [meta].datavault_git_hash even when nothing else changed).
        v = Vault(_RO_CONFIG; outdir=outdir, readonly=true)
        @test v.readonly
        @test read(_log_path(outdir), String) == recorded

        # Different path_keys under the same run name: the refusal that the upsert provides must
        # survive into the read-only path, or a reader silently reads the wrong key space.
        alt = joinpath(mktempdir(), "alt.toml")
        cfg = TOML.parsefile(_RO_CONFIG)
        cfg["datavault"]["path_keys"] = ["model.g", "system.N"]
        open(alt, "w") do io
            TOML.print(io, cfg)
        end
        @test_throws ErrorException Vault(alt; outdir=outdir, readonly=true)
        @test read(_log_path(outdir), String) == recorded
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "readonly: every write verb refuses" begin
    outdir = mktempdir()
    try
        w = Vault(_RO_CONFIG; outdir=outdir)
        k = DataVault.keys(w)[1]
        DataVault.save!(w, k, Dict("energy" => 1.0))
        mark_done!(w, k)

        r = Vault(_RO_CONFIG; outdir=outdir, readonly=true)
        @test_throws ArgumentError DataVault.save!(r, k, Dict("energy" => 2.0))
        @test_throws ArgumentError DataVault.save_bin!(r, k, Dict("psi" => 1))
        @test_throws ArgumentError mark_done!(r, k)
        @test_throws ArgumentError mark_running!(r, k)
        @test_throws ArgumentError acquire_running!(r, k)
        @test_throws ArgumentError touch_running!(r, k)
        @test_throws ArgumentError refresh_running!(r, k)
        @test_throws ArgumentError clear_running!(r, k)
        @test_throws ArgumentError build_ledger(r)
        @test_throws ArgumentError record_figure(r; study="test_study")
        @test_throws ArgumentError cleanup_stale(r)

        # Refusing is not the same as breaking: the payload the writer left is still readable, and
        # unchanged by the refused save!.
        @test is_done(r, k)
        @test DataVault.load(r, k)["energy"] == 1.0
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "readonly: the same verbs work on an ordinary vault" begin
    # Control for the testset above: those ArgumentErrors have to come from `readonly`, not from
    # the fixture being unable to support the call.
    outdir = mktempdir()
    try
        w = Vault(_RO_CONFIG; outdir=outdir)
        k = DataVault.keys(w)[1]
        @test isfile(DataVault.save!(w, k, Dict("energy" => 1.0)).file)
        @test acquire_running!(w, k) == :ok
        @test refresh_running!(w, k)
        @test touch_running!(w, k) === nothing
        @test clear_running!(w, k) === nothing
        @test mark_done!(w, k) === nothing
        @test isfile(build_ledger(w))
        @test record_figure(w; study="test_study") isa AbstractString
        @test cleanup_stale(w) isa Int
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "readonly: attach and open_all pass it through" begin
    outdir = mktempdir()
    try
        Vault(_RO_CONFIG; outdir=outdir)
        recorded = read(_log_path(outdir), String)

        v = attach(outdir; project="test_study", run="default", readonly=true)
        @test v.readonly
        @test read(_log_path(outdir), String) == recorded

        studies = open_all(outdir; readonly=true)
        @test length(studies) == 1
        @test studies[1].vault.readonly
        @test read(_log_path(outdir), String) == recorded

        # Default is unchanged: still writable, so this is an opt-in and not a silent narrowing.
        @test !attach(outdir; project="test_study", run="default").readonly
        @test !open_all(outdir)[1].vault.readonly
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "tryload: absence is a value, and only absence" begin
    outdir = mktempdir()
    try
        v = Vault(_RO_CONFIG; outdir=outdir)
        ks = DataVault.keys(v)
        DataVault.save!(v, ks[1], Dict("energy" => 1.5))

        @test DataVault.tryload(v, ks[1])["energy"] == 1.5
        @test DataVault.tryload(v, ks[2]) === nothing
        @test_throws ErrorException DataVault.load(v, ks[2])

        # A file that exists and is not readable still raises: a corrupt payload must not be
        # reported as a missing one.
        path = DataVault.data_file(v, ks[2])
        mkpath(dirname(path))
        write(path, "not a JLD2 file")
        @test_throws Exception DataVault.tryload(v, ks[2])

        # Reading is not writing: tryload works on a readonly vault.
        r = Vault(_RO_CONFIG; outdir=outdir, readonly=true)
        @test DataVault.tryload(r, ks[1])["energy"] == 1.5
    finally
        rm(outdir; recursive=true, force=true)
    end
end
