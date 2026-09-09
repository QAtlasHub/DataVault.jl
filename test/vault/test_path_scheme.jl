# The path scheme: `[datavault] float_format`, what log.toml remembers about it, and the
# collision check that runs when the formatter and the grid first meet.

using Dates
using Logging: Logging

# A silence assertion is `@test_logs min_level=Logging.Warn expr` with NO pattern and the
# DEFAULT match_mode. Adding `match_mode=:any` makes it vacuous — the patterns only have to be
# a subset of what was logged, and the empty set always is, so a warning slips through.

const SCHEME_DIR = mktempdir()

# A grid whose float axis is FINER than `%.2f` can resolve. That is the discriminating shape:
# under fixed2 these four dt values render as "0.01", "0.01", "0.00", "0.00".
function scheme_config(
    dir::AbstractString; float_format=nothing, dt=[1.0e-2, 5.0e-3, 2.5e-3, 1.25e-3]
)
    path = joinpath(dir, "cfg.toml")
    ff = float_format === nothing ? "" : "float_format = \"$(float_format)\"\n"
    write(
        path,
        """
        [study]
        project_name  = "scheme"
        total_samples = 1
        outdir        = "$(escape_string(joinpath(dir, "out")))"

        [datavault]
        path_keys = ["system.a", "numerics.dt"]
        $(ff)
        [[paramsets]]

        [paramsets.system]
        a = [1.0]

        [paramsets.numerics]
        dt = $(dt)
        """,
    )
    return path
end

# The directories a vault would actually create, one per DISTINCT parameter point.
function param_paths(vault)
    return Set(DataVault._param_path(vault, k) for k in ParamIO.expand(vault.spec))
end

@testset "float_format=auto separates points fixed2 collapses" begin
    d = mktempdir(SCHEME_DIR)
    # Control first: the default really does collapse them, so the auto case below is not
    # passing for some unrelated reason.
    v_fixed = Vault(
        scheme_config(joinpath(mkpath(joinpath(d, "f")))); run="phase1", check_paths=false
    )
    @test length(param_paths(v_fixed)) == 2          # 4 points -> 2 directories
    @test v_fixed.path_formatter === ParamIO.format_path

    v_auto = Vault(
        scheme_config(joinpath(mkpath(joinpath(d, "a"))); float_format="auto");
        run="phase1",
        check_paths=false,
    )
    @test length(param_paths(v_auto)) == 4           # …and auto keeps all four apart
    @test v_auto.path_formatter isa DataVault.AutoPathFormatter
end

@testset "auto reaches the data, not just the path string" begin
    d = mktempdir(SCHEME_DIR)
    cfg = scheme_config(d; float_format="auto")
    vault = Vault(cfg; run="phase1", check_paths=false)
    for k in ParamIO.expand(vault.spec)
        DataVault.save!(vault, k, Dict("dt" => k.params["numerics.dt"]))
        mark_done!(vault, k)
    end
    # Every point survives its neighbours: under fixed2 two of these four reads return
    # another point's payload.
    got = sort([DataVault.load(vault, k)["dt"] for k in ParamIO.expand(vault.spec)])
    @test got == sort([1.0e-2, 5.0e-3, 2.5e-3, 1.25e-3])
end

@testset "log.toml remembers the scheme, and it outranks the config" begin
    d = mktempdir(SCHEME_DIR)
    out = joinpath(d, "out")

    # A run written under the default scheme…
    cfg_default = scheme_config(joinpath(mkpath(joinpath(d, "c1"))))
    v1 = Vault(cfg_default; run="phase1", outdir=out, check_paths=false)
    key = first(ParamIO.expand(v1.spec))
    DataVault.save!(v1, key, Dict("x" => 1.0))
    mark_done!(v1, key)
    info = read_log_toml(DataVault._log_toml_path(out, "scheme", "phase1"))
    @test info.path_scheme == "default"

    # …stays on it when the config is later switched to auto, so the data stays reachable.
    cfg_auto = scheme_config(joinpath(mkpath(joinpath(d, "c2"))); float_format="auto")
    v2 = @test_logs (:warn, r"different path scheme") match_mode = :any Vault(
        cfg_auto; run="phase1", outdir=out, check_paths=false
    )
    @test v2.path_formatter === ParamIO.format_path
    @test is_done(v2, key)                       # the point above is still found

    # A NEW run name is the documented way to sweep under the new scheme.
    v3 = Vault(cfg_auto; run="phase2", outdir=out, check_paths=false)
    @test v3.path_formatter isa DataVault.AutoPathFormatter
    @test read_log_toml(DataVault._log_toml_path(out, "scheme", "phase2")).path_scheme ==
        "auto"
