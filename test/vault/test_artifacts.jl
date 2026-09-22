# [artifacts.<name>] — built once per identity, reused across cells, vaults and runs.

using DataVault, ParamIO, Test, JLD2, TOML, Dates

function _av_config(dir; version=1, depends_on="[\"U\", \"D\"]")
    path = joinpath(dir, "config_v$(version).toml")
    write(
        path,
        """
        [study]
        project_name = "artifacts_study"
        [datavault]
        path_keys = ["run.U", "run.D", "run.omega1"]
        [[paramsets]]
        [paramsets.run]
        U      = [0.0, 0.2]
        D      = [8, 16]
        omega1 = [1.0, 2.0, 3.0]
        [artifacts.gs]
        depends_on = $depends_on
        version    = $version
        """,
    )
    return path
end

function with_av(f)
    dir = mktempdir()
    try
        f(dir, Vault(_av_config(dir); outdir=joinpath(dir, "out"), run="a"))
    finally
        rm(dir; recursive=true, force=true)
    end
end

_gs(akey) = (U=param(akey, "run.U"), D=param(akey, "run.D"))

@testset "artifact!: built once per identity, not once per cell" begin
    with_av() do dir, v
        builds = Ref(0)
        keys = DataVault.keys(v)
        @test length(keys) == 12
        for k in keys
            got = artifact!(v, :gs, k) do akey
                builds[] += 1
                _gs(akey)
            end
            @test got == (U=param(k, "run.U"), D=param(k, "run.D"))   # the RIGHT one, not just one
        end
        @test builds[] == 4
        for k in keys
            artifact!(_ -> (builds[] += 1), v, :gs, k)
        end
        @test builds[] == 4                                         # the second pass only loads
        @test all(k -> has_artifact(v, :gs, k), keys)
    end
end

@testset "artifact!: reused by another run, and rebuilt when version changes" begin
    with_av() do dir, v
        k = first(DataVault.keys(v))
        artifact!(_gs, v, :gs, k)
        other_run = Vault(_av_config(dir); outdir=joinpath(dir, "out"), run="b")
        @test artifact!(_ -> error("must not rebuild"), other_run, :gs, k) == _gs(k)

        v2 = Vault(_av_config(dir; version=2); outdir=joinpath(dir, "out"), run="a")
        rebuilt = Ref(false)
        artifact!(v2, :gs, k) do akey
            rebuilt[] = true
            _gs(akey)
        end
        @test rebuilt[]
        @test DataVault.artifact_dir(v2, :gs, k) != DataVault.artifact_dir(v, :gs, k)
    end
end

@testset "artifact!: the builder sees only the declared parameters" begin
    with_av() do dir, v
        k = first(DataVault.keys(v))
        @test_throws Exception artifact!(akey -> param(akey, "run.omega1"), v, :gs, k)
        # ...and the failure left nothing behind: no payload, no lock.
        @test !has_artifact(v, :gs, k)
        @test !isfile(joinpath(DataVault.artifact_dir(v, :gs, k), ".building"))
        @test artifact!(_gs, v, :gs, k) == _gs(k)                   # so the next call builds
    end
end

@testset "artifact!: inputs.toml says what it was built from" begin
    with_av() do dir, v
        k = first(DataVault.keys(v))
        artifact!(_gs, v, :gs, k)
        t = TOML.parsefile(joinpath(DataVault.artifact_dir(v, :gs, k), "inputs.toml"))
        @test t["identity"] == ParamIO.artifact_identity(v.spec, :gs, k)
        @test t["version"] == 1
        @test Set(Base.keys(t["params"])) == Set(["run.U", "run.D"])
    end
    # A value TOML cannot hold is written as its repr, element-wise inside a vector, so
    # inputs.toml never fails to serialise the parameters it describes.
    @test DataVault._toml_safe([1, :a]) == [1, ":a"]
    @test DataVault._toml_safe(1 + 2im) == "1 + 2im"
    @test TOML.parse(sprint(TOML.print, Dict("p" => DataVault._toml_safe([0.5, :x]))))["p"] ==
        [0.5, ":x"]
