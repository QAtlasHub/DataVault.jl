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

@testset "the inode guard refuses a name that was relinked since the read" begin
    # The mechanism that closes the 0.8.1 hazard, tested directly, because the hazard itself is a
    # mid-call interleaving that a unit test cannot schedule. A mutation run confirmed the cost of
    # pretending otherwise: a testset built on an ALREADY-COMPLETED reclaim passes against the
    # 0.8.1 code unchanged, since the owner check rejects the loser before the write is reached.
    dir = mktempdir()
    try
        path = joinpath(dir, "lock")
        write(path, "owner=A\nheartbeat=t0\n")
        ino = stat(path).inode
        @test DataVault._still_inode(path, ino)

        # A reclaim: unlink the name, link a different file onto it.
        other = joinpath(dir, "other")
        write(other, "owner=B\nheartbeat=t1\n")
        rm(path; force=true)
        @test ccall(:link, Cint, (Cstring, Cstring), other, path) == 0
        rm(other; force=true)

        @test isfile(path)                          # the NAME is still there
        @test !DataVault._still_inode(path, ino)    # but not the inode the token came from
        @test DataVault._still_inode(path, stat(path).inode)   # control: it does say yes

        rm(path; force=true)
        @test !DataVault._still_inode(path, ino)    # absent is "no", not an error
    finally
        rm(dir; recursive=true, force=true)
    end
end

@testset "refresh_running!/clear_running!: a completed reclaim is refused at the owner check" begin
    # Weaker than it looks, and labelled so. Both 0.8.1 and 0.8.2 refuse here, because the file
    # already reads `owner=B`; what separates them is the interleaving above. Kept because it
    # pins the ordinary, reachable case.
    with_lost_lock() do v, k, A, B
        before = readlines(DataVault._running_file(v, k))
        @test refresh_running!(v, k, A) == false
        @test readlines(DataVault._running_file(v, k)) == before
        @test clear_running!(v, k, A) == false
        @test is_running(v, k)
        @test running_owner(v, k) == B
        @test refresh_running!(v, k, B) == true     # control: the winner still can
        @test clear_running!(v, k, B) == true
    end
end

@testset "refresh_running!: a failed write leaves the lock untouched" begin
    # Found while writing this PR, in the PR's own first attempt. Rewriting the file in place
    # truncates it first, so a write that fails partway leaves a lock owned by NOBODY, refreshable
    # by nobody, and fresh by mtime until `stale_after` expires: the holder keeps computing while
    # its lock is an orphan. `touch_running!` had the same shape and this file's sibling fix
    # addressed only that one.
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; outdir=outdir)
        k = DataVault.keys(v)[1]
        tok = new_owner_token()
        @test acquire_running!(v, k, tok) === :ok
        path = DataVault._running_file(v, k)
        before = readlines(path)
        @test !isempty(before)

        chmod(dirname(path), 0o555)                  # no temp file can be created here
        failed = refresh_running!(v, k, tok)
        chmod(dirname(path), 0o755)

        @test failed == false                        # reported, not silently "refreshed"
        @test readlines(path) == before              # and the lock is byte-identical
        @test running_owner(v, k) == tok             # still attributable
        @test refresh_running!(v, k, tok) == true    # and usable once the fault clears
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "no bare catch in the lock code swallows an interrupt" begin
    # The repo already rethrows InterruptException in `vault.jl`; the 0.8.1 lock code did not
    # follow it. This asserts the file itself, because the condition is about code shape.
    for f in ("src/io/status.jl", "src/util/query.jl")
        src = read(joinpath(pkgdir(DataVault), f), String)
        # `catch` with no binding, whatever follows it on the line. The earlier spelling required a
        # newline straight after, so `catch  # swallow` slipped through.
        @test !occursin(r"(?m)^\s*catch\s*(#.*)?$", src)
        # Every `catch e` in these files rethrows an interrupt. Counting occurrences instead let
        # two of them vanish unnoticed.
        @test count("catch e", src) == count("e isa InterruptException && rethrow()", src)
    end
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