end

@testset "auto is recorded as reproducible, not as a custom formatter" begin
    d = mktempdir(SCHEME_DIR)
    cfg = scheme_config(d; float_format="auto")
    # The "custom path_formatter" warning must NOT fire for a scheme the config declares.
    vault = @test_logs min_level = Logging.Warn Vault(cfg; run="phase1", check_paths=false)
    info = read_log_toml(DataVault._log_toml_path(vault.outdir, "scheme", "phase1"))
    @test info.path_scheme == "auto"
    @test info.path_formatter == "ParamIO.format_path(auto)"
end

@testset "an explicit path_formatter still wins over both" begin
    d = mktempdir(SCHEME_DIR)
    cfg = scheme_config(d; float_format="auto")
    mine = (_, _) -> "FIXED_LABEL"
    vault = Vault(cfg; run="phase1", path_formatter=mine, check_paths=false)
    @test vault.path_formatter === mine
    @test length(param_paths(vault)) == 1
end

@testset "construction warns when the grid collides — and stays quiet when it does not" begin
    d = mktempdir(SCHEME_DIR)
    # Fires: four points, two directories.
    @test_logs (:warn, r"claimed by more than one parameter point") match_mode = :any Vault(
        scheme_config(joinpath(mkpath(joinpath(d, "bad")))); run="phase1"
    )
    # Control: the SAME grid under auto, where nothing collides — a check that cannot stay
    # quiet is not a check.
    @test_logs min_level = Logging.Warn Vault(
        scheme_config(joinpath(mkpath(joinpath(d, "ok"))); float_format="auto");
        run="phase1",
    )
    # Second control: a fixed2 grid whose values `%.2f` CAN separate.
    @test_logs min_level = Logging.Warn Vault(
        scheme_config(joinpath(mkpath(joinpath(d, "coarse"))); dt=[0.1, 0.05, 0.02, 0.01]);
        run="phase1",
    )
    # …and the knob turns it off.
    @test_logs min_level = Logging.Warn Vault(
        scheme_config(joinpath(mkpath(joinpath(d, "off")))); run="phase1", check_paths=false
    )
end

# ── the paths that report a failure, which must not report success ────────────

@testset "a run written with a custom formatter says so when reopened without one" begin
    d = mktempdir(SCHEME_DIR)
    out = joinpath(d, "out")
    cfg = scheme_config(d)
    Vault(
        cfg; run="phase1", outdir=out, path_formatter=(_, _) -> "LABEL", check_paths=false
    )

    # log.toml records "custom" and cannot reproduce the function. Reopening must SAY that
    # rather than quietly resolve a different scheme and look in the wrong directory.
    v = @test_logs (:warn, r"custom path_formatter, which log.toml cannot reproduce") match_mode =
        :any Vault(cfg; run="phase1", outdir=out, check_paths=false)
    @test v.path_formatter === ParamIO.format_path
end

@testset "an unreadable log.toml is reported, not read as 'no record'" begin
    d = mktempdir(SCHEME_DIR)
    out = joinpath(d, "out")
    cfg = scheme_config(d; float_format="auto")
    Vault(cfg; run="phase1", outdir=out, check_paths=false)

    # Corrupt the anchor. Falling back silently would resolve the scheme from the config and
    # could point at directories this run's data is not in.
    log_path = DataVault._log_toml_path(out, "scheme", "phase1")
    write(log_path, "this is not toml [[[")
    @test_logs (:warn, r"log.toml unreadable") match_mode = :any try
        Vault(cfg; run="phase1", outdir=out, check_paths=false)
    catch                                  # _save_log_toml then fails on the same file
    end
