using SHA, TOML

# observe_sources: a content snapshot with a stable identity, kept apart from its binding to the
# code the process loaded.

const _OBS_CFG = joinpath(@__DIR__, "fixtures", "study.toml")

git!(repo, args...) = run(`git -C $repo -c user.name=t -c user.email=t@t $args`)

# A git repo holding the config, a small package, and a .gitignore; a vault writing elsewhere.
function with_observed_repo(f)
    repo = mktempdir()
    out = mktempdir()
    name = "ObsProbe" * string(rand(UInt32); base=16)
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

@testset "observe_sources: contents are kept by size, and .jl/.toml at any size" begin
    sha(file) = bytes2hex(sha256(read(file)))
    with_observed_repo() do t
        observe_sources(t.vault)
        blobs = joinpath(obs_dir(t), "sources", "blobs")
        @test isfile(joinpath(blobs, sha(joinpath(t.pkg, "src", "$(t.name).jl"))))
        # A data file a package reads is source too; an extension list would drop it silently.
        @test isfile(joinpath(blobs, sha(joinpath(t.repo, "notes.dat"))))
    end
    with_observed_repo() do t
        r = record(t, observe_sources(t.vault; materialize_limit=4))
        blobs = joinpath(obs_dir(t), "sources", "blobs")
        @test isfile(joinpath(blobs, sha(joinpath(t.pkg, "src", "$(t.name).jl"))))
        @test !isfile(joinpath(blobs, sha(joinpath(t.repo, "notes.dat"))))
        state = TOML.parsefile(joinpath(obs_dir(t), "sources", r["source"], "state.toml"))
        @test state["materialize_limit"] == 4
    end
end

@testset "observe_sources: the vault's own output inside the study is not source" begin
    repo = mktempdir()
    try
        cp(_OBS_CFG, joinpath(repo, "study.toml"))
        out = joinpath(repo, "out")                     # inside the study, ignored by nothing
        v = Vault(joinpath(repo, "study.toml"); outdir=out)
        k = DataVault.keys(v)[1]
        mark_done!(v, k; result=DataVault.save!(v, k, Dict("x" => 1.0)))
        store = joinpath(out, ".datavault", "test_study")
        r = TOML.parsefile(joinpath(store, "observations", "$(observe_sources(v)).toml"))
        tsv = read(joinpath(store, "sources", r["source"], "files.tsv"), String)
        @test occursin("config\tstudy.toml\t", tsv)
        @test !occursin("config\tout/", tsv)
    finally
        rm(repo; recursive=true, force=true)
    end
end

@testset "observe_sources: a study with its own environment is its own root" begin
    with_observed_repo() do t
        study = joinpath(t.repo, "studies", "one")
        mkpath(study)
        cp(_OBS_CFG, joinpath(study, "study.toml"))
        write(joinpath(study, "Project.toml"), "[deps]\n")
        write(joinpath(t.repo, "studies", "other.jl"), "x = 1\n")   # a neighbour, not this study
        git!(t.repo, "add", "-A")
        git!(t.repo, "commit", "-qm", "studies")
        before = Base.active_project()
        Base.set_active_project(joinpath(study, "Project.toml"))
        try
            v = Vault(joinpath(study, "study.toml"); outdir=t.out)
            r = record(t, observe_sources(v))
            tsv = read(joinpath(obs_dir(t), "sources", r["source"], "files.tsv"), String)
            @test occursin("config\tstudy.toml\t", tsv)
            @test occursin("config\tProject.toml\t", tsv)
            @test !occursin("other.jl", tsv) && !occursin("notes.dat", tsv)
            c = config_root(r)
            @test c["kind"] == "git"
            @test c["head"] == readchomp(`git -C $(t.repo) rev-parse HEAD`)
            @test c["dirty"] == "false"
            write(joinpath(t.repo, "notes.dat"), "changed outside the study")
            @test config_root(record(t, observe_sources(v)))["dirty"] == "false"
        finally
            Base.set_active_project(before)
        end
    end
end

@testset "observe_sources: the packages a computing process loaded are kept" begin
    with_observed_repo() do t
        manifest = DataVault._active_manifest()
        pinned = Dict{String,String}()
        if manifest !== nothing
            for (_, es) in TOML.parsefile(manifest)["deps"], e in es
                haskey(e, "git-tree-sha1") && (pinned[e["uuid"]] = e["git-tree-sha1"])
            end
        end
        # JLD2 is loaded by DataVault itself, from a depot, whenever these tests run.
        uuid = "033835bb-8acc-5ee8-8aae-3f567f8a3819"
        r = record(t, observe_sources(t.vault))
        if haskey(pinned, uuid)
            j = only(x for x in r["roots"] if x["name"] == "pkg:JLD2:$uuid")
            @test j["kind"] == "depot" && j["head"] == pinned[uuid]
            snap = joinpath(obs_dir(t), "sources", r["source"])
            @test occursin(
                "pkg:JLD2:$uuid\tsrc/JLD2.jl\tfile",
                read(joinpath(snap, "files.tsv"), String),
            )
            state = TOML.parsefile(joinpath(snap, "state.toml"))
            @test any(x -> get(x, "tree", "") == j["head"], state["roots"])
        else
            @test_broken haskey(pinned, uuid)        # JLD2 is not pinned by a tree here
        end
        # A render is not the computing process: its plotting stack is not kept by default.
        rr = record(t, observe_sources(t.vault; phase="render"))
        @test !any(x -> x["kind"] == "depot", rr["roots"])
    end
end