# The review that produced this file also asked for the behaviours below, which the fixes above
# introduced and nothing exercised: the two new warnings, the readonly refusal on the new verb,
# and interrupt propagation as BEHAVIOUR rather than as a property of the source text.

struct ThrowsOnClose
    e::Exception
end
Base.close(t::ThrowsOnClose) = throw(t.e)

@testset "_close_quietly swallows a close fault but never an interrupt" begin
    # `close` on NFS is where a deferred write-back error surfaces, so a verb promising a `Bool`
    # must absorb it. An interrupt is the one thing it must not absorb: Ctrl-C during a sweep would
    # be reported as a lock that merely failed to close, and the sweep would carry on.
    @test_throws InterruptException DataVault._close_quietly(
        ThrowsOnClose(InterruptException())
    )
    @test (@test_logs (:warn, r"closing a .running descriptor failed") DataVault._close_quietly(
        ThrowsOnClose(ErrorException("simulated NFS write-back failure"))
    )) === nothing
end

@testset "touch_running!: a write that cannot land is reported, not silent" begin
    # The heartbeat is what `cleanup_stale` reads to tell a live job from a crashed one. A
    # heartbeat that silently fails to land makes a working job look abandoned `stale_after` later.
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; outdir=outdir)
        k = DataVault.keys(v)[1]
        @test acquire_running!(v, k, new_owner_token()) === :ok
        path = DataVault._running_file(v, k)

        chmod(path, 0o444)                           # readable, so the rewrite cannot open it
        @test_logs (:warn, r"heartbeat write failed") touch_running!(v, k)
        chmod(path, 0o644)

        @test is_running(v, k)                       # and the lock itself is intact
        @test_logs touch_running!(v, k)              # control: silent when the write can land
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "acquire_running!: a reclaim that cannot unlink is reported, not just :busy" begin
    # A permanent fault here returns `:busy` forever, which reads as healthy contention: the key
    # never runs and nothing says why.
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; outdir=outdir)
        k = DataVault.keys(v)[1]
        @test acquire_running!(v, k, new_owner_token(); stale_after=0.3) === :ok
        sleep(0.5)                                   # now stale, so a reclaim is attempted
        path = DataVault._running_file(v, k)

        chmod(dirname(path), 0o555)                  # unlinking needs write on the DIRECTORY
        got = @test_logs (:warn, r"stale .running could not be reclaimed") acquire_running!(
            v, k, new_owner_token(); stale_after=0.3
        )
        chmod(dirname(path), 0o755)

        @test got === :busy
        @test is_running(v, k)                       # the lock it failed to remove is still there
        # Control: the same call reclaims silently once the fault clears, so the warning is about
        # the fault and not about staleness.
        @test acquire_running!(v, k, new_owner_token(); stale_after=0.3) === :reclaimed
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "mark_done!: the three-argument form refuses a readonly Vault" begin
    # `readonly` is documented as a check rather than a label, which only holds if EVERY write verb
    # passes through the refusal. A verb added later is exactly how that stops being true.
    outdir = mktempdir()
    try
        w = Vault(_RV_CONFIG; outdir=outdir)
        k = DataVault.keys(w)[1]
        tok = new_owner_token()
        @test acquire_running!(w, k, tok) === :ok

        r = Vault(_RV_CONFIG; outdir=outdir, readonly=true)
        @test_throws ArgumentError mark_done!(r, k, tok)
        @test !is_done(r, k)                         # and it really did not write
        @test is_running(r, k)
        @test mark_done!(w, k, tok) == true          # control: the writable vault can
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "open_all attaches the listing it was GIVEN, not the directory as it stands" begin
    # `master_ledger_report` counts `discovered` and then subtracts what attached. When those came
    # from two independent `find_log_tomls` walks, a run started by a sibling master in between
    # made `unattached` negative — and, worse, cancelled out a genuine attach failure so `ok`
    # reported true. Both counts now come from the one listing, which is what this pins.
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; run="phase1", outdir=outdir)
        DataVault.save!(v, DataVault.keys(v)[1], Dict("x" => 1))
        mark_done!(v, DataVault.keys(v)[1])
        build_ledger(v)

        snapshot = find_log_tomls(outdir)
        @test length(snapshot) == 1

        # A sibling master starts a second run while the report is mid-flight.
        v2 = Vault(_RV_CONFIG; run="phase2", outdir=outdir)
        DataVault.save!(v2, DataVault.keys(v2)[1], Dict("x" => 2))
        mark_done!(v2, DataVault.keys(v2)[1])
        build_ledger(v2)

        @test length(find_log_tomls(outdir)) == 2    # the directory moved on
        @test length(open_all(snapshot)) == 1        # the snapshot did not

        # And the report is internally consistent: both numbers come from one listing, so every
        # discovered study is accounted for as either attached or not.
        rep = master_ledger_report(outdir)
        @test rep.discovered == 2
        @test rep.unattached == 0
        @test length(rep.sources) + rep.unattached == rep.discovered
    finally
        rm(outdir; recursive=true, force=true)
    end
