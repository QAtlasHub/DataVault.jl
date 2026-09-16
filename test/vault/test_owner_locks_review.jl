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
        # `stat` on a missing path returns a ZEROED struct rather than throwing, so a `UInt64(0)`
        # standing for "could not read it" would compare equal here and pass the guard. The
        # sentinel is `nothing` for that reason, and `nothing` is refused before any comparison.
        @test stat(path).inode == UInt64(0)
        @test DataVault._still_inode(path, UInt64(0))     # the trap, shown to be real
        @test !DataVault._still_inode(path, nothing)      # and the sentinel that avoids it
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
    for f in
        ("src/io/status.jl", "src/util/query.jl", "src/io/atomic.jl", "src/util/cleanup.jl")
        src = read(joinpath(pkgdir(DataVault), f), String)
        # `catch` with no binding, whatever follows it on the line. The earlier spelling required a
        # newline straight after, so `catch  # swallow` slipped through.
        @test !occursin(r"(?m)^\s*catch\s*(#.*)?$", src)
        # Every `catch e` in these files must let an interrupt through, either by testing for it or
        # by rethrowing unconditionally. Counted, because naming them individually is how two of
        # them vanished unnoticed.
        guarded =
            count("e isa InterruptException && rethrow()", src) + count("rethrow(e)", src)
        @test count("catch e", src) == guarded
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

struct ThrowsOnClose <: IO
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
    # made `unattached` negative, or cancelled out a genuine attach failure so that `ok`
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

@testset "a cleanup unlink that fails does not replace an answer already decided" begin
    # `_close_quietly` was added for `close`; the `rm`s that tidy up AFTER a verb has decided its
    # return had the same shape and were missed. `force=true` swallows only ENOENT, so a read-only
    # directory still throws, and from a `finally` that throw replaces the pending `return`.
    dir = mktempdir()
    try
        sub = joinpath(dir, "ro")
        mkpath(sub)
        victim = joinpath(sub, "f")
        write(victim, "x")
        chmod(sub, 0o555)

        @test_throws Base.IOError rm(victim; force=true)    # the trap, shown to be real
        @test (@test_logs (:warn, r"removing a lock file failed") DataVault._rm_quietly(
            victim
        )) === nothing
        chmod(sub, 0o755)
        @test DataVault._rm_quietly(victim) === nothing     # control: silent when it works
        @test !isfile(victim)
    finally
        rm(dir; recursive=true, force=true)
    end
end

@testset "an unreadable lock is stale, and does not abandon the rest of the sweep" begin
    # `_running_age_secs` fell back to `mtime`, which stats the path, so it failed on exactly the
    # faults that broke the read it was the fallback for. And `cleanup_stale` had no per-file
    # isolation, so one such lock aborted the whole reaper: item 1 of 40 looks like "nothing to do".
    outdir = mktempdir()
    try
        v = Vault(_RV_CONFIG; outdir=outdir)
        ks = DataVault.keys(v)[1:2]
        for k in ks
            @test acquire_running!(v, k, new_owner_token()) === :ok
        end
        paths = [DataVault._running_file(v, k) for k in ks]
        blocked = dirname(paths[1])

        # Age the locks so the reaper would want them, then make the first one unreadable.
        for p in paths
            write(p, "pid=1\nstarted=2000-01-01T00:00:00\nheartbeat=2000-01-01T00:00:00\n")
        end
        @test isfinite(DataVault._running_age_secs(paths[1], Dates.now()))   # control

        chmod(blocked, 0o000)
        age = DataVault._running_age_secs(paths[1], Dates.now())
        chmod(blocked, 0o755)
        @test age == Inf                            # maximally stale, not a throw, not 0.0

        # The sweep survives a lock it cannot remove and still reaps the ones it can.
        if dirname(paths[2]) != blocked
            chmod(blocked, 0o555)                   # the unlink of paths[1] will fail
            n = cleanup_stale(v; stale_after=1.0)
            chmod(blocked, 0o755)
            @test n >= 1                            # it did not abort at the first failure
        else
            @test cleanup_stale(v; stale_after=1.0) == 2
        end
    finally
        rm(outdir; recursive=true, force=true)
    end
end

