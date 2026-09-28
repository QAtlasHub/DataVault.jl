# The lock protocol (io/lock.jl), tested for what a lock must never do rather than along the path
# that works. Each testset sweeps the parameter the defect lives in, plus one that should not
# matter, and the ones that need a real second process start one.
#
#   time zone of writer and reader  · sub-second phase of the heartbeat × stale_after
#   concurrent reclaimers           · a holder whose work never yields
#   a holder killed with SIGKILL    · a holder that lost its key trying to commit or beat
#   a lock written by an older DataVault

using DataVault, ParamIO, Test, Distributed, Dates

const _LP_CONFIG = joinpath(@__DIR__, "fixtures", "study.toml")

function with_lp(f)
    outdir = mktempdir()
    try
        v = Vault(_LP_CONFIG; outdir=outdir)
        f(v, DataVault.keys(v)[1])
    finally
        rm(outdir; recursive=true, force=true)
    end
end

_lp_path(v, k) = DataVault._running_file(v, k)

function _lp_hb_unix(path)
    try
        for l in eachline(path)
            startswith(l, "heartbeat_unix=") && return parse(Float64, l[16:end])
        end
    catch
    end
    return nothing
end

# Run `f` with the process's zone set to `tz`, as a process started under `TZ=tz` would see it.
function _with_tz(f, tz)
    old = get(ENV, "TZ", nothing)
    ENV["TZ"] = tz
    ccall(:tzset, Cvoid, ())
    try
        return f()
    finally
        old === nothing ? delete!(ENV, "TZ") : (ENV["TZ"] = old)
        ccall(:tzset, Cvoid, ())
    end
end

function _lp_julia(script::AbstractString; threads=1)
    exe = Base.julia_cmd()
    return `$exe --startup-file=no -t $threads --project=$(Base.active_project()) -e $script`
end

# Start `script` in a second Julia and wait until it touches `ready`.
function _lp_spawn(script, ready; threads=1, stdout=devnull)
    p = run(
        pipeline(_lp_julia(script; threads=threads); stdout=stdout, stderr=devnull);
        wait=false,
    )
    t0 = time()
    while !isfile(ready) && process_running(p) && time() - t0 < 180
        sleep(0.05)
    end
    return p
end

@testset "lock: age does not depend on the writer's or the reader's time zone" begin
    # Before heartbeat_unix, a lock written in New York was read 13 h old in Tokyo and taken from a
    # live holder. Both directions, a half-hour zone, and a pair one hour apart.
    pairs = [
        ("America/New_York", "Asia/Tokyo"),
        ("Asia/Tokyo", "America/New_York"),
        ("Europe/London", "Europe/Berlin"),
        ("Asia/Kolkata", "UTC"),
        ("UTC", "Pacific/Kiritimati"),
    ]
    for (wtz, rtz) in pairs
        with_lp() do v, k
            _with_tz(() -> @test(acquire_running!(v, k, new_owner_token()) === :ok), wtz)
            _with_tz(rtz) do
                @test running_age_secs(v, k) < 5.0
                @test acquire_running!(v, k, new_owner_token(); stale_after=600) === :busy
            end
        end
    end
end

@testset "lock: never reclaimable before stale_after, at any sub-second phase" begin
    # Whole-second `heartbeat=` made a lock read up to 1 s older than it was, so a sibling took it
    # early by the fraction of the second it was written in. Sweep that fraction, and stale_after.
    for stale in (0.6, 1.3), phase in (0.05, 0.35, 0.65, 0.95)
        with_lp() do v, k
            while abs(mod(time(), 1.0) - phase) > 0.01
                sleep(0.001)
            end
            @test acquire_running!(v, k, new_owner_token()) === :ok
            t_acq = time()
            got = :busy
            while got === :busy && time() - t_acq < stale + 5
                got = acquire_running!(v, k, new_owner_token(); stale_after=stale)
                got === :busy && sleep(0.01)
            end
            waited = time() - t_acq
            @test got === :reclaimed
            @test waited >= stale - 0.01             # the lock was written before t_acq
            @test waited < stale + 1.0
        end
    end
end

