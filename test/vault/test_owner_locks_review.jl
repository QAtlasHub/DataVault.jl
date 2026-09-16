# Holes the owner-stamped locks of 0.8.1 still had, found by reviewing the published release.
#
# 0.8.1's own tests only ever called a verb AFTER a reclaim had fully completed. Nothing exercised
# the verb that ends a key's life, and nothing interleaved a reclaim with a verb already in flight.

using DataVault, ParamIO, Test, Dates

const _RV_CONFIG = joinpath(@__DIR__, "fixtures", "study.toml")

function with_lost_lock(f)
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; outdir=outdir)
        k = DataVault.keys(v)[1]
        A, B = new_owner_token(), new_owner_token()
        @assert acquire_running!(v, k, A; stale_after=0.3) === :ok
        sleep(0.5)
        @assert acquire_running!(v, k, B; stale_after=0.3) === :reclaimed
        f(v, k, A, B)
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "mark_done!: the loser cannot commit over the winner" begin
    # No race is needed for this one, only a key slow enough to lose its lock: the two-argument
    # form deletes whatever `.running` is there and commits, so a stalled master finishing its
    # superseded computation takes out the live sibling's lock.
    with_lost_lock() do v, k, A, B
        @test mark_done!(v, k, A) == false
        @test is_running(v, k)                       # B's lock survives
        @test running_owner(v, k) == B
        @test !is_done(v, k)                         # and nothing was committed

        @test mark_done!(v, k, B) == true            # the winner still can
        @test is_done(v, k)
        @test !is_running(v, k)
    end
end

@testset "mark_done!: the owner-blind form still behaves as before" begin
    # Kept deliberately, so the new form is additive. This pins that the hazard is a property of
    # the two-argument form and not something the three-argument one merely papers over.
    with_lost_lock() do v, k, A, B
        mark_done!(v, k)                             # owner-blind: deletes B's lock
        @test !is_running(v, k)
        @test is_done(v, k)
    end
end

@testset "refresh_running!: a reclaim MID-CALL cannot reach the winner's file" begin
    # The interleaving 0.8.1 never tested: the loser reads the file, the reclaim lands, and only
    # then does the loser write. Reopening the PATH to write would truncate the winner's inode.
    # Reproduced by splitting the verb's own halves around a real reclaim.
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; outdir=outdir)
        k = DataVault.keys(v)[1]
        path = DataVault._running_file(v, k)
        A, B = "hostA:111:aaaa", "hostB:222:bbbb"

        @test acquire_running!(v, k, A; stale_after=0.3) === :ok
        io = open(path, "r+")                        # the loser's read half, still open
        lines = readlines(io)
        @test any(l -> l == "owner=$A", lines)

        sleep(0.5)
        @test acquire_running!(v, k, B; stale_after=0.3) === :reclaimed
        @test running_owner(v, k) == B

        # The loser's write half, through the descriptor it already held.
        seekstart(io)
        truncate(io, 0)
        for l in lines
            println(io, l)
        end
        close(io)

        @test running_owner(v, k) == B               # the winner's file is untouched
        @test refresh_running!(v, k, B)              # and the winner still holds it
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "clear_running!: the unlink is guarded by the inode, not the name" begin
    with_lost_lock() do v, k, A, B
        @test clear_running!(v, k, A) == false
        @test is_running(v, k)
        @test running_owner(v, k) == B
        @test clear_running!(v, k, B) == true
        @test !is_running(v, k)
    end
end

@testset "no bare catch in the lock code swallows an interrupt" begin
    # The repo already rethrows InterruptException in `vault.jl`; the 0.8.1 lock code did not
    # follow it. This asserts the file itself, because the condition is about code shape.
    src = read(joinpath(pkgdir(DataVault), "src", "io", "status.jl"), String)
    @test !occursin(r"\n\s*catch\s*\n", src)         # no `catch` without a binding
    @test count("e isa InterruptException && rethrow()", src) >= 8
end

@testset "master_ledger_report: a study that could not attach is counted" begin
    # An unattachable study contributes no rows AND no `sources` entry, so without `unattached`
    # a half-readable outdir reports exactly like a complete one.
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; run="phase1", outdir=outdir)
        for k in DataVault.keys(v)[1:2]
            DataVault.save!(v, k, Dict("x" => 1))
            mark_done!(v, k)
        end
        build_ledger(v)

        good = master_ledger_report(outdir)
        @test good.ok
        @test good.discovered == 1
        @test good.unattached == 0

        # Corrupt the anchor so the study cannot be attached at all.
        log = joinpath(outdir, ".datavault", "test_study", "phase1.log.toml")
        write(log, "this is not valid TOML {{{")
        bad = master_ledger_report(outdir)
        @test bad.discovered == 1
        @test bad.unattached == 1
        @test isempty(bad.rows)
        @test !bad.ok                                # and `ok` reflects it
    finally
        rm(outdir; recursive=true, force=true)
    end
end
