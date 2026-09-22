using SHA

# load_recorded: the digest names exactly the bytes the returned data came from, and sits next to
# what the .done marker recorded, so the two can be compared.

const _LR_CFG = joinpath(@__DIR__, "fixtures", "study.toml")

function with_lr_vault(f)
    outdir = mktempdir()
    try
        v = Vault(_LR_CFG; outdir=outdir)
        f(v, DataVault.keys(v))
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "load_recorded: the data, and the digest of the bytes it came from" begin
    with_lr_vault() do v, keys
        k = keys[1]
        saved = DataVault.save!(v, k, Dict("energy" => -1.5))
        mark_done!(v, k; result=saved, observation="obs1-test")
        data, rec = load_recorded(v, k)
        @test data["energy"] == -1.5
        @test rec.read_sha256 == saved.sha256 == rec.result_sha256
        @test rec.read_sha256 == bytes2hex(open(sha256, saved.file))
        @test rec.observation == "obs1-test" && rec.done_version == "2"
        @test rec.key == DataVault.ParamIO.canonical(k)
        @test joinpath(v.outdir, rec.file) == saved.file
        @test occursin(r"Z$", rec.completed_at)
    end
end

@testset "load_recorded: bytes replaced after completion are told apart" begin
    with_lr_vault() do v, keys
        k = keys[1]
        mark_done!(v, k; result=DataVault.save!(v, k, Dict("energy" => -1.5)))
        DataVault.save!(v, k, Dict("energy" => 9.0))           # rewritten after the marker
        data, rec = load_recorded(v, k)
        @test data["energy"] == 9.0
        @test rec.read_sha256 != rec.result_sha256
    end
end

@testset "load_recorded: what the marker did not say is unknown" begin
    with_lr_vault() do v, keys
        k1, k2 = keys[1], keys[2]
        DataVault.save!(v, k1, Dict("x" => 1))
        mkpath(dirname(DataVault._done_file(v, k1)))
        write(
            DataVault._done_file(v, k1),
            "jobid=1\ncompleted=2026-01-01T00:00:00\ngit_hash=abc\n",
        )
        _, rec = load_recorded(v, k1)                           # a version-1 marker
        @test rec.done_version == "1" && rec.result_sha256 == "unknown"
        @test rec.observation == "unknown" && rec.completed_at == "unknown"
        DataVault.save!(v, k2, Dict("x" => 2))
        _, rec2 = load_recorded(v, k2)                          # no marker at all
        @test rec2.done_version == "unknown" && isempty(read_done(v, k2))
        @test_throws ErrorException load_recorded(v, keys[3])  # no file
    end
end