@testset "lock: of concurrent reclaimers, exactly one wins, and it keeps the lock" begin
    # Check-then-rm let two reclaimers both win: 1 round in 300 on a local disk, more on NFS. Each
    # round stages a stale lock and releases N processes on it at one instant.
    nw, rounds = 4, 150
    pids = addprocs(
        nw; exeflags=["--project=$(Base.active_project())", "--startup-file=no"]
    )
    try
        @everywhere pids using DataVault
        outdir = mktempdir()
        try
            v = Vault(_LP_CONFIG; outdir=outdir)
            k = DataVault.keys(v)[1]
            path = _lp_path(v, k)
            mkpath(dirname(path))
            multi = 0
            lost = 0
            none = 0
            for _ in 1:rounds
                write(
                    path,
                    "heartbeat_unix=0946684800.000000\nheartbeat=2000-01-01T00:00:00\n" *
                    "owner=dead:1:0\n",
                )
                go = time() + 0.15
                res = pmap(1:nw) do _
                    tok = DataVault.new_owner_token()
                    while time() < go
                    end
                    r = DataVault._acquire_lock_at!(path, tok; stale_after=600)
                    held = r === :busy || (sleep(0.05); DataVault._owns_lock_at(path, tok))
                    (r, held)
                end
                wins = count(r -> r[1] !== :busy, res)
                wins > 1 && (multi += 1)
                wins == 0 && (none += 1)
                lost += count(r -> r[1] !== :busy && !r[2], res)
                rm(path; force=true)
            end
            @test multi == 0
            @test lost == 0
            @test none == 0                              # and a stale lock does get reclaimed
            @test !isfile(path * ".reclaim")             # no mutex left behind
        finally
            rm(outdir; recursive=true, force=true)
        end
    finally
        rmprocs(pids)
    end
end

@testset "lock: a busy reclaim mutex holds reclaimers off; an abandoned one does not" begin
    with_lp() do v, k
        path = _lp_path(v, k)
        mkpath(dirname(path))
        stale_body = "heartbeat_unix=0946684800.000000\nheartbeat=2000-01-01T00:00:00\nowner=dead:1:0\n"
        write(path, stale_body)
        write(path * ".reclaim", DataVault._hb_header() * "pid=1\n")         # another reclaimer, live
        @test acquire_running!(v, k, new_owner_token()) === :busy
        @test read(path, String) == stale_body                               # untouched
        write(path * ".reclaim", "heartbeat_unix=0946684800.000000\n")      # abandoned in 2000
        tok = new_owner_token()
        @test acquire_running!(v, k, tok) === :reclaimed
        @test running_owner(v, k) == tok
        @test !isfile(path * ".reclaim")
    end
end

@testset "lock: a holder whose work never yields keeps its key (heartbeat child)" begin
    # A heartbeat TASK did not move once during a busy loop, with -t 1, -t 2 and -t 2,1, and the
    # key was taken from a live holder, which then committed it as well. Sweep -t; the child must
    # not care.
    for threads in (1, 2)
        with_lp() do v, k
            ready = joinpath(v.outdir, "ready")
            script = """
            using DataVault
            v = Vault($(repr(_LP_CONFIG)); outdir=$(repr(v.outdir)))
            k = DataVault.keys(v)[1]
            tok = new_owner_token()
            acquire_running!(v, k, tok) === :ok || exit(3)
            hb = start_heartbeat(v, k, tok; interval=0.2)
            touch($(repr(ready)))
            let t = time() + 4.0, x = 0.0
                while time() < t; x += sin(x) + 1e-9; end # never yields
            end
            stop_heartbeat(hb)
            t_commit = time()
            print(mark_done!(v, k, tok) ? "committed " : "refused ", t_commit)
            """
            out = IOBuffer()
            p = _lp_spawn(script, ready; threads=threads, stdout=out)
            @test isfile(ready)
            t_ready = time()
            got_at = Float64[]                           # when a sibling got the key
            tries = 0
            while process_running(p) && !is_done(v, k)
                tok = new_owner_token()
                r = acquire_running!(v, k, tok; stale_after=1.0)
                tries += 1
                if r !== :busy
                    push!(got_at, time())
                    clear_running!(v, k, tok)
                end
                sleep(0.1)
            end
            wait(p)
            said, t_commit = split(String(take!(out)))
            # The holder must really have computed for longer than stale_after while we tried;
            # a holder that died at once would pass without testing anything.
            @test time() - t_ready >= 3.5
            @test tries >= 25
            # Getting the key AFTER the holder released it is correct; before, it is the defect.
            @test count(<(parse(Float64, t_commit)), got_at) == 0
            @test said == "committed"
            @test is_done(v, k)
        end
    end
end

