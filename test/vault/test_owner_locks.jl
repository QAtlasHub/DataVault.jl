# Owner-stamped .running locks (#21): the two hazards the owner-blind API leaves open.

using DataVault, ParamIO, Test

const _OL_CONFIG = joinpath(@__DIR__, "fixtures", "study.toml")

function with_ol(f)
    outdir = mktempdir()
    try
        v = Vault(_OL_CONFIG; outdir=outdir)
        f(v, DataVault.keys(v)[1])
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "owner: a token identifies the acquisition, not the process" begin
    a, b = new_owner_token(), new_owner_token()
    @test a != b                                   # same host, same pid
    @test occursin(string(getpid()), a)
    @test count(==(':'), a) == 2
end

@testset "owner: acquire stamps it, and the 2-arg form does not" begin
    with_ol() do v, k
        tok = new_owner_token()
        @test acquire_running!(v, k, tok) === :ok
        @test running_owner(v, k) == tok
        clear_running!(v, k)

        @test acquire_running!(v, k) === :ok
        @test running_owner(v, k) === nothing       # unstamped, as before
        clear_running!(v, k)

        @test running_owner(v, k) === nothing       # absent file
    end
end

@testset "owner: acquire returns the same symbols as before" begin
    with_ol() do v, k
        @test acquire_running!(v, k, new_owner_token()) === :ok
        @test acquire_running!(v, k, new_owner_token()) === :busy
        # Stale: reclaimable, and the reclaimer's token replaces the previous one.
        b = new_owner_token()
        @test acquire_running!(v, k, b; stale_after=0.0) === :reclaimed
        @test running_owner(v, k) == b
    end
end

@testset "hazard 1: after a reclaim, the loser's refresh is false and writes nothing" begin
    with_ol() do v, k
        a = new_owner_token()
        @test acquire_running!(v, k, a) === :ok

        b = new_owner_token()
        @test acquire_running!(v, k, b; stale_after=0.0) === :reclaimed   # B takes it over
        before = read(DataVault._running_file(v, k), String)

        # A's heartbeat, after losing. The file EXISTS, so the owner-blind form returns true and
        # stamps A's clock onto B's file; the owner-aware form must not.
        @test refresh_running!(v, k, a) == false
        @test read(DataVault._running_file(v, k), String) == before
        @test running_owner(v, k) == b

        # Control: the owner-blind form on the same state does the wrong thing, which is why the
        # three-argument form exists rather than being a stylistic preference.
        @test refresh_running!(v, k) == true
    end
end

@testset "hazard 2: after a reclaim, the loser's clear does not delete the winner's lock" begin
    with_ol() do v, k
        a = new_owner_token()
        acquire_running!(v, k, a)
        b = new_owner_token()
        acquire_running!(v, k, b; stale_after=0.0)

        @test clear_running!(v, k, a) == false
        @test is_running(v, k)                       # B's lock survives
        @test running_owner(v, k) == b

        @test clear_running!(v, k, b) == true
        @test !is_running(v, k)

        @test clear_running!(v, k, b) == false       # idempotent, reports it removed nothing
    end
end

@testset "owner: the holder's own refresh succeeds and moves the heartbeat" begin
    with_ol() do v, k
        tok = new_owner_token()
        acquire_running!(v, k, tok)
        t0 = running_heartbeat(v, k)
        sleep(1.1)
        @test refresh_running!(v, k, tok) == true
        @test running_heartbeat(v, k) > t0
        @test running_owner(v, k) == tok             # refresh preserves the stamp
    end
end

@testset "owner: an unstamped lock is neither refreshed nor cleared by a token holder" begin
    # A `.running` from mark_running! or from a pre-owner version carries no token. It cannot be
    # shown to be ours, so neither verb touches it; stale_after is what reclaims it.
    with_ol() do v, k
        mark_running!(v, k)
        @test running_owner(v, k) === nothing
        tok = new_owner_token()
        @test refresh_running!(v, k, tok) == false
        @test clear_running!(v, k, tok) == false
        @test is_running(v, k)
        @test acquire_running!(v, k, tok; stale_after=0.0) === :reclaimed
    end
end

@testset "owner: an absent file is refused by every owner-aware verb" begin
    with_ol() do v, k
        tok = new_owner_token()
        acquire_running!(v, k, tok)
        clear_running!(v, k)                         # gone
        @test !is_running(v, k)
        @test running_owner(v, k) === nothing
        @test refresh_running!(v, k, tok) == false
        @test clear_running!(v, k, tok) == false
    end
end

@testset "owner: a truncated .running is not treated as ours" begin
    # A partial write from a crashed acquire has no `owner=` line, so it must read as unowned
    # rather than as a match on whatever did land.
    with_ol() do v, k
        tok = new_owner_token()
        acquire_running!(v, k, tok)
        path = DataVault._running_file(v, k)
        write(path, "pid=1\nstarted=2026-09-15T00:00:00\n")   # heartbeat and owner lost
        @test running_owner(v, k) === nothing
        @test refresh_running!(v, k, tok) == false
        @test clear_running!(v, k, tok) == false
        @test is_running(v, k)
    end
end

@testset "owner: readonly still refuses the owner-aware forms" begin
    outdir = mktempdir()
    try
        w = Vault(_OL_CONFIG; outdir=outdir)
        k = DataVault.keys(w)[1]
        tok = new_owner_token()
        acquire_running!(w, k, tok)

        r = Vault(_OL_CONFIG; outdir=outdir, readonly=true)
        @test_throws ArgumentError acquire_running!(r, k, tok)
        @test_throws ArgumentError refresh_running!(r, k, tok)
        @test_throws ArgumentError clear_running!(r, k, tok)
        @test running_owner(r, k) == tok             # reading is not writing
    finally
        rm(outdir; recursive=true, force=true)
    end
end
