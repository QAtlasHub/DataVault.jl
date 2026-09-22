using SHA

# `.done` version 2: the marker names the bytes save! wrote, and states what it observed.

const DONE_V2_CONFIG = joinpath(@__DIR__, "fixtures", "study.toml")

function done_v2_vault(f; config=DONE_V2_CONFIG)
    outdir = mktempdir()
    try
        f(Vault(config; outdir=outdir), outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

function done_fields(vault, key)
    pairs = (split(l, '='; limit=2) for l in eachline(DataVault._done_file(vault, key)))
    return Dict(String(p[1]) => String(p[2]) for p in pairs)
end

@testset ".done v2: save! returns the file and the digest of what it wrote" begin
    done_v2_vault() do vault, _
        k = DataVault.keys(vault)[1]
        res = DataVault.save!(vault, k, Dict("x" => 1.0))
        @test res.file == DataVault._data_file(vault, k)
        @test res.sha256 == bytes2hex(open(sha256, res.file))
    end
end

@testset ".done v2: every field is written, with the result named" begin
    done_v2_vault() do vault, outdir
        k = DataVault.keys(vault)[1]
        res = DataVault.save!(vault, k, Dict("x" => 1.0))
        mark_done!(vault, k; result=res)
        f = done_fields(vault, k)
        @test f["done_version"] == "2"
        @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", f["completed_at"])
        @test haskey(f, "completed") && haskey(f, "git_hash") && haskey(f, "jobid")
        @test f["git_observed_at"] == "completion"
        @test f["result_sha256"] == res.sha256
        @test !isabspath(f["result_file"]) && joinpath(outdir, f["result_file"]) == res.file
    end
end

@testset ".done v2: without a result, the digest is unknown, not absent" begin
    done_v2_vault() do vault, _
        k = DataVault.keys(vault)[1]
        DataVault.save!(vault, k, Dict("x" => 1.0))
        mark_done!(vault, k)
        f = done_fields(vault, k)
        @test f["result_sha256"] == "unknown" && f["result_file"] == "unknown"
    end
end

@testset ".done v2: the digest is of the bytes written, whatever replaces the file after" begin
    done_v2_vault() do vault, _
        k = DataVault.keys(vault)[1]
        res = DataVault.save!(vault, k, Dict("x" => 1.0))
        DataVault.save!(vault, k, Dict("x" => 2.0))          # someone rewrites the file
        mark_done!(vault, k; result=res)
        @test done_fields(vault, k)["result_sha256"] == res.sha256
        @test res.sha256 != bytes2hex(open(sha256, DataVault._data_file(vault, k)))
    end
end

@testset ".done v2: the full commit and object format inside a git repo, unknown outside" begin
    repo = mktempdir()
    try
        cp(DONE_V2_CONFIG, joinpath(repo, "study.toml"))
        for c in (
            `init -q`,
            `add study.toml`,
            `-c user.name=t -c user.email=t@t commit -qm config`,
        )
            run(`git -C $repo $c`)
        end
        head = readchomp(`git -C $repo rev-parse HEAD`)
        done_v2_vault(; config=joinpath(repo, "study.toml")) do vault, _
            k = DataVault.keys(vault)[1]
            mark_done!(vault, k; result=DataVault.save!(vault, k, Dict("x" => 1.0)))
            f = done_fields(vault, k)
            @test f["git_commit_observed"] == head
            @test f["git_object_format"] == "sha1"
            @test startswith(head, f["git_hash"])
        end
    finally
        rm(repo; recursive=true, force=true)
    end
    outside = mktempdir()
    try
        cp(DONE_V2_CONFIG, joinpath(outside, "study.toml"))
        done_v2_vault(; config=joinpath(outside, "study.toml")) do vault, _
            k = DataVault.keys(vault)[1]
            mark_done!(vault, k)
            f = done_fields(vault, k)
            @test f["git_commit_observed"] == "unknown" &&
                f["git_object_format"] == "unknown"
        end
    finally
        rm(outside; recursive=true, force=true)
    end
end

@testset ".done v2: the ledger reads a version-2 marker as before" begin
    done_v2_vault() do vault, _
        k = DataVault.keys(vault)[1]
        mark_done!(vault, k; result=DataVault.save!(vault, k, Dict("x" => 1.0)))
        f = done_fields(vault, k)
        DataVault.build_ledger(vault)
        row = only(DataVault.load_ledger(vault))
        @test row["completed_at"] == f["completed"]
        @test row["git_hash"] == f["git_hash"]
    end
end
