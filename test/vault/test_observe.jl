using SHA, TOML

# observe_sources: a content snapshot with a stable identity, kept apart from its binding to the
# code the process loaded.

const _OBS_CFG = joinpath(@__DIR__, "fixtures", "study.toml")

git!(repo, args...) = run(`git -C $repo -c user.name=t -c user.email=t@t $args`)

# A git repo holding the config, a small package, and a .gitignore; a vault writing elsewhere.
function with_observed_repo(f)
    repo = mktempdir()
    out = mktempdir()
    name = "ObsProbe" * string(time_ns(); base=16)   # not rand: every testset reseeds it
    try
        cp(_OBS_CFG, joinpath(repo, "study.toml"))
        write(joinpath(repo, ".gitignore"), "ignored.txt\n")
        pkg = joinpath(repo, name)
        mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"),
            "name = \"$name\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\nversion = \"0.1.0\"\n",
        )
        write(joinpath(pkg, "src", "$name.jl"), "module $name\nanswer() = 42\nend\n")
        write(joinpath(repo, "notes.dat"), "not source")
        git!(repo, "init", "-q")
        git!(repo, "add", "-A")
        git!(repo, "commit", "-qm", "base")
        f((; repo, out, name, pkg, vault=Vault(joinpath(repo, "study.toml"); outdir=out)))
    finally
        rm(repo; recursive=true, force=true)
        rm(out; recursive=true, force=true)
    end
end

obs_dir(t) = joinpath(t.out, ".datavault", "test_study")
record(t, token) = TOML.parsefile(joinpath(obs_dir(t), "observations", "$token.toml"))
source_of(t) = record(t, observe_sources(t.vault))["source"]
config_root(rec) = only(r for r in rec["roots"] if r["name"] == "config")

@testset "observe_sources: the snapshot's identity is its content" begin
    with_observed_repo() do t
        t1, t2 = observe_sources(t.vault), observe_sources(t.vault)
        @test t1 != t2
        r = record(t, t1)
        @test r["source"] == record(t, t2)["source"]
        snap = joinpath(obs_dir(t), "sources", r["source"])
        @test isfile(joinpath(snap, "COMPLETE"))
        @test "src1-" * bytes2hex(sha256(read(joinpath(snap, "files.tsv")))) == r["source"]
        @test TOML.parsefile(joinpath(snap, "state.toml"))["id"] == r["source"]
        @test occursin(
            "config\tstudy.toml\tfile", read(joinpath(snap, "files.tsv"), String)
        )

        base = r["source"]
        write(joinpath(t.repo, "ignored.txt"), "ignored")
        @test source_of(t) == base                        # ignored files are not source
        git!(t.repo, "commit", "-q", "--allow-empty", "-m", "empty")
        @test source_of(t) == base                        # a new HEAD with the same files: same id
        write(joinpath(t.repo, "extra.jl"), "y = 2\n")
        @test source_of(t) != base                        # an untracked, unignored file is source
        rm(joinpath(t.repo, "extra.jl"))
        write(
            joinpath(t.pkg, "src", "$(t.name).jl"), "module $(t.name)\nanswer() = 43\nend\n"
        )
        @test source_of(t) != base                        # an edited tracked file
    end
end

@testset "observe_sources: only .jl and .toml contents are kept" begin
    with_observed_repo() do t
        observe_sources(t.vault)
        blobs = joinpath(obs_dir(t), "sources", "blobs")
        sha(file) = bytes2hex(sha256(read(file)))
        @test isfile(joinpath(blobs, sha(joinpath(t.pkg, "src", "$(t.name).jl"))))
        @test !isfile(joinpath(blobs, sha(joinpath(t.repo, "notes.dat"))))
    end
end

@testset "observe_sources: a file over the hash limit makes the inventory incomplete" begin
    with_observed_repo() do t
        r = record(t, observe_sources(t.vault; hash_limit=4))
        snap = joinpath(obs_dir(t), "sources", r["source"])
        @test TOML.parsefile(joinpath(snap, "state.toml"))["inventory_complete"] == false
        @test occursin("\tskipped\n", read(joinpath(snap, "files.tsv"), String))
    end
end

@testset "observe_sources: HEAD, dirtiness and the process are recorded, not hashed" begin
    with_observed_repo() do t
        r = record(t, observe_sources(t.vault; process=Dict("worker" => 3)))
        c = config_root(r)
        @test c["head"] == readchomp(`git -C $(t.repo) rev-parse HEAD`)
        @test c["dirty"] == "false"
        @test r["process"]["worker"] == 3 && r["process"]["pid"] == getpid()
        @test r["phase"] == "run-start"
        write(joinpath(t.repo, "extra.jl"), "y = 2\n")
        @test config_root(record(t, observe_sources(t.vault)))["dirty"] == "true"
    end
end