end

@testset "artifact!: a readonly vault loads but never builds" begin
    with_av() do dir, v
        ks = DataVault.keys(v)
        artifact!(_gs, v, :gs, ks[1])
        ro = Vault(_av_config(dir); outdir=joinpath(dir, "out"), run="a", readonly=true)
        @test artifact!(_ -> error("must not build"), ro, :gs, ks[1]) == _gs(ks[1])
        miss = only(
            filter(
                k ->
                    param(k, "run.U") != param(ks[1], "run.U") &&
                    param(k, "run.D") != param(ks[1], "run.D") &&
                    param(k, "run.omega1") == 1.0,
                ks,
            ),
        )
        @test_throws ErrorException artifact!(_gs, ro, :gs, miss)
        @test tryload_artifact(ro, :gs, miss) === nothing
        @test_throws ErrorException load_artifact(ro, :gs, miss)
    end
end

@testset "artifact!: a held lock is busy; a stale one is reclaimed" begin
    with_av() do dir, v
        k = first(DataVault.keys(v))
        lock = joinpath(DataVault.artifact_dir(v, :gs, k), ".building")
        tok = new_owner_token()
        @test DataVault._acquire_lock_at!(lock, tok) === :ok
        err = try
            artifact!(_gs, v, :gs, k; wait=false)
        catch e
            e
        end
        @test err isa ArtifactBusy
        @test err.identity == ParamIO.artifact_identity(v.spec, :gs, k)
        @test occursin("\"gs\" is being built elsewhere", sprint(showerror, err))
        @test_throws ErrorException artifact!(_gs, v, :gs, k; poll=0.05, timeout=0.2)
        # The control for the reclaim: the same held lock, now older than `stale_after`.
        @test artifact!(_gs, v, :gs, k; stale_after=0.0, heartbeat_interval=-1.0) == _gs(k)
        @test !isfile(lock)
    end
end

@testset "artifact!: concurrent callers build once" begin
    with_av() do dir, v
        k = first(DataVault.keys(v))
        builds = Threads.Atomic{Int}(0)
        slow = akey -> (Threads.atomic_add!(builds, 1); sleep(0.5); _gs(akey))
        tasks = [@async artifact!(slow, v, :gs, k; poll=0.05) for _ in 1:4]
        @test all(==(_gs(k)), fetch.(tasks))
        @test builds[] == 1
    end
end

@testset "artifact!: a payload stored under another identity is refused" begin
    with_av() do dir, v
        k = first(DataVault.keys(v))
        artifact!(_gs, v, :gs, k)
        f = joinpath(DataVault.artifact_dir(v, :gs, k), "artifact.jld2")
        jldsave(f; value=:wrong, identity="gs@v1|something else")
        @test_throws ErrorException load_artifact(v, :gs, k)
        @test_throws ErrorException artifact!(_gs, v, :gs, k)
    end
end

@testset "artifact!: the heartbeat advances while a build computes without yielding" begin
    # The reason the heartbeat is a child PROCESS: a task inside Julia does not run here. Under
    # the old in-process task this age was the whole build (≈ 3 s); a live heartbeat keeps it
    # within an interval plus the lock's one-second resolution.
    with_av() do dir, v
        k = first(DataVault.keys(v))
        lock = joinpath(DataVault.artifact_dir(v, :gs, k), ".building")
        age = artifact!(v, :gs, k; heartbeat_interval=0.3, stale_after=10.0) do _
            t0 = time()
            x = 0.0
            while time() - t0 < 3.0
                for i in 1:(10 ^ 6)
                    x += sin(i)
                end
            end
            line = only(filter(startswith("heartbeat="), readlines(lock)))
            (Dates.now() - Dates.DateTime(line[11:end], "yyyy-mm-ddTHH:MM:SS")).value / 1000
        end
        @test age < 2.0
    end
end