end

# Below: the uncovered half of the `catch` blocks this PR touched. Each is a documented contract
# reached with a REAL fault, rather than a line executed to move a coverage number.

@testset "when the answer cannot be shown, the owner forms say no" begin
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; outdir=outdir)
        k = DataVault.keys(v)[1]
        tok = new_owner_token()

        # No lock at all: nothing proves the key is ours, so all three refuse and none writes.
        @test !is_running(v, k)
        @test mark_done!(v, k, tok) == false
        @test !is_done(v, k)
        @test refresh_running!(v, k, tok) == false
        @test clear_running!(v, k, tok) == false

        # `_still_inode` that cannot `stat` is "no", and does not throw out of a `Bool` verb.
        @test acquire_running!(v, k, tok) === :ok
        path = DataVault._running_file(v, k)
        ino = stat(path).inode
        chmod(dirname(path), 0o000)
        blinded = DataVault._still_inode(path, ino)
        chmod(dirname(path), 0o755)
        @test blinded == false
        @test DataVault._still_inode(path, ino)      # control: readable again, and it says yes

        # An unlink that cannot happen is `false` with the lock left intact, not a half-release.
        chmod(dirname(path), 0o555)
        cleared = clear_running!(v, k, tok)
        chmod(dirname(path), 0o755)
        @test cleared == false
        @test is_running(v, k)
        @test running_owner(v, k) == tok
        @test clear_running!(v, k, tok) == true      # control: it can once the fault clears
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "a corrupt heartbeat falls back to mtime instead of throwing" begin
    # `cleanup_stale` reads this to tell a live job from a crashed one. A half-written heartbeat
    # line must not take the sweep down, and must not read as infinitely fresh either.
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; outdir=outdir)
        k = DataVault.keys(v)[1]
        @test acquire_running!(v, k, new_owner_token()) === :ok
        path = DataVault._running_file(v, k)
        @test running_heartbeat(v, k) isa DateTime   # control: it parses when well-formed

        write(path, "pid=1\nheartbeat=NOT-A-DATE\n")
        @test running_heartbeat(v, k) === nothing
        age = DataVault._running_age_secs(path, Dates.now())
        @test isfinite(age) && age >= 0.0            # mtime fallback, not an exception
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "_git_hash outside a repository is \"unknown\", not a failure" begin
    # `.done` records the commit that produced the payload, so a vault living outside any checkout
    # still has to be able to close a key.
    plain, repo = mktempdir(), mktempdir()
    try
        @test DataVault._git_hash(plain) == "unknown"

        # Control: a real repo, built here so the assertion does not depend on how CI checked the
        # package out.
        run(pipeline(`git -C $repo init -q`; stderr=devnull))
        write(joinpath(repo, "f"), "x")
        run(pipeline(`git -C $repo add f`; stderr=devnull))
        run(
            pipeline(
                `git -C $repo -c user.email=t@example.invalid -c user.name=t commit -q -m x`;
                stderr=devnull,
            ),
        )
        @test occursin(r"^[0-9a-f]{7,}$", DataVault._git_hash(repo))
    finally
        rm(plain; recursive=true, force=true)
        rm(repo; recursive=true, force=true)
    end
end
