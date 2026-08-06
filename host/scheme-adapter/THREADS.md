# The `threads` capability — and what its absence means

Part of the portable-scheme-layer epic (#446). CONTRACT.txt's threads tier
names the SRFI-18-shaped primitives every threaded target provides. This
document is the other half: the design for a target WITHOUT threads
(capability `threads` absent — the WASM/browser case is the motivator), and
the semantic requirements a target WITH threads must meet beyond providing
the names. Design only: no degraded implementations exist yet; rounds that
build a threadless target implement against this.

## Degraded semantics, per construct

The rule everywhere: **synchronous, eager, and honest.** A threadless target
runs work at the point that reveals it, and anything that genuinely requires
concurrent progress raises `unsupported` rather than deadlocking or faking.

- **`future` / `future-call`** — the body runs EAGERLY at creation, on the
  calling thread; the future is born realized. `deref` returns immediately;
  `deref` with timeout never times out. `future-cancel` on a realized future
  returns false, matching the JVM's semantics for a completed future — so
  cancellation-dependent code behaves as if it always lost the race, which
  is a legal JVM schedule. Observable divergence: side-effect ORDER — body
  effects happen before the code after the `future` form runs, where a
  threaded run interleaves. That is also a legal JVM schedule, but code
  which parks in `deref` waiting on an effect from AFTER the future's
  creation point (a rendezvous) would have deadlocked threaded too — no
  new deadlocks are introduced, existing rendezvous deadlocks surface
  eagerly at creation instead of at deref.
- **`promise` / `deliver`** — unchanged: a promise is a value cell, no
  thread involved. `deref` on an undelivered promise on a threadless target
  cannot ever be satisfied by another thread, so a blocking deref with no
  timeout raises `unsupported` (a threaded target parks); deref with
  timeout returns the timeout value.
- **agents (`send` / `send-off` / `send-via`)** — the action runs
  SYNCHRONOUSLY at send time, on the calling thread, in send order.
  `await`/`await-for` return immediately (queues are always drained).
  Divergences: (1) actions run on the sender's thread, so an action that
  sends to its own agent recurses instead of queueing — the send-in-action
  case therefore queues to a drain loop at the outermost send, preserving
  Clojure's run-after-commit ordering; the design REQUIRES that drain-loop
  shape, not naive recursion. (2) `*agent*` bindings and error handlers
  behave identically. (3) Throughput semantics (send never blocks the
  caller) are lost — callers observe latency instead; that is the honest
  trade.
- **STM (`dosync`/refs)** — single-threaded transactions cannot conflict;
  commit is direct. The commit-log machinery stays (rollback on throw is
  still real); only contention retry paths become unreachable. No API
  change.
- **`pmap` / `pcalls` / `pvalues`** — degrade to `map`/sequential calls.
  Purely a performance divergence; document, nothing else to do.
- **process-port pump threads** (jolt.process, Redirect handling) — pumps
  exist to move bytes concurrently. Threadless: pumped redirects switch to
  sequential drain at `waitFor`/exit, which preserves correctness for
  bounded output but can deadlock on a child that fills both pipes beyond
  kernel buffers while waiting for reads — EXACTLY the deadlock the JVM
  documents for un-drained Process streams, so we inherit a known JVM
  hazard shape rather than inventing one; the entry point doc must say so.
  Where the platform offers no subprocess at all (browser WASM),
  `sa-run-process` already raises `unsupported` (R3) and jolt.process
  surfaces that cleanly.
- **socket accept loops** (jolt.socket) — blocking accept with no threads
  serves one connection at a time; that is already jolt.socket's documented
  shape, unchanged. A target with no sockets raises from the FFI capability
  (R7), not from here.
- **`Thread/sleep`** — real sleep (contract name `sleep`); a browser target
  without blocking sleep must implement it via its host's synchronous wait
  or reject at the adapter, never busy-wait silently.

## Requirements pinned on THREADED targets (from the R4 site validation)

1. **Thread-parameter inheritance**: a thread created by `fork-thread`
   observes the CREATING thread's current values for every
   `make-thread-parameter` parameter at fork time (Chez semantics). The
   load-bearing dependent is `dyn-binding-stack` (dyn-binding.ss) — Clojure
   binding conveyance into agent-worker forks, async callbacks, and the tap
   delivery thread (concurrency.ss:530) relies on inheritance ALONE
   (future/go/Thread.start forks re-install an explicit snapshot as well, so
   they survive either model). The STM `*txn*` parameter, by contrast, is
   explicitly cleared in 12 of the 13 fork bodies (the async timeout thread
   deliberately doesn't — it runs no ref ops; verified inert), so it only
   needs thread-local parameterize-able storage. An adapter over SRFI-18
   must arrange inheritance explicitly if its native threads don't.
2. **Mutexes need not be recursive**: host code is written to never
   re-acquire a held mutex; a target may provide non-recursive mutexes.
   (Conversely: host code must KEEP that discipline — the portability gate's
   census + the R4 table are the record.)
3. **condition-wait may wake spuriously**: every host wait site re-checks
   its predicate in a loop; targets need not suppress spurious wakeups.
4. **Blocking FFI calls do not stop the world**: a thread parked in a
   `:blocking` foreign call (process wait, socket accept/recv) must not
   prevent other threads from running or the GC from proceeding (Chez
   deactivates the calling thread). A target that cannot guarantee this
   must not claim the `threads` capability together with `ffi`.

Divergence-tracking: any degraded-mode divergence that becomes user-visible
when a threadless target ships gets a known-divergences entry at that point;
the entries above are design commitments, not yet shipped behavior.