end

@testset "a grid the check cannot scan is reported as unchecked, never as clean" begin
    d = mktempdir(SCHEME_DIR)
    exploding = (_, _) -> error("formatter blew up")
    @test_logs (:warn, r"Could not check the grid") match_mode = :any Vault(
        scheme_config(d); run="phase1", path_formatter=exploding
    )
end

@testset "more collisions than the warning lists are counted, not dropped" begin
    d = mktempdir(SCHEME_DIR)
    # Eight dt values, pairwise indistinguishable under %.2f -> four colliding directories,
    # one more than the three the message shows.
    dt = [0.011, 0.0111, 0.021, 0.0211, 0.031, 0.0311, 0.041, 0.0411]
    msg = (:warn, r"and 1 more")
    @test_logs msg match_mode = :any Vault(scheme_config(d; dt=dt); run="phase1")
end

# ── the public path API ───────────────────────────────────────────────────────

@testset "the exported accessors are the vault's own paths" begin
    d = mktempdir(SCHEME_DIR)
    vault = Vault(scheme_config(d); run="phase1", check_paths=false)
    key = first(ParamIO.expand(vault.spec))

    @test param_path(vault, key) == DataVault._param_path(vault, key)
    @test data_dir(vault, key) == DataVault._data_dir(vault, key)
    @test data_file(vault, key) == DataVault._data_file(vault, key)
    @test data_file(vault, key; prefix="aux") ==
        DataVault._data_file(vault, key; prefix="aux")
    @test status_dir(vault, key) == DataVault._status_dir(vault, key)
    @test bin_dir(vault, key) == DataVault._bin_dir(vault, key)

    # …and they are the directory `save!` really used, not a plausible-looking string.
    DataVault.save!(vault, key, Dict("x" => 1.0))
    @test isdir(data_dir(vault, key))
    @test isfile(data_file(vault, key))
end

@testset "the accessors follow the scheme; a hand-built path does not" begin
    d = mktempdir(SCHEME_DIR)
    vault = Vault(scheme_config(d; float_format="auto"); run="phase1", check_paths=false)
    keys4 = ParamIO.expand(vault.spec)

    # This is the line the twelve benchmark scripts write. It cannot see `float_format`, so it
    # collapses four points onto two directories while the vault keeps them apart.
    hand_built(k) = joinpath(
        vault.outdir,
        "data",
        vault.spec.study.project_name,
        vault.run,
        ParamIO.format_path(k, vault.spec.path_keys),
    )
    @test length(Set(hand_built(k) for k in keys4)) == 2
    @test length(Set(data_dir(vault, k) for k in keys4)) == 4

    # Concretely: for at least one key the hand-built path is not where the data is.
    k = last(keys4)
    DataVault.save!(vault, k, Dict("x" => 1.0))
    @test isdir(data_dir(vault, k))
    @test !isdir(hand_built(k))
end

# ── reading is not writing ────────────────────────────────────────────────────

@testset "attach and open_all do not re-run the write-side grid check" begin
    d = mktempdir(SCHEME_DIR)
    out = joinpath(d, "out")
    cfg = scheme_config(d)                     # a grid that DOES collide

    # Writing warns, once, where the sweep starts.
    @test_logs (:warn, r"claimed by more than one parameter point") match_mode = :any Vault(
        cfg; run="phase1", outdir=out
    )

    # Reading it back must not. `open_all` attaches once per run, so a colliding study would
    # otherwise re-warn on every discovery for the rest of its life.
    @test_logs min_level = Logging.Warn attach(out; project="scheme", run="phase1")
    @test_logs min_level = Logging.Warn open_all(out)
    @test length(open_all(out)) == 1
end

rm(SCHEME_DIR; recursive=true, force=true)
