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

# A one-axis auto sweep, so the derived precision is easy to state.
function auto_dt_config(dir::AbstractString, dts; out=joinpath(dir, "out"), name="cfg.toml")
    path = joinpath(dir, name)
    write(
        path,
        """
        [study]
        project_name  = "ext"
        total_samples = 1
        outdir        = "$(escape_string(out))"

        [datavault]
        path_keys = ["numerics.dt"]
        float_format = "auto"

        [[paramsets]]

        [paramsets.numerics]
        dt = $(dts)
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

@testset "the path accessors are public but NOT exported" begin
    exported = names(DataVault)
    for n in (:param_path, :data_dir, :data_file, :status_dir, :bin_dir)
        @test isdefined(DataVault, n)      # public: documented, callable, part of the API
        @test !(n in exported)             # but qualified, so it cannot collide downstream
    end

    # The reason, as a live check rather than a comment. `data_dir` is a name a study naturally
    # gives its own accessor — FiniteTemperature defines and exports one on its own vault type.
    # Exporting it here too leaves the name unresolvable for anyone who uses both.
    @eval module _StudyLike
    using DataVault
    struct StudyVault end
    data_dir(::StudyVault, key) = "the study's own layout"
    export data_dir
    end
    @eval module _UserScript
    using DataVault
    using ..._StudyLike
    probe() = data_dir(_StudyLike.StudyVault(), nothing)
    end
    @test _UserScript.probe() == "the study's own layout"
end

@testset "the accessors are the vault's own paths" begin
    d = mktempdir(SCHEME_DIR)
    vault = Vault(scheme_config(d); run="phase1", check_paths=false)
    key = first(ParamIO.expand(vault.spec))

    @test DataVault.param_path(vault, key) == DataVault._param_path(vault, key)
    @test DataVault.data_dir(vault, key) == DataVault._data_dir(vault, key)
    @test DataVault.data_file(vault, key) == DataVault._data_file(vault, key)
    @test DataVault.data_file(vault, key; prefix="aux") ==
        DataVault._data_file(vault, key; prefix="aux")
    @test DataVault.status_dir(vault, key) == DataVault._status_dir(vault, key)
    @test DataVault.bin_dir(vault, key) == DataVault._bin_dir(vault, key)

    # …and they are the directory `save!` really used, not a plausible-looking string.
    DataVault.save!(vault, key, Dict("x" => 1.0))
    @test isdir(DataVault.data_dir(vault, key))
    @test isfile(DataVault.data_file(vault, key))
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
    @test length(Set(DataVault.data_dir(vault, k) for k in keys4)) == 4

    # Concretely: for at least one key the hand-built path is not where the data is.
    k = last(keys4)
    DataVault.save!(vault, k, Dict("x" => 1.0))
    @test isdir(DataVault.data_dir(vault, k))
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

# ── growing an auto sweep must not orphan what it already computed ────────────

@testset "auto precision is pinned by log.toml, not re-derived from the config" begin
    d = mktempdir(SCHEME_DIR)
    out = joinpath(d, "out")

    v1 = Vault(
        auto_dt_config(d, [0.01, 0.005]; out=out, name="a.toml");
        run="phase1",
        check_paths=false,
    )
    for k in ParamIO.expand(v1.spec)
        DataVault.save!(v1, k, Dict("dt" => k.params["numerics.dt"]))
        mark_done!(v1, k)
    end
    @test length(DataVault.keys(v1; status=:done)) == 2
    rec = read_log_toml(DataVault._log_toml_path(out, "ext", "phase1")).path_float_precision
    @test rec == Dict("numerics.dt" => 3)      # 0.005 needs three decimals, 0.01 two

    # Grow the sweep by one finer point — the ordinary way a study advances. Re-deriving the
    # precision would renumber 0.010 -> 0.0100 and lose both finished points.
    v2 = @test_logs (:warn, r"implies a different float precision") match_mode = :any Vault(
        auto_dt_config(d, [0.01, 0.005, 0.0025]; out=out, name="b.toml");
        run="phase1",
        check_paths=false,
    )
    @test length(DataVault.keys(v2; status=:done)) == 2       # kept
    @test length(DataVault.keys(v2; status=:pending)) == 1    # only the new point
    @test DataVault.param_path(v2, first(ParamIO.expand(v1.spec))) ==
        DataVault.param_path(v1, first(ParamIO.expand(v1.spec)))
end

@testset "a sweep that grows without changing the precision does not report a mismatch" begin
    d = mktempdir(SCHEME_DIR)
    out = joinpath(d, "out")
    Vault(
        auto_dt_config(d, [0.01, 0.005]; out=out, name="a.toml");
        run="phase1",
        check_paths=false,
    )
    # 0.015 needs three decimals too, so the pinned precision still describes the axis. Asserting
    # TOTAL silence here would be testing the snapshot warning, which fires for its own reasons
    # whenever the config file changes; the claim is about this warning specifically.
    logs, _ = Test.collect_test_logs(; min_level=Logging.Warn) do
        Vault(
            auto_dt_config(d, [0.01, 0.005, 0.015]; out=out, name="b.toml");
            run="phase1",
            check_paths=false,
        )
    end
    @test !any(r -> occursin("different float precision", string(r.message)), logs)
    # …and the control for THAT: the same shape with a precision change does report it.
    logs2, _ = Test.collect_test_logs(; min_level=Logging.Warn) do
        Vault(
            auto_dt_config(d, [0.01, 0.005, 0.0025]; out=out, name="c.toml");
            run="phase1",
            check_paths=false,
        )
    end
    @test any(r -> occursin("different float precision", string(r.message)), logs2)
end

@testset "an auto run written before precision was recorded says so" begin
    d = mktempdir(SCHEME_DIR)
    out = joinpath(d, "out")
    cfg = auto_dt_config(d, [0.01, 0.005]; out=out)
    Vault(cfg; run="phase1", check_paths=false)

    # Strip the record, as a log.toml written by an earlier DataVault would have it. Editing the
    # parsed table rather than the text: it is written as a `[path.float_precision]` sub-table,
    # so a line-oriented substitution silently matches nothing.
    lp = DataVault._log_toml_path(out, "ext", "phase1")
    parsed = TOML.parsefile(lp)
    delete!(parsed["path"], "float_precision")
    open(io -> TOML.print(io, parsed), lp, "w")
    @test isempty(read_log_toml(lp).path_float_precision)
    @test_logs (:warn, r"predates precision recording") match_mode = :any Vault(
        cfg; run="phase1", check_paths=false
    )
end

@testset "a new point that collides at the pinned precision is still reported" begin
    d = mktempdir(SCHEME_DIR)
    out = joinpath(d, "out")
    Vault(
        auto_dt_config(d, [0.01, 0.005]; out=out, name="a.toml");
        run="phase1",
        check_paths=false,
    )
    # Pinned at three decimals, 0.0051 renders as "0.005" — the same directory as 0.005.
    @test_logs (:warn, r"claimed by more than one parameter point") match_mode = :any Vault(
        auto_dt_config(d, [0.01, 0.005, 0.0051]; out=out, name="b.toml"); run="phase1"
    )
end

rm(SCHEME_DIR; recursive=true, force=true)