@testset "lock: a holder killed with SIGKILL is reclaimed after stale_after, not before" begin
    for stale in (1.0, 2.0)
        with_lp() do v, k
            ready = joinpath(v.outdir, "ready")
            path = _lp_path(v, k)
            script = """
            using DataVault
            v = Vault($(repr(_LP_CONFIG)); outdir=$(repr(v.outdir)))
            k = DataVault.keys(v)[1]
            tok = new_owner_token()
            acquire_running!(v, k, tok) === :ok || exit(3)
            start_heartbeat(v, k, tok; interval=0.2)
            touch($(repr(ready)))
            sleep(3600)
            """
            p = _lp_spawn(script, ready)
            @test isfile(ready)
            sleep(1.0 + stale)                           # alive and beating for longer than stale
            @test acquire_running!(v, k, new_owner_token(); stale_after=stale) === :busy
            kill(p, Base.SIGKILL)
            wait(p)
            t_kill = time()
            got = :busy
            last_hb = _lp_hb_unix(path)
            while got === :busy && time() - t_kill < stale + 10
                last_hb = something(_lp_hb_unix(path), last_hb)
                got = acquire_running!(v, k, new_owner_token(); stale_after=stale)
                got === :busy && sleep(0.02)
            end
            @test got === :reclaimed
            @test time() - last_hb >= stale              # never before stale_after of silence
            @test time() - t_kill < stale + 1.5          # and the child did stop beating
        end
    end
end

@testset "lock: a holder that lost its key commits nothing and beats nothing" begin
    with_lp() do v, k
        a, b = new_owner_token(), new_owner_token()
        @test acquire_running!(v, k, a) === :ok
        @test acquire_running!(v, k, b; stale_after=0.0) === :reclaimed
        winner = read(_lp_path(v, k), String)

        @test refresh_running!(v, k, a) === false
        @test read(_lp_path(v, k), String) == winner
        @test mark_done!(v, k, a) === false
        @test !is_done(v, k)
        @test running_owner(v, k) == b
        @test clear_running!(v, k, a) === false
        @test running_owner(v, k) == b

        @test mark_done!(v, k, b) === true
        @test is_done(v, k)
        @test !is_running(v, k)
    end

    # The same with the heartbeat child running for the loser: it must stop, not write the
    # winner's file.
    with_lp() do v, k
        a, b = new_owner_token(), new_owner_token()
        @test acquire_running!(v, k, a) === :ok
        hb = start_heartbeat(v, k, a; interval=0.1)
        try
            sleep(0.3)
            @test acquire_running!(v, k, b; stale_after=0.0) === :reclaimed
            winner = read(_lp_path(v, k), String)
            sleep(0.5)
            @test read(_lp_path(v, k), String) == winner
            @test !process_running(hb.proc)             # it saw the name leave its inode
        finally
            stop_heartbeat(hb)
        end
    end
end

@testset "lock: the heartbeat child moves both lines, and stops with its lock" begin
    with_lp() do v, k
        tok = new_owner_token()
        @test acquire_running!(v, k, tok) === :ok
        path = _lp_path(v, k)
        first = readlines(path)
        hb = start_heartbeat(v, k, tok; interval=0.3)
        try
            sleep(1.5)
            now_lines = readlines(path)
            @test _lp_hb_unix(path) > parse(Float64, first[1][16:end]) + 0.5
            @test now_lines[2] != first[2]               # the legacy line an older reader reads
            @test now_lines[3:end] == first[3:end]       # nothing else changes
            @test clear_running!(v, k, tok) === true
            sleep(0.6)
            @test !process_running(hb.proc)
        finally
            stop_heartbeat(hb)
        end
    end
end

@testset "lock: a lock written by an older DataVault is still read and still beaten" begin
    with_lp() do v, k
        path = _lp_path(v, k)
        mkpath(dirname(path))
        now_str = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
        write(path, "pid=1\nstarted=$now_str\nheartbeat=$now_str\nowner=old:1:0\n")
        @test acquire_running!(v, k, new_owner_token(); stale_after=600) === :busy
        @test refresh_running!(v, k, "old:1:0") === true
        @test startswith(read(path, String), "heartbeat_unix=")
        @test running_owner(v, k) == "old:1:0"

        write(path, "pid=1\nstarted=2000-01-01T00:00:00\nheartbeat=2000-01-01T00:00:00\n")
        @test acquire_running!(v, k, new_owner_token(); stale_after=600) === :reclaimed
    end
    # And the other way: what an older reader parses from a new lock.
    legacy = split(DataVault._hb_header(), '\n')[2]
    @test Dates.DateTime(legacy[11:end], "yyyy-mm-ddTHH:MM:SS") isa DateTime
end