@testset "observe_sources: a loaded package is checked against the snapshot" begin
    with_observed_repo() do t
        pushfirst!(LOAD_PATH, t.pkg)
        try
            mod = Base.require(Main, Symbol(t.name))
            origin = Base.pkgorigins[Base.PkgId(mod)]
            checkable = DataVault._cached_sources(origin.cachepath) !== nothing
            @test config_root(record(t, observe_sources(t.vault)))["loaded"] ==
                (checkable ? "matches" : "unknown")
            # The loaded code stays as it was; the file on disk changes under it.
            write(
                joinpath(t.pkg, "src", "$(t.name).jl"),
                "module $(t.name)\nanswer() = 43\nend\n",
            )
            r = record(t, observe_sources(t.vault))
            @test config_root(r)["loaded"] == (checkable ? "differs" : "unknown")
            checkable && @test r["binding"] == "loaded-differs-from-disk"
        finally
            filter!(!=(t.pkg), LOAD_PATH)
        end
    end
end

# The package of `with_observed_repo`, loaded, with `f(t, mod)`; `checkable` when its cache header can
# be read in this Julia (otherwise every claim must stay unverified).
function with_loaded_probe(f)
    with_observed_repo() do t
        pushfirst!(LOAD_PATH, t.pkg)
        try
            mod = Base.require(Main, Symbol(t.name))
            origin = Base.pkgorigins[Base.PkgId(mod)]
            f(t, mod, DataVault._cached_sources(origin.cachepath) !== nothing)
        finally
            filter!(!=(t.pkg), LOAD_PATH)
        end
    end
end

script_defined(k) = 1

@testset "observe_sources: unverified unless the entry code is named and checked" begin
    with_loaded_probe() do t, mod, checkable
        r = record(t, observe_sources(t.vault))
        @test r["binding"] == "unverified"
        @test any(contains("no entry code was named"), r["binding_reasons"])

        answer = getfield(mod, :answer)
        r = record(t, observe_sources(t.vault; code=[answer]))
        @test r["binding"] == (checkable ? "loaded-matches-disk" : "unverified")
        @test only(r["code"])["module"] == t.name && !only(r["code"])["captures"]
        @test config_root(r)["loaded_matches_head"] == (checkable ? "true" : "unknown")

        for (entry, why) in (
            (script_defined, r"defined in Main|no readable precompile cache"),
            (
                let a = 2
                    k -> a + k
                end,
                r"captures values",
            ),
            (sum, r"no readable precompile cache|not loaded from a source root"),
        )
            r = record(t, observe_sources(t.vault; code=[entry]))
            @test r["binding"] == "unverified"
            @test any(contains(why), r["binding_reasons"])
        end

        # A method added to the package from outside its files: the entry is unchanged on disk,
        # but what it calls is not what the files say.
        Core.eval(mod, :(helper() = 0))
        r = record(t, observe_sources(t.vault; code=[answer]))
        @test r["binding"] == "unverified"
        @test any(contains("outside $(t.name)'s checked sources"), r["binding_reasons"])
    end
end

@testset "observe_sources: loaded code that HEAD does not hold is told apart" begin
    with_loaded_probe() do t, mod, checkable
        checkable || return nothing
        # The loaded file stays byte-identical on disk, but is no longer what HEAD holds.
        git!(t.repo, "rm", "-q", "--cached", joinpath(t.pkg, "src", "$(t.name).jl"))
        git!(t.repo, "commit", "-qm", "untrack")
        r = record(t, observe_sources(t.vault; code=[getfield(mod, :answer)]))
        @test config_root(r)["loaded"] == "matches"
        @test config_root(r)["loaded_matches_head"] == "false"
    end
end

@testset "binding_of: what an observation may claim" begin
    ok = Dict("config" => "matches", "pkg:A:1" => "matches")
    @test DataVault.binding_of(ok, false, String[]) == ("loaded-matches-disk", String[])
    @test DataVault.binding_of(Dict("config" => "differs"), false, String[])[1] ==
        "loaded-differs-from-disk"
    for (status, revise, code) in (
        (Dict("config" => "unknown"), false, String[]),
        (Dict("config" => "not-loaded", "pkg:A:1" => "matches"), false, String[]),
        (ok, true, String[]),
        (ok, false, ["work is defined in Main"]),
    )
        binding, reasons = DataVault.binding_of(status, revise, code)
        @test binding == "unverified" && !isempty(reasons)
    end
end

@testset "observe_sources: the token goes into .done, and discovery is undisturbed" begin
    with_observed_repo() do t
        v = t.vault
        k = DataVault.keys(v)[1]
        token = observe_sources(v)
        mark_done!(v, k; result=DataVault.save!(v, k, Dict("x" => 1.0)), observation=token)
        line(key) = only(
            l for
            l in eachline(DataVault._done_file(v, key)) if startswith(l, "observation=")
        )
        @test line(k) == "observation=$token"
        k2 = DataVault.keys(v)[2]
        mark_done!(v, k2)
        @test line(k2) == "observation=unknown"
        @test length(DataVault.find_log_tomls(t.out)) == 1
        @test !any(endswith(".log.toml"), readdir(joinpath(obs_dir(t), "observations")))
    end
end