@testset "mark_done!: a reclaim DURING the call is refused, not committed over" begin
    # The interleaving this whole file exists for, scheduled DETERMINISTICALLY rather than raced.
    # `_done_body` shells out to `git rev-parse`, and it does so after the ownership read and before
    # the inode re-check, so a `git` placed on PATH that performs the reclaim lands exactly in the
    # window. Without this, deleting either `_still_inode` call left every other testset green: the
    # helper was pinned, but nothing pinned that the verbs still CALL it.
    outdir = mktempdir()
    bin = mktempdir()
    try
        v = Vault(_RV_CONFIG; outdir=outdir)
        k = DataVault.keys(v)[1]
        A, B = new_owner_token(), new_owner_token()
        @test acquire_running!(v, k, A) === :ok
        path = DataVault._running_file(v, k)

        # B's lock, ready to be linked onto the name A is holding.
        other = joinpath(outdir, "B.running")
        write(
            other,
            "pid=2\nstarted=2030-01-01T00:00:00\nheartbeat=2030-01-01T00:00:00\nowner=$(B)\n",
        )

        fake = joinpath(bin, "git")
        write(
            fake,
            """
            #!/bin/sh
            rm -f '$(path)'
            ln '$(other)' '$(path)'
            echo deadbee
            """,
        )
        chmod(fake, 0o755)

        committed = withenv("PATH" => "$(bin):$(get(ENV, "PATH", ""))") do
            mark_done!(v, k, A)
        end

        @test committed == false                 # A lost the lock partway through its own call
        @test !is_done(v, k)                      # and did NOT commit its result over B's
        @test is_running(v, k)                    # B's lock survived ...
        @test running_owner(v, k) == B            # ... and is still B's

        # Control: the same call with an ordinary `git` commits, so `false` above is the reclaim
        # and not the fixture refusing for some unrelated reason.
        @test mark_done!(v, k, running_owner(v, k)) == true
        @test is_done(v, k)
        @test !is_running(v, k)
    finally
        rm(outdir; recursive=true, force=true)
        rm(bin; recursive=true, force=true)
    end
end

@testset "every destructive step in the owner-checked verbs is inode-guarded" begin
    # The guard's SEMANTICS are pinned by the `_still_inode` testset, and one of its windows is
    # pinned behaviourally by the mid-call reclaim above. The others are a single syscall wide and
    # cannot be scheduled from a unit test. What is pinned here is that the call sites still exist:
    # a mutation run found that deleting one of them left every other testset in this file green.
    src = read(joinpath(pkgdir(DataVault), "src", "io", "status.jl"), String)
    lines = split(src, '\n')
    code(i) = !startswith(strip(lines[i]), "#") && !isempty(strip(lines[i]))

    # The guard must be on the act's own line or the one code line before it. A wider window lets
    # a DIFFERENT act's guard vouch for this one: `_rm_quietly(running)` sits three lines after
    # `write(done, body)`'s guard, so a three-line window called it guarded after its own was cut.
    function guarded(act::AbstractString)
        at = [i for i in eachindex(lines) if code(i) && occursin(act, lines[i])]
        isempty(at) && return false                      # the act vanished: not "vacuously guarded"
        return all(at) do i
            prev = findlast(j -> code(j), 1:(i - 1))
            occursin("_still_inode", lines[i]) ||
                (prev !== nothing && occursin("_still_inode", lines[prev]))
        end
    end

    @test guarded("write(done, body)")                   # the .done commit
    @test guarded("_rm_quietly(running)")                # and the lock deletion that follows it
    @test guarded("_rename_into_place(tmp, path)")       # the heartbeat rewrite
    @test !guarded("mkpath(dirname(done))")              # control: an unguarded line reads as such

    # And the replacement itself must stay atomic. `mv(src, dst; force=true)` unlinks the
    # destination first before Julia 1.12, which this package supports, so a crash in the gap
    # leaves the destination ABSENT rather than holding either version.
    for f in ("src/io/status.jl", "src/io/atomic.jl", "src/util/log_toml.jl")
        body = split(read(joinpath(pkgdir(DataVault), f), String), '\n')
        # Code lines only: the comment explaining why `mv` is not used says `mv(`.
        @test !any(l -> !startswith(strip(l), "#") && occursin(r"\bmv\(", l), body)
    end
    @test occursin(
        "ccall(:rename", read(joinpath(pkgdir(DataVault), "src/io/atomic.jl"), String)
    )
end
