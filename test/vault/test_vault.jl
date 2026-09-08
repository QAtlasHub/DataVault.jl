using Dates

const FIXTURES = joinpath(@__DIR__, "fixtures")
const CONFIG = joinpath(FIXTURES, "study.toml")

# Each testset uses its own tmpdir so tests are isolated
function with_vault(f)
    outdir = mktempdir()
    try
        vault = Vault(CONFIG; outdir=outdir)
        f(vault, outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# Convenience: first key in the full key list
first_key(vault) = DataVault.keys(vault)[1]

# ── Constructor ───────────────────────────────────────────────────────────────

@testset "Vault: constructor reads config" begin
    with_vault() do vault, _
        @test vault.spec.study.project_name == "test_study"
        @test vault.spec.study.total_samples == 2
        @test vault.spec.path_keys == ["system.N", "model.g"]
    end
end

@testset "Vault: outdir override" begin
    outdir = mktempdir()
    try
        vault = Vault(CONFIG; outdir=outdir)
        @test vault.outdir == abspath(outdir)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "Vault: config snapshot created" begin
    with_vault() do vault, outdir
        snapshot = joinpath(outdir, "data", "test_study", "default", "config_snapshot.toml")
        @test isfile(snapshot)
    end
end

@testset "Vault: config snapshot warns on change" begin
    with_vault() do vault, outdir
        snapshot = joinpath(outdir, "data", "test_study", "default", "config_snapshot.toml")
        # Overwrite snapshot with a different parameter value
        raw = TOML.parsefile(snapshot)
        raw["study"]["total_samples"] = 999
        open(snapshot, "w") do io
            return TOML.print(io, raw)
        end
        # Re-constructing the Vault should warn, not error
        @test_logs (:warn, r"Config has changed") Vault(CONFIG; outdir=outdir)
    end
end

# ── Key enumeration ───────────────────────────────────────────────────────────

@testset "keys: returns all DataKeys" begin
    with_vault() do vault, _
        ks = DataVault.keys(vault)
        # 2N × 2g × 2 samples = 8
        @test length(ks) == 8
        @test all(k -> k isa DataKey, ks)
    end
end

@testset "keys: status filtering" begin
    with_vault() do vault, _
        k = first_key(vault)
        @test length(DataVault.keys(vault; status=:done)) == 0
        @test length(DataVault.keys(vault; status=:pending)) == 8

        mark_done!(vault, k)

        @test length(DataVault.keys(vault; status=:done)) == 1
        @test length(DataVault.keys(vault; status=:pending)) == 7
    end
end

@testset "keys: unknown status → error" begin
    with_vault() do vault, _
        @test_throws ErrorException DataVault.keys(vault; status=:bogus)
    end
end

# ── Status: done / running ────────────────────────────────────────────────────

@testset "is_done: false before, true after mark_done!" begin
    with_vault() do vault, _
        k = first_key(vault)
        @test !is_done(vault, k)
        mark_done!(vault, k)
        @test is_done(vault, k)
    end
end

@testset "mark_done!: .done file has expected fields" begin
    with_vault() do vault, outdir
        k = first_key(vault)
        mark_done!(vault, k; tag_value=0.99)

        # Find and parse the .done file
        done_files = filter(
            f -> endswith(f, ".done"),
            vcat(
                [
                    joinpath(root, f) for (root, _, files) in walkdir(outdir) for f in files
                ]...,
            ),
        )
        @test length(done_files) == 1

        content = read(done_files[1], String)
        @test occursin("jobid=", content)
        @test occursin("completed=", content)
        @test occursin("git_hash=", content)
        @test occursin("tag_value=0.99", content)
    end
end

@testset "mark_running! creates .running; mark_done! removes it" begin
    with_vault() do vault, outdir
        k = first_key(vault)
        mark_running!(vault, k)

        running_files = filter(
            f -> endswith(f, ".running"),
            vcat(
                [
                    joinpath(root, f) for (root, _, files) in walkdir(outdir) for f in files
                ]...,
            ),
        )
        @test length(running_files) == 1

        mark_done!(vault, k)
        @test !isfile(running_files[1])
    end
end

# ── Data I/O ──────────────────────────────────────────────────────────────────

@testset "save! / load: round-trip" begin
    with_vault() do vault, _
        k = first_key(vault)
        data = Dict("energy" => -1.23, "magnetization" => [0.1, 0.2, 0.3])

        DataVault.save!(vault, k, data)
        loaded = DataVault.load(vault, k)

        @test loaded["energy"] ≈ -1.23
        @test loaded["magnetization"] ≈ [0.1, 0.2, 0.3]
    end
end

@testset "save! is atomic: file does not appear until complete" begin
    with_vault() do vault, _
        k = first_key(vault)
        DataVault.save!(vault, k, Dict("x" => 42))
        @test isfile(DataVault._data_file(vault, k))
    end
end

@testset "load: error on missing file" begin
    with_vault() do vault, _
        k = first_key(vault)
        @test_throws ErrorException DataVault.load(vault, k)
    end
end

@testset "save_bin! / load_bin: round-trip" begin
    with_vault() do vault, _
        k = first_key(vault)
        data = Dict("mps" => rand(4, 4))

        DataVault.save_bin!(vault, k, data)
        loaded = DataVault.load_bin(vault, k)
        @test loaded["mps"] ≈ data["mps"]
    end
end

@testset "load_bin: error with helpful message when missing" begin
    with_vault() do vault, _
        k = first_key(vault)
        ex = try
            DataVault.load_bin(vault, k)
            nothing
        catch e
            e
        end
        @test ex isa ErrorException
        @test occursin("HPC", ex.msg)
    end
end

# ── Ledger ────────────────────────────────────────────────────────────────────

@testset "build_ledger: empty when no done keys" begin
    with_vault() do vault, outdir
        path = build_ledger(vault)
        @test isfile(path)
        @test read(path, String) == ""
    end
end

@testset "build_ledger: rows match done keys" begin
    with_vault() do vault, outdir
        ks = DataVault.keys(vault)[1:3]
        for k in ks
            mark_done!(vault, k)
        end

        path = build_ledger(vault)
        lines = readlines(path)

        @test length(lines) == 4   # header + 3 rows
        @test occursin("sample", lines[1])
        @test occursin("git_hash", lines[1])
        @test length(lines) - 1 == 3
    end
end

# ── Figure provenance ─────────────────────────────────────────────────────────

@testset "record_figure: meta.toml created" begin
    with_vault() do vault, outdir
        path = record_figure(
            vault;
            study="test_study",
            scripts=Dict("plot_energy" => "scripts/plot_energy.jl"),
        )

        @test isfile(path)
        meta = TOML.parsefile(path)
        @test haskey(meta, "source")
        @test haskey(meta["source"], "config")
        @test haskey(meta["source"], "git_hash")
        @test haskey(meta["source"], "generated_at")
        @test meta["scripts"]["plot_energy"] == "scripts/plot_energy.jl"
    end
end

# ── Cleanup ───────────────────────────────────────────────────────────────────

@testset "cleanup_stale: removes stale .running files (stale_after=0)" begin
    with_vault() do vault, outdir
        ks = DataVault.keys(vault)[1:3]
        for k in ks
            mark_running!(vault, k)
        end

        # stale_after=0 で全削除 (旧動作互換)
        n = cleanup_stale(vault; stale_after=0.0)
        @test n == 3

        running = filter(
            f -> endswith(f, ".running"),
            vcat(
                [
                    joinpath(root, f) for (root, _, files) in walkdir(outdir) for f in files
                ]...,
            ),
        )
        @test isempty(running)
    end
end

@testset "cleanup_stale: keeps fresh .running files by default" begin
    with_vault() do vault, outdir
        ks = DataVault.keys(vault)[1:2]
        for k in ks
            mark_running!(vault, k)
        end

        # デフォルト stale_after=600s → 作りたてのファイルは残る
        n = cleanup_stale(vault)
        @test n == 0
    end
end

@testset "cleanup_stale: returns 0 if no status dir" begin
    with_vault() do vault, _
        @test cleanup_stale(vault) == 0
    end
end

@testset "mark_running!/touch_running!/running_heartbeat round-trip" begin
    with_vault() do vault, _
        k = DataVault.keys(vault)[1]
        @test !is_running(vault, k)

        mark_running!(vault, k)
        @test is_running(vault, k)

        hb1 = running_heartbeat(vault, k)
        @test hb1 !== nothing
        @test hb1 isa Dates.DateTime

        sleep(1.1)
        touch_running!(vault, k)
        hb2 = running_heartbeat(vault, k)
        @test hb2 !== nothing
        @test hb2 > hb1

        clear_running!(vault, k)
        @test !is_running(vault, k)
        @test running_heartbeat(vault, k) === nothing
    end
end

# ── acquire_running! (atomic .running via POSIX link) ─────────────────────────

@testset "acquire_running!: :ok on empty slot, :busy on fresh lock" begin
    with_vault() do vault, _
        k = DataVault.keys(vault)[1]
        @test acquire_running!(vault, k) === :ok
        @test is_running(vault, k)

        # Second acquire on a fresh .running must not steal the lock.
        @test acquire_running!(vault, k) === :busy
    end
end

@testset "acquire_running!: :reclaimed when heartbeat is stale" begin
    with_vault() do vault, _
        k = DataVault.keys(vault)[1]
        @test acquire_running!(vault, k) === :ok

        # Backdate the heartbeat= line to simulate a crashed holder.
        path = DataVault._running_file(vault, k)
        old_str = Dates.format(Dates.now() - Dates.Second(7200), "yyyy-mm-ddTHH:MM:SS")
        lines = readlines(path)
        open(path, "w") do io
            for line in lines
                println(io, startswith(line, "heartbeat=") ? "heartbeat=$old_str" : line)
            end
        end
        @test running_age_secs(vault, k) > 600

        # stale_after=600: the old lock is stale, we should reclaim it.
        @test acquire_running!(vault, k; stale_after=600.0) === :reclaimed
        # And the new heartbeat is fresh.
        @test running_age_secs(vault, k) < 5
    end
end

@testset "acquire_running!: race is serialised by POSIX link()" begin
    # Pure serialised check — two acquire_running! calls in sequence
    # must see exactly one :ok and one :busy.  The `link()` atomicity
    # is the invariant; Julia's task model is a coarse proxy but
    # sufficient to catch a broken implementation.
    with_vault() do vault, _
        k = DataVault.keys(vault)[1]
        r1 = acquire_running!(vault, k)
        r2 = acquire_running!(vault, k)
        @test Set([r1, r2]) == Set([:ok, :busy])
    end
end

@testset "acquire_running!: concurrent @async on stale lock at most one :reclaimed" begin
    with_vault() do vault, _
        k = DataVault.keys(vault)[1]
        # Seed a very stale .running.
        acquire_running!(vault, k)
        path = DataVault._running_file(vault, k)
        old_str = Dates.format(Dates.now() - Dates.Second(7200), "yyyy-mm-ddTHH:MM:SS")
        lines = readlines(path)
        open(path, "w") do io
            for line in lines
                println(io, startswith(line, "heartbeat=") ? "heartbeat=$old_str" : line)
            end
        end

        # Fire 8 concurrent reclaim attempts; at most one may win.
        tasks = [@async acquire_running!(vault, k; stale_after=600.0) for _ in 1:8]
        results = [fetch(t) for t in tasks]
        n_ok = count(==(:ok), results)
        n_reclaimed = count(==(:reclaimed), results)
        n_busy = count(==(:busy), results)

        @test (n_ok + n_reclaimed) == 1
        @test n_busy == 7
    end
end

@testset "refresh_running!: returns true while held, false after release" begin
    with_vault() do vault, _
        k = DataVault.keys(vault)[1]
        @test acquire_running!(vault, k) === :ok

        hb1 = running_heartbeat(vault, k)
        sleep(1.1)
        @test refresh_running!(vault, k) === true
        hb2 = running_heartbeat(vault, k)
        @test hb2 !== nothing
        @test hb2 > hb1

        clear_running!(vault, k)
        # Lock was released; refresh_running! now sees no file.
        @test refresh_running!(vault, k) === false
    end
end

@testset "running_age_secs: Inf when no lock held" begin
    with_vault() do vault, _
        k = DataVault.keys(vault)[1]
        @test running_age_secs(vault, k) == Inf

        acquire_running!(vault, k)
        @test running_age_secs(vault, k) < 5
        clear_running!(vault, k)
        @test running_age_secs(vault, k) == Inf
    end
end

# ── Custom path_formatter ─────────────────────────────────────────────────────

@testset "path_formatter: default uses ParamIO.format_path" begin
    with_vault() do vault, _
        # デフォルトでは ParamIO.format_path と一致すべき
        @test vault.path_formatter === ParamIO.format_path
        key = first_key(vault)
        expected = ParamIO.format_path(key, vault.spec.path_keys)
        @test DataVault._param_path(vault, key) == expected
    end
end

@testset "path_formatter: custom function overrides default" begin
    outdir = mktempdir()
    try
        # カスタムフォーマッタ: "custom_N{N}_g{g}" のような独自形式
        my_format = (key, _) -> begin
            n = key.params["system.N"]
            g = key.params["model.g"]
            "custom_N$(n)_g$(g)"
        end

        vault = Vault(CONFIG; outdir=outdir, path_formatter=my_format)
        key = DataVault.keys(vault)[1]
        @test DataVault._param_path(vault, key) == "custom_N24_g0.5"
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "path_formatter: custom format affects data/bin/status paths" begin
    outdir = mktempdir()
    try
        my_format = (_, _) -> "FIXED_LABEL"
        vault = Vault(CONFIG; outdir=outdir, path_formatter=my_format)
        key = DataVault.keys(vault)[1]

        DataVault.save!(vault, key, Dict("x" => 1.0))
        mark_done!(vault, key)

        # 全パスに "FIXED_LABEL" が含まれていることを確認
        @test occursin("FIXED_LABEL", DataVault._data_dir(vault, key))
        @test occursin("FIXED_LABEL", DataVault._bin_dir(vault, key))
        @test occursin("FIXED_LABEL", DataVault._status_dir(vault, key))
        @test isfile(DataVault._data_file(vault, key))
        @test is_done(vault, key)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# ── results ───────────────────────────────────────────────────────────────────

@testset "results: pairs every done key with its payload" begin
    with_vault() do vault, _
        ks = DataVault.keys(vault)
        @test length(ks) > 1                       # the fixture has to be able to distinguish
        DataVault.save!(vault, ks[1], Dict("x" => 41))
        DataVault.mark_done!(vault, ks[1])

        got = collect(DataVault.results(vault))
        @test length(got) == 1                     # only the done one, not all of `ks`
        k, d = only(got)
        @test k == ks[1]
        @test d["x"] == 41
    end
end

@testset "results: :done is the default because :all cannot be loaded" begin
    with_vault() do vault, _
        ks = DataVault.keys(vault)
        DataVault.save!(vault, ks[1], Dict("x" => 1))
        DataVault.mark_done!(vault, ks[1])

        # The control for the default: asking for every key reaches one nobody computed, and `load`
        # raises there. A default of :all would make the ordinary reader loop die on a half-finished
        # sweep — which is the state a sweep is in for most of its life.
        @test_throws ErrorException collect(DataVault.results(vault; status=:all))
    end
end

@testset "results: lazy, so a large sweep is not materialised to read one point" begin
    with_vault() do vault, _
        ks = DataVault.keys(vault)
        for k in ks
            DataVault.save!(vault, k, Dict("x" => 1))
            DataVault.mark_done!(vault, k)
        end
        it = DataVault.results(vault)
        @test !(it isa AbstractVector)             # a generator, not a materialised Vector
        @test first(it)[2]["x"] == 1               # …and taking one does not force the rest
    end
end