@testset "observe_sources: a symlink's target is kept, and so are the artifacts loaded" begin
    with_observed_repo() do t
        symlink("notes.dat", joinpath(t.repo, "link.dat"))
        r = record(t, observe_sources(t.vault))
        blobs = joinpath(obs_dir(t), "sources", "blobs")
        @test isfile(joinpath(blobs, bytes2hex(sha256("notes.dat"))))
        @test read(joinpath(blobs, bytes2hex(sha256("notes.dat"))), String) == "notes.dat"
        # Every artifact root is named by, and pinned to, its tree; and it is one that a loaded
        # depot package's Artifacts.toml selects.
        for a in (x for x in r["roots"] if x["kind"] == "artifact")
            @test startswith(a["name"], "artifact:") && endswith(a["name"], ":" * a["head"])
            @test isdir(a["dir"]) && basename(a["dir"]) == a["head"]
        end
        @test haskey(r, "program")
    end
end

@testset "observe_sources: an artifact that cannot be resolved is said, not dropped" begin
    pkg = mktempdir()
    try
        fake = (
            name="pkg:Fake:00000000-0000-0000-0000-000000000000",
            dir=pkg,
            kind=:depot,
            tree="",
        )
        # Unreadable: a note, which the observation turns into an incomplete inventory.
        write(joinpath(pkg, "Artifacts.toml"), "this is [[ not toml")
        notes = String[]
        @test isempty(DataVault._artifact_roots([fake], notes))
        @test any(n -> occursin("Artifacts.toml could not be resolved", n), notes)
        # Readable but never fetched (lazy): nothing to keep, and nothing wrong either.
        write(joinpath(pkg, "Artifacts.toml"), "[foo]\ngit-tree-sha1 = \"$("0"^40)\"\n")
        notes = String[]
        @test isempty(DataVault._artifact_roots([fake], notes)) && isempty(notes)
    finally
        rm(pkg; recursive=true)
    end
end

@testset "observe_sources: a depot package is kept whole, whatever the size limit" begin
    with_observed_repo() do t
        uuid = "033835bb-8acc-5ee8-8aae-3f567f8a3819"      # JLD2, loaded from a depot
        r = record(t, observe_sources(t.vault; materialize_limit=1))
        snap = joinpath(obs_dir(t), "sources", r["source"])
        rows = [
            split(l, '\t') for
            l in eachline(joinpath(snap, "files.tsv")) if startswith(l, "pkg:JLD2:$uuid\t")
        ]
        if isempty(rows)
            @test_broken !isempty(rows)                    # JLD2 not from a depot here
        else
            # A file that is neither .jl nor .toml and larger than the 1-byte limit.
            other = [
                x for x in rows if x[3] == "file" &&
                    parse(Int, x[5]) > 1 &&
                    !endswith(x[2], ".jl") &&
                    !endswith(x[2], ".toml") &&
                    x[6] != "skipped"
            ]
            @test !isempty(other)
            @test all(x -> isfile(joinpath(obs_dir(t), "sources", "blobs", x[6])), other)
        end
    end
end

@testset "observe_sources: `program` is the script `julia <file>` ran" begin
    with_observed_repo() do t
        script = joinpath(t.repo, "run.jl")
        before = PROGRAM_FILE
        @eval Base PROGRAM_FILE = $script
        try
            @test record(t, observe_sources(t.vault))["program"] == abspath(script)
        finally
            @eval Base PROGRAM_FILE = $before
        end
        @test record(t, observe_sources(t.vault))["program"] ==
            (isempty(before) ? "" : abspath(before))
    end
end

@testset "observe_sources: which Julia binary, and BLAS's thread count" begin
    with_observed_repo() do t
        j = record(t, observe_sources(t.vault))["julia"]
        @test j["blas_threads"] == DataVault.LinearAlgebra.BLAS.get_num_threads()
        @test occursin(r"^[0-9a-f]{64}$", j["executable_sha256"])
        @test j["bindir"] == Sys.BINDIR
        @test !isempty(j["platform"]) && !isempty(j["blas_libraries"])
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
            r0 = record(t, observe_sources(t.vault))
            @test config_root(r0)["loaded"] == (checkable ? "matches" : "unknown")
            @test r0["binding"] == "unverified"         # a match is recorded, never claimed
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

@testset "binding_of: what an observation may claim" begin
    ok = Dict("config" => "matches", "pkg:A:1" => "matches")
    # Everything checkable matched, and still no match is claimed.
    @test DataVault.binding_of(ok, false, String[]) ==
        ("unverified", [DataVault.NO_MATCH_CLAIMED])
    @test DataVault.binding_of(Dict("config" => "differs"), false, String[])[1] ==
        "loaded-differs-from-disk"
    for (status, revise, main) in (
        (Dict("config" => "unknown"), false, String[]),
        (Dict("config" => "not-loaded", "pkg:A:1" => "matches"), false, String[]),
        (ok, true, String[]),
        (ok, false, ["/repo/scripts/compute.jl"]),
    )
        binding, reasons = DataVault.binding_of(status, revise, main)
        @test binding == "unverified" && !isempty(reasons)
    end
end

@testset "observe_sources: the token goes into .done, and discovery is undisturbed" begin
    with_observed_repo() do t
        v = t.vault
        k = DataVault.keys(v)[1]
        token = observe_sources(v)
        mark_done!(v, k; result=DataVault.save!(v, k, Dict("x" => 1.0)), observation=token)
        function line(key)
            return only(
                l for
                l in eachline(DataVault._done_file(v, key)) if startswith(l, "observation=")
            )
        end
        @test line(k) == "observation=$token"
        k2 = DataVault.keys(v)[2]
        mark_done!(v, k2)
        @test line(k2) == "observation=unknown"
        @test length(DataVault.find_log_tomls(t.out)) == 1
        @test !any(endswith(".log.toml"), readdir(joinpath(obs_dir(t), "observations")))
    end
end
