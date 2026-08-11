# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.3] - 2026-08-11

`core.async` names three carriers and jolt has all three now: `io-thread` runs
its body on a fiber. Three fixes are for things that failed quietly rather than
loudly, which is what took them so long to find: `System/exit` off the main
thread did nothing, a stray close paren truncated a file and reported success,
and the one timer behind every `(timeout ms)` could miss its own deadline by the
length of the farthest deadline pending. Three more come from making the real
`clojure.jdbc` run: `with-open` on a `reify`, `(Class/FIELD)` in call position,
and a protocol extended to a class a library declared.

### Added

- **`io-thread` runs its body on a fiber.** It was an alias for `thread`, so
  asking for the cheap blocking-shaped carrier got you an OS thread and the
  `workload` argument to `thread-call` was accepted and ignored. The three names
  now pick three different things: `thread` is a real OS thread, `go` is the CPS
  pass on whatever `clojure.core.async/*go-backend*` says, and `io-thread`, which
  is `(thread-call f :io)`, is a fiber. `:mixed` (the default, as on the JVM) and
  `:compute` stay OS threads, and any other workload throws rather than quietly
  running on one of them.

  Neither `thread` nor `io-thread` consults `*go-backend*`, because both name
  their carrier at the call site. A body that parks releases its carrier, so
  thousands of `io-thread` bodies cost thousands of stacks rather than thousands
  of OS threads, and a park works anywhere in the body, including inside a called
  function, a `try` or a loop, because a fiber parks by capturing its
  continuation rather than by being rewritten. That is the reason to have
  `io-thread` as well as `go`.

  What a fiber does not get is an OS thread of its own. Channel operations park,
  and so does `jolt.socket`, but work that blocks somewhere the runtime cannot
  see (`Thread/sleep`, a raw fd read, a blocking FFI call) holds its carrier for
  the duration. `thread` is still the escape for that, and the docstrings say
  which is which. `go`'s default backend is unchanged. (#583, jolt-579)

### Fixed

- **`System/exit` ends the process from any thread.** It was Chez's `exit`, which
  unwinds only the calling thread when that thread is not the main one, so off
  the main thread the call did nothing the process could notice: a worker that
  decided the program should stop could not stop it, and nothing said it had
  tried. On the JVM `System.exit` halts the VM from wherever it is called. The
  boot thread keeps the normal path with its exit handlers; any other thread
  flushes stdout and stderr by hand and calls libc `_exit`. Not unwinding is
  right on its own terms too, since the JVM does not run `finally` blocks on
  `System.exit`. (#582, jolt-7xls)

- **One paren too many is a read error, not a silent truncation.** The two loops
  that read a file form by form treated a stray close delimiter as end of input,
  so everything after it was dropped: `jolt run` printed whatever came before the
  paren and exited 0, and a build emitted an image of those forms and reported
  success. The JVM raises "Unmatched delimiter: )" and exits 1, and so does jolt
  now, naming the file and the line and column of the delimiter rather than the
  start of the file. Found the way you would want to find it, from a test file
  whose entire body silently did not exist. (#581, jolt-3amm)

- **A `(timeout ms)` closes on its own deadline.** One timer thread serves every
  `(timeout ms)` in the process, and it slept to the nearest deadline with its
  mutex released, which left it off its condition variable exactly when a nearer
  deadline arrived. The wake was dropped and the new timeout did not close until
  the deadline the timer was already sleeping to, so a `(timeout 100)` created
  while a `(timeout 3000)` was pending took 3000ms. Every `alts!` timeout guard,
  every operator built on one, and every fiber parked on one inherited that.

  The same three lines cleared the flag that guards the fork before an idle wait,
  but a timer that finds nothing pending waits rather than exiting, so the next
  timeout both signalled the live thread and forked another one that also never
  exits. 100 sequential `(timeout 1)` calls left 100 live timer threads.
  (#584, jolt-pe84)

- **`with-open` closes a `reify`.** It had an arm for a `deftype` or `defrecord`
  that declares `close` and fell through to "no .close method on value" for a
  `reify` that declares one, even though `(.close x)` on the same value worked.
  It now goes through the shared interface-method lookup that already handles
  both. A connection handed out as a `reify` implementing `java.io.Closeable`,
  which is what `clojure.jdbc` does, could not be used with `with-open` before.
  (#585)

- **`(Class/FIELD)` in call position reads the field** instead of trying to apply
  its value, so `(Math/PI)` and `(Integer/MAX_VALUE)` evaluate to the field as
  they do on Clojure, which reads a parenthesised static member as a field when
  one exists. It holds for a class a library declares too, which is what
  `clojure.jdbc` needs for its `(Locale/US)`. The dot form already resolved this
  ambiguity at runtime; the slash form now gets the same treatment, for a
  zero-argument call whose head is a qualified non-var symbol. A no-arg static
  method is still called, and a zero-arg var call is untouched. (#585)

- **`extend-protocol` on a class a library declared now dispatches.** Registering
  a class made `(class x)` and `instance?` answer for the library's own host
  values, which was half the point; the other half, dispatching a protocol
  extended to that class, never worked. Resolving the extended type name to a
  dispatch tag only recognised classes the runtime models, so a name it did not
  know was filed under the extending namespace, a tag no value can ever carry,
  and the extension silently never fired. A dotted name that names no `deftype`
  is now taken verbatim, which is the tag such a value reports. Simple names are
  untouched. (#585)

### Internal

- **A hung gate case reports itself instead of wedging the run.** `make test` sat
  on the socket poller case for over ninety minutes in one local run and said
  nothing, because the per-case cap needed GNU `timeout` and stock macOS has
  none. Every host has a cap now (`host/chez/cap.sh`, POSIX sh), and the case
  itself runs its workload on a spawned thread while the main thread watches a
  deadline, so a wedge exits 1 naming the round and phase it stopped in. Its old
  claim that an `alts!!` timeout bounded every read was not a bound at all, since
  the bound depended on the same machinery the case exists to stress, which the
  timer fix above is a candidate explanation for. (jolt-8tma)

- **`make certify` names the rows it could not finish**, rather than counting
  them, and staleness now ignores rows the JVM oracle had no opinion on, so a
  row that timed out is not evidence that a divergence went away. The
  `(reduce + (eduction (filter odd?) [1 2 3 4 5]))` row is recorded as flaky,
  because the JVM's own answer is unspecified: `CollReduce` is extended to both
  `IReduceInit` and `Iterable`, an Eduction implements both, and which one wins
  falls out of a hash set ordered by identity hash codes. Twelve consecutive
  local runs raise; CI returns 9. (jolt-owjl)

## [0.7.2] - 2026-08-11

A Path answers for the file system it came from, and the java.nio.file shim
values report their classes through the registry every other shim uses.

### Added

- **`Path.getFileSystem` and `FileSystem.getPath`.** `FileSystems/getDefault`
  hands back one file-system object rather than a fresh one per call, so
  `(identical? (FileSystems/getDefault) (.getFileSystem p))` holds the way it
  does on the JVM, and a file system reached through a path can construct paths
  itself. That is the shape migratus uses to filter migration files: it takes
  the file system off a path, asks it for both the candidate path and the glob
  matcher, and matches the two. Thanks to @sundbp (#574).

### Fixed

- **`extend-protocol` on `java.nio.file.Path` now dispatches.** A Path answered
  `instance?` and `(class p)` through arms local to the nio shim rather than
  through the jhost tag registry, and protocol dispatch reads that registry, so
  `(extend-protocol P java.nio.file.Path …)` threw "No method" on a value whose
  own `(class …)` said `java.nio.file.Path`. The registry now carries a row for
  each of the three shims and the tag-local arms are gone, which is also what
  fixes `(class (FileSystems/getDefault))` answering `:object` and
  `(instance? java.nio.file.FileSystem fs)` answering false where the JVM
  answers true. A Path is a Comparable, an Iterable and a Watchable now, as it
  is on the JVM. (#577, jolt-o9xv)

## [0.7.1] - 2026-08-11

Dependency resolution tells the truth about a Maven fetch that failed, retries a
transient one, and stops silently continuing without the dependency.

### Changed

- **Grenadine updated to v0.1.6.** No behaviour change for jolt: the only two
  namespaces jolt consumes, `grenadine.version` and `grenadine.pom`, differ from
  v0.1.5 by license and provenance comment headers alone.

  It is not a plain submodule bump, though. From v0.1.6 Grenadine *generates*
  `basis`, `coordinate`, `expander` and `gitlibs` from pinned upstream sources
  rather than committing them — its own `.gitignore` lists all four — so the git
  tree is an incomplete source tree, and jolt loads Clojure straight off
  `vendor/grenadine/src`. Those four now come from the release's
  checksum-verified `-src.tar.gz` and live in `vendor/grenadine-generated`; the
  alternative was running Grenadine's `yq`-and-`git clone` staging step on every
  build and CI job. `make grenadinecheck` fails if the vendored sources and the
  pinned submodule name different versions.

- **A Maven dependency that cannot be obtained is now a hard error**, matching
  the reference implementation: tools.deps aborts with "Error building
  classpath. The following artifacts could not be resolved:" and exits 1 for a
  missing artifact and an unreachable repository alike (checked against Clojure
  CLI 1.12.5.1654), and jolt already did this for a git dep whose tag does not
  exist. Maven was the outlier — it warned and carried on with the dependency
  missing from the classpath. Every unresolvable dep is named in one message,
  as tools.deps does, rather than one build at a time.

  Unaffected: a jar that downloads fine and carries no jolt-loadable source
  still contributes nothing, quietly. That is a different condition — the
  artifact resolved — and JVM-only jars turn up as transitive deps routinely.
  Only failing to *obtain* an artifact is fatal.

### Fixed

- **"not found" no longer means "something went wrong".** `jolt.mvn-http/fetch`
  answered one bit, so a 404 was indistinguishable from a connection reset, a
  TLS failure, a timeout, a truncated body, a 429 or a 503 — and `jolt.deps`
  reported all of them as `maven dep X V not found`. A fetch now classifies its
  outcome (`:ok` / `:not-found` / `:retryable` / `:failed`), and the message
  distinguishes "not found in any repository" from "could not be fetched:
  <repo> — <reason>", naming the underlying error instead of discarding it.

  This is not hypothetical: the v0.7.0 release run reported
  `org.clojure/spec.alpha 0.5.238 not found` for an artifact that returns HTTP
  200 from Central. The dependency vanished from the classpath, orchard failed
  to load, and the nREPL suite reported it as 55 identical "connect refused"
  errors that never mentioned a dependency.

- **A transient Maven fetch is retried**, three attempts with a short backoff,
  and only for conditions a retry can fix — a 408, a 429, a 5xx, a truncated
  body, or a connect/TLS error. A 404 and a 403 are final and cost exactly one
  attempt. There was no retry at all before, so a single packet-loss event
  failed a whole resolution.

Finishes the fiber backend for `core.async`. A parked `go` process is roughly
5.5x smaller when the compiler can see where it parks, a compute-bound body no
longer starves the fibers queued behind it, and every lock a program can hold —
`locking`, `dosync`, a `delay` being forced, `ReentrantLock` — survives a park
with exclusion intact. Fibers stay opt-in
(`clojure.core.async/*go-backend* :fiber`); the default is still `:thread`.

### Added

- **The cheap park: a `go` body pays for a continuation only where it needs
  one.** A fiber parks by capturing a continuation, which Chez represents as a
  stack segment that stays live for as long as the process is parked. A CPS pass
  in `clojure.core.async` now rewrites the rest of the body into a closure where
  it can see the park, and the channel op stores that closure and switches to the
  scheduler with no capture at all. Measured in one run, same process shape and
  retention: 864 B live / 1,244 B peak RSS rewritten, against 4,762 B / 7,368 B
  captured — 5.5x and 5.9x. Round-trip time is unchanged (903 ns against 858 ns,
  inside the spread).

  The choice is per **park site**, not per body, with the continuation park as
  the runtime fallback. A park the pass cannot see or cannot rewrite — inside a
  called function, inside a `try`, inside a nested `fn`, in an `alts!`, reached
  through `eval` — is left exactly as written and parks the way every park did
  before. So the pass is opportunistic: it can cost a park its cheap
  representation, never its correctness, and nothing about a `go` body needs
  annotating. Jolt keeps the property the JVM's transform gives up: a parking op
  does not have to appear lexically in the body.

- **Preemption is the scheduler.** A `go` body that computes without reaching a
  channel op used to hold its carrier for as long as it ran, and every fiber
  queued behind it waited — fibers cannot migrate, so nothing could rescue them.
  Chez polls an engine timer at procedure calls and loop back edges, so a tight
  arithmetic loop yields like anything else; the quantum is ~0.45 ms.
  `clojure.core.async/*fiber-preempt-ticks*` sets it, read once when the carrier
  pool starts. There is no value that turns preemption off — cooperative-only is
  an unbounded starvation window, so code that wants it asks for a very long
  quantum instead. A fiber inside a blocking foreign call is not running Scheme
  and no timer fires for it.

- **`clojure.core.async/go-monitor`** yields the throwable when a `go` body
  died, and closes when it did not. A body that threw and a body that returned
  nil were otherwise indistinguishable: both close the result channel and hand
  the reader nil, with the condition reported to stderr at best. It answers for
  either backend and for both fiber spawn paths — which backend ran a body
  follows from the caller's `*go-backend*` binding and which spawn path from
  whether the CPS pass could rewrite the body, so a monitor that reported on some
  of those and said "clean" for the rest would be worse than none.

  ```clojure
  (let [g (a/go (throw (ex-info "boom" {})))]
    (a/<!! g)                    ;=> nil, same as a body that returned nil
    (a/<!! (a/go-monitor g)))    ;=> the throwable
  ```

  A `thread` block's channel answers too — it has the same nil ambiguity and
  comes from the same spawn. A channel that is not one of those monitors as nil
  rather than raising.

### Fixed

- **A lock is a lock across a park.** Holding an object monitor, a transaction
  or a `delay` across a `<!` broke exclusion, in each case because ownership sat
  in an OS mutex: `locking` was a `dynamic-wind`, so a park released the monitor
  mid-body and re-took it on resume, and two fibers on one carrier then ran the
  same body at once — undetected, because same-carrier fibers share the carrier's
  identity and the owner check took the reentrant arm. `dosync` lost isolation
  the same way, and `(delay (<!! gate))` ran its body once per forcer that got
  in, so one delay answered two forcers with different values. Those four locks —
  object monitors, `dosync`, `delay`, `java.util.concurrent.locks.ReentrantLock`
  — now carry ownership in a field keyed on the fiber, which survives a context
  switch. You can hold a monitor across a `<!`, park in the middle of a
  transaction, and force a `delay` whose body waits on a channel.

  Underneath, every lock in the runtime routes through one counting wrapper and
  the scheduler refuses to switch a fiber that holds one, re-arming on a short
  retry so the preemption lands just after the region. A gate checks the routing
  rather than documenting it.

- **`require` is safe to call from more than one thread.** Nothing serialized a
  namespace load, so two threads requiring the same namespace both passed the
  loaded check and both ran its top-level forms — every `def` and every
  side effect twice. The mark-before-load that terminates a require cycle made it
  worse across threads: the namespace reads as loaded before its forms run, so
  the second thread's `require` returned having defined nothing. Loads are
  serialized per namespace now, following the JVM's class-initialization
  procedure (JLS 12.4.2) — the same thread re-entering its own in-progress load
  still proceeds, which is what makes a cycle terminate, and unrelated namespaces
  still load in parallel.

  The compiler had to be made safe for that first: the emit session's scratch,
  the per-def cache cells and the hoisted constant pool lived on a process-global
  unit that two emitting threads traded, so a namespace that compiled cleanly
  alone died with `variable _kc$81 is not bound`. They are thread-bound vars now,
  which also unwinds them on a throw, where the old save/restore pair left the
  unit pointing at an abandoned def's collector.

- **`compare-and-set!`, `swap-vals!` and `reset-vals!` name the class the JVM
  names.** They skipped the atom check `swap!`/`reset!` run and reached a record
  accessor, so a non-atom receiver reported jolt's own record type and nil
  stopped reporting as a `NullPointerException` — which a `catch` selecting on it
  stopped matching.

- **A dynamic binding the runtime establishes is not doubled by a park.** Three
  places pushed a binding frame in a `dynamic-wind`'s before thunk — `*agent*`,
  `*compile-files*`, and the loader's file and source-path frame. A park saves
  the fiber's slice with the frame already in it, the escape's unwind pops it,
  and the resume both restores the slice and re-runs the before thunk, so the var
  ended up bound twice and one frame leaked past the end of its extent. Visible
  with an ordinary park; no preemption needed.

## [0.6.9] - 2026-08-10

### Changed

- **`(.-field obj)` raises when the field is absent**, where it used to answer
  nil — so `(.-zz record)` and `(.-nope map)` no longer read as a field that is
  present and set to nil, and a caller testing one no longer silently takes the
  wrong branch. The JVM raises `IllegalArgumentException` there and so does
  jolt now. What still answers is unchanged: a declared `deftype`/`defrecord`
  slot, and the documented map-as-object read where a key the map HAS reads as
  a field. Code that relied on the nil needs a `contains?`/`get` instead.

### Fixed

- **A lookup answers with the element the collection HOLDS**, not the key it was
  probed with, so metadata on the stored element survives. `(#{^{:x 1} [a b]}
  [a b])` handed back the bare probe and lost the metadata; `assoc` replaced a
  stored key with the equal one it was given, `find` minted its entry from the
  probe, and `select-keys` rebuilt through `assoc`. All of them read the
  collection's own entry now.

- **`count`/`seq`/`nth` work on a `CharSequence`**, which `RT.count`/`RT.seq`/
  `RT.nth` reach for on the JVM: a `deftype` presenting a window over a string
  answered its field count rather than its length. `re-matches`/`re-find`/
  `re-seq` accept one too (only `re-matcher` did), and `StringBuilder` is a
  `CharSequence` at all now — it had no supers row and no `count`/`seq`/`nth`/
  `subSequence`.

- **`deref`'s timed arity is a real `IBlockingDeref` cast.** `(deref (delay 7)
  50 :timeout)` returned 7 with the timeout silently dropped, where the JVM
  throws `ClassCastException` because `Delay` is `IDeref` but not
  `IBlockingDeref`; same for an agent. `atom`/`ref`/`var` did throw, but
  reported the class as an opaque `:object` sentinel.

- **A core.async transducer's `:ex-handler` gets the original throwable.** It
  was handed the raw raised condition, so `ex-data`, `ex-message` and the class
  all read nil and the thrown `ex-info`'s data was lost. core.async also joins
  the library conformance manifest, giving `async.ss` a standing regression gate.

- **The runtime's shared side-tables are serialized.** A Chez hashtable is not
  thread-safe, and the metadata table (every `with-meta`) and the variadic
  fixed-arity registry (every variadic closure creation) were written from
  whatever thread the program ran on. The corruption surfaced later as an
  invalid memory reference inside the collector, or a hang — reproducibly, as a
  crash of core.async's own pipeline test, and in builds predating the fibers
  work.

- **Shutdown hooks run** (#571). `Runtime.addShutdownHook` kept a list nothing
  ever read, so `jolt.process`'s `:shutdown` option — `destroy-tree` and
  friends — cleaned up nothing on any exit path, and a `SIGTERM` to a jolt
  program left its child processes running. Hooks now run once per process from
  a single registry, on normal return, on `System/exit`, on an uncaught throw,
  and on `SIGTERM`/`SIGHUP`.

  The signals are taken over only once a hook is actually registered, by a
  thread parked in `sigwait` — Chez runs a `register-signal-handler` handler on
  the main thread at its next safe point, and the two ways a program usually
  waits (a `deref` of a promise, a blocking foreign call) never reach one, so
  that route would have made the process ignore the signal instead of handling
  it. A program with no hooks is untouched and dies on `SIGTERM` as before. Exit
  status is 128+signal, as on the JVM.

- **A blocking stdin read no longer stops the rest of the program.** `read-line`
  and the REPL waited inside Chez's own blocking read, which holds the whole
  Scheme world: a `future` stopped ticking and an agent stopped draining the
  moment the main thread reached a prompt, where a JVM keeps both running. The
  wait now happens in `sleep` and the port is read once it has something. A
  buffered line costs one `char-ready?` and no sleep, so a piped `read-line` loop
  keeps its throughput (1326 -> 1386 ns/line, 1.045x).

- **A subprocess can be interrupted with `^C` again.** Children spawned the
  default way came up with SIGINT set to `SIG_IGN`, so `^C` in a terminal killed
  your program and left the subprocess running. That is the `system(3)` leak the
  convention exists to avoid rather than the convention itself — a child's
  dispositions should match what a plain shell would give it, as they do on the
  JVM. `posix_spawn` now drives every spawn rather than only the ones redirecting
  a stream to `:inherit` (it already piped every other stream); Chez's fork,
  which is where the ignore was set, stays as the fallback for platforms without
  the FFI surface.

- **A child process no longer inherits jolt's signal mask.** jolt blocks SIGINT
  in its own threads so `^C` reaches the one parked for it, and now blocks
  SIGTERM/SIGHUP for the shutdown watcher; both travelled to every child through
  `posix_spawn`'s null attributes and through Chez's fork. A child that starts
  with SIGTERM blocked survives the `destroy` a shutdown hook calls, and one with
  SIGINT blocked ignores `^C`. The mask is emptied for the length of a spawn and
  put back, so a child gets the default mask the JVM would give it.

### Added

- **Fibers R8: a socket read parks the fiber instead of pinning its carrier.**
  `jolt.socket` runs its syscalls with the fd in `O_NONBLOCK`; on `EAGAIN` it
  registers readiness with the new `jolt.io-poller` and parks the fiber, so the
  carrier runs other fibers meanwhile, and blocks on a private
  `kevent`/`epoll_wait` exactly as before when there is no fiber. User code keeps
  its blocking shape either way. File offload is not in this round.

- **Fibers R5: a carrier pool, and `<!!` parks on a fiber.** The scheduler state
  R4 kept in globals moved into a per-carrier record — run queue, mutex,
  condition, resume continuation, dynamic slice, thread, stop flag — since R4's
  single global resume continuation stops being safe the moment there is more
  than one carrier. Carriers default to the processor count and are overridable;
  placement is round-robin at spawn and never revisited, because a fiber cannot
  migrate.

- **Fibers R4: `go` on fibers, opt-in.** A `go` body can run on a fiber.
  `clojure.core.async/*go-backend*` selects it (`:thread` default, `:fiber` to
  opt in), read at spawn time off the dynamic binding, so a `binding` covers
  every `go` in its scope including ones inside functions it calls.
  `thread`/`thread-call` stay real OS threads regardless — that is the documented
  escape for blocking work, which would otherwise pin a carrier. The default is
  unchanged.

- **Fibers R3 (jolt-nvpr.4): one waiter protocol for threads and fibers.** A
  pending channel operation is a handler, never a fork. The alt-taker/alt-putter
  records in `host/chez/java/async.ss` — the list machinery `ac-notify!` already
  drains under the channel mutex — gain a `wake` field, and `alt-deliver!`
  dispatches on it: a thread-waiter is woken by its condvar exactly as before, a
  fiber-waiter by enqueuing the fiber on its carrier's run queue
  (`sa-fiber-resume`, safe cross-thread now that the run queue in
  `host/chez/fibers.ss` has a mutex). The channel core never learns what a fiber
  is: a fiber's `< !` registers as an alt-taker, its `>!` as an alt-putter. The
  new bridge `host/chez/java/fibers-async.ss` defines `jolt-fiber-<!` /
  `jolt-fiber->!`, the Scheme-level primitives R4's `go` will drive: the
  immediate-completion path takes a buffered value or drains a waiting putter
  under the channel mutex with no continuation capture, and the park path
  registers the handler, releases the channel mutex, then suspends — the commit
  decision (park vs. already-delivered) happens inside the handler mutex, so a
  delivery racing the release can never be lost. A parked fiber taker counts as
  a waiting taker for the unbuffered readiness check in `ac-try-give!/locked`,
  so `offer!`/`put!` complete against it instead of forking a thread. Lock order
  stays channel mu → handler mu → run-queue mu; "never yield while holding the
  channel mutex" is now stated in async.ss's lock-order comment. The new `make
  fibers` gate (`fibers-chan-test.ss`, 47 checks) covers thread/fiber handoff in
  both directions, buffered and unbuffered, a thread-put waking a parked fiber
  and a fiber-put waking a parked thread, no-capture immediate completion (the
  park counter stays at zero; 81ns vs 1775ns per take), N×M exactly-once
  delivery, close! waking both waiter kinds, a fiber parking while a sibling on
  the same carrier puts, and a pumping-thread stress drain. The `thread-sleep`
  helpers in async.ss moved to Chez `sleep`.

- **Fibers R2 (jolt-nvpr.3): per-fiber dynamic state.** A fiber's `binding`
  frames, current namespace, and STM `*txn*` now travel with the fiber instead
  of the carrier. R0 pinned the bug: dyn-binding.ss pushes a binding frame by
  calling a thread parameter as a setter, and a setter write survives a
  continuation escape — a fiber parked inside a `binding` leaked its frames
  onto the carrier, visible to the scheduler and every other fiber, and a
  second fiber's pop could pop the parked fiber's. The fix lives in the
  scheduler: each fiber carries a dynamic slice (`host/chez/fibers.ss`,
  `jolt-dslice`), saved on switch-out and restored on switch-in, with the
  carrier reverting to the caller's state between fibers. Writes are diffed
  with eq? (a thread-parameter write is 33ns vs 2ns to read), so identical
  slices cost reads only; the switch ratio in `make fibers` moved from ~22x to
  ~27x a bare procedure call (ceiling 60x). `sa-fiber-spawn` conveys the
  parent's bindings and namespace but never its `*txn*` (async-go-spawn
  parity), so a child spawned inside a dosync cannot join the parent's
  transaction. `dyn-binding.ss` is untouched. The new `make fibers` gate
  (`fibers-state-test.ss`) asserts the six R2 scenarios: binding invisibility
  between siblings, the parked-frame leak regression, bindings intact on
  resume, transaction isolation across two fibers on one carrier, spawn
  conveyance, and namespace-follows-fiber.

- **Fibers R1 (jolt-nvpr.2): the fiber primitive and a single-carrier
  scheduler** behind the new `coroutines` CONTRACT.txt tier (`sa-fiber-spawn`,
  `sa-fiber-yield`, `sa-fiber-resume`, `sa-fiber-run-all`), in
  `host/chez/fibers.ss`. Per R0's measurements: the per-fiber slice rides in
  one virtual register (2ns vs 33ns per thread-parameter write), the run queue
  is intrusive (the next link lives in the fiber record), and exceptions are
  isolated per fiber (a raise kills the fiber, never the scheduler loop).
  The Chez gate (`make fibers`, in CI) asserts correctness (round trip,
  completion, raise isolation, 8-fiber round-robin, yield from 40 frames deep)
  and the pinned numbers: spawn 0.04us (< 5us), switch 50ns (< 100ns),
  3.7KB live per parked fiber (< 8KB, by the R0-corrected absolute-live-bytes
  measurement). Gambit satisfies the tier with a call/cc-based scheduler
  (verified under native gsi in gambitcheck); `go` stays on OS threads there
  per the plan's documented degradation. No jolt-level `go` or channel code
  yet — those are later rounds.

- **Gambit build profiles**, so a bundle carries only the language a build
  needs. The Gambit runtime plus jolt's kernel is two thirds of the bundle and
  cannot be dropped; what is separable is regex, the compiler, and
  `clojure.core` itself, so the profiles trade features for the last third —
  `repl` ships 27.7MB / 3.1MB gzipped against `full`'s 32.6MB / 3.5MB.
  `make gambitweb` builds the browser bundle, and `host/gambit/host-vars.ss`
  binds the 40 `clojure.core` names the `java/` tree owns on Chez (`(time 1)`
  reached an unbound global and failed as a bare Gambit exception); each is
  either implemented or raises a catchable `UnsupportedOperationException` that
  names itself.

- **Gambit is a second Scheme backend** — the first target ported through the
  portable Scheme layer (#446). Jolt reads, compiles, and evaluates source on
  native Gambit, and the whole stack compiles to a single JavaScript file via
  `gsc -target js` that boots in about a second in a browser (the live REPL on
  jolt-lang.github.io). `host/gambit/` holds the adapter, prelude shims, hash
  kernel, and a target-owned runtime kernel; the seed and the expansion-hostile
  macros are generated on Chez (`make gambitseed`) rather than hand-written.
  Three detection-gated targets hold the boundary: `make gambitcheck` (adapter
  and shims), `make gambitkernel` (the booted kernel, 113 checks), and
  `make gambiteval` (jolt source through the compiler, renders pinned to Chez
  captures). Nothing on the Chez path changed.

  The backend is demo-grade: FFI, AOT compilation, and program images raise,
  the concurrency tier is stubbed, and only checked primitives are emitted.
  `jolt build` binaries remain Chez-only. See "Scheme Backends" in the docs for
  the contract a new target must satisfy.

## [0.6.8] - 2026-08-07

### Added

- **Variadic FFI** (#551): a `:varargs` marker in a `defcfn` argtype vector
  declares the binding variadic and marks the fixed/variadic boundary — types
  before it are the named parameters, types after it the concrete variadic
  arguments. Calls emit Chez's `(__varargs_after n)` convention so variadic
  arguments travel where the callee's `va_list` reads them; on Apple arm64
  they ride the caller's stack, and a fixed-arity binding silently corrupts
  them (fcntl's F_SETFL flags never land). Marker-first, marker-last, and
  `:varargs` combined with `:blocking` reject at compile time with messages
  naming the rule.

## [0.6.7] - 2026-08-06

### Added

- **Portable Scheme layer completed** (#446, rounds R7–R10). The FFI tier,
  eval/compile/AOT, and the backend's unsafe-primitive and FFI emission all
  route through the scheme-adapter now; the lint allowlist is structurally
  confined to the two target-owned files. `host/scheme-adapter/` gains
  `TARGET-CONTRACT.md` (the porting document) and `guile.ss` (a structural
  stub a port starts from); design notes are RFC 0010 on the site. No
  behavior change on Chez — the seed prelude is byte-identical and the hot
  FFI paths measured within noise.

### Changed

- **State image format version 3**: refs now travel in `jolt.image` dumps by
  value (a descriptor is written; restore re-mints live refs — identity,
  cycles, metadata, and STM liveness all preserved). This build still reads
  version-2 images, including ones holding refs; runtimes at 0.6.6 or older
  refuse version-3 images with a clean version error. Dropping the ref
  record's dead lock field also makes `(ref x)` cheaper: the STM microbench
  runs ~1.17x faster and a ref-heavy image round-trip ~1.2x faster.

### Fixed

- `jolt.image/resolve-stub!` now replaces a stub held inside a ref's value;
  the substitution walk previously passed refs through untouched.

## [0.6.6] - 2026-08-06

### Added

- **Portability groundwork for #446** — a general Scheme layer with the
  Chez-specific bits isolated. Every Chez-only identifier the host uses is
  now either in the documented adapter contract (`host/scheme-adapter/`) or
  routed through `sa-*` capability entry points
  (`host/chez/scheme-adapter-runtime.ss`), enforced by new ci gates
  (`portcheck`, `adaptercheck`, `degradedbacktrace`). Capability tiers
  (threads / ffi / introspect / native-compile) make a WASM-class target
  definable; the threads-tier audit behind this produced the concurrency
  fixes above. No user-facing behavior change otherwise.

- **`jolt.socket`: `java.net.Socket` / `ServerSocket` / `InetSocketAddress` /
  `InetAddress` over POSIX sockets** (`(require 'jolt.socket)` registers the
  classes; IPv4, blocking I/O). Contributed by @allen-munsch in #542,
  hardened in #543: writes to a peer-closed socket throw `IOException`
  instead of silently dropping (SIGPIPE guarded via
  `MSG_NOSIGNAL`/`SO_NOSIGPIPE`), `ServerSocket` binds the wildcard address
  like Java (port 0 + `getLocalPort` report the kernel-assigned port via
  `getsockname`), accepted sockets know their peer,
  `class`/`instance?`/`str` answer as the mirrored classes, and
  `InetAddress/getByName` resolves. Deliberate gaps are in
  `known-divergences.edn`: `available()` is 0, a recv error reads as EOF,
  connect timeouts are ignored.

### Fixed

- The install script honors `PREFIX` (`PREFIX=~/.local bash install` puts the
  binary in `~/.local/bin`) and, when neither `PREFIX` nor `--dir` is given,
  defaults to `~/.local/bin` for non-root users instead of failing on
  `/usr/local/bin` with permission denied. Root keeps `/usr/local/bin`.
- **Monitors are reentrant per thread, like JVM intrinsic locks.** A nested
  `(locking x ...)` on the same object from the same thread deadlocked, and
  a non-owner `monitor-exit` silently released someone else's lock instead
  of throwing `IllegalMonitorStateException`. (#446 threads audit)
- **Executor pool workers no longer inherit an in-flight transaction.** A
  pool created inside a `dosync` handed its workers the live transaction,
  so a job's `ref-set` outside any transaction silently wrote into the dead
  transaction log instead of throwing `IllegalStateException`.
- **Atomic `updateAndGet`/`getAndUpdate` run the update fn lock-free** in a
  CAS retry loop like the JVM; a fn that touched its own atomic deadlocked.
- **`await`/`await-for` on a failed agent throw** `"Agent is failed, needs
  restart"` instead of returning normally. Entering the wait on an
  already-failed agent matches the JVM exactly; an agent failing mid-wait
  throws where the JVM blocks forever (deliberate; `known-divergences.edn`).

- **`ProcessBuilder$Redirect/INHERIT` inherits the real file descriptors.**
  A spawn with any INHERIT stream goes through `posix_spawn`: the child sees
  the actual fd (`isatty` answers truthfully, stdin's read offset is shared
  between children), pipes are built only for the streams that ask for one,
  and the API returns null streams for the inherited ends like the JVM. Pump
  emulation remains as the fallback where that FFI surface is unavailable.
  (#541)
- **A top-level macro call expanding to `do` unrolls into top-level forms**,
  per Clojure's compilation-unit rule: each child compiles and evaluates
  before the next, so a macro emitting `(do (require ...) (deftest ...))`
  has the require in force when the `deftest` compiles. Previously only a
  literal `(do ...)` unrolled; babashka.process's own suite loads exactly
  this way.

## [0.6.5] - 2026-08-05

Images now carry the two things 0.6.3 refused: anonymous functions and
sorted collections. Open resources stub instead of refusing. Image format
is now v2 — older runtimes refuse a v2 image with the reason named. (#539)

### Added

- **Anonymous functions travel in images.** A `fn` literal is compiled under
  a stable name with its source form and free names registered at load time;
  the dump records the source plus the captured values (recovered live from
  the closure), and restore rebuilds a callable closure in the defining
  namespace. Captures optimized into the compiled code refuse at dump,
  naming the local — never a closure that silently computes with `nil`.
- **Sorted maps and sets travel in images**, restored through the public
  constructors with the original comparator (natural or user-supplied).
- **Open resources dump as resolvable stubs.** `dump-world!` stubs
  unwritable values (ports, threads, sockets) by default and reports them
  under `:stubbed`; `dump!` stays strict unless `{:unwritable :stub}`.
  After restore, `jolt.image/stubs` lists what needs rebuilding, inert until
  `resolve-stub!` replaces one; `register-stub-describer!` /
  `register-stub-resolver!` extend both ends. `scan` reports each value's
  `:disposition` so the split is visible before writing.

### Fixed

- Timed `(deref ref timeout-ms timeout-val)` on a record or reify
  implementing `IBlockingDeref` reaches the 3-arity method instead of
  silently blocking on the one-arity; a `deref` method existing only at the
  other arity throws the JVM's `ClassCastException` naming the interface.
  (#537, #540, fixes #538)
- `realized?` dispatches to a record or reify `isRealized` method
  (`clojure.lang.IPending`). (#540)

### Conformance

- mount (application state lifecycle) passes its full suite — 21 tests,
  131 assertions, matching JVM Clojure exactly — and joins the
  libconformance fleet. (#540)

## [0.6.4] - 2026-08-05

### Changed

- Vendored grenadine updated to v0.1.5. The effective-POM reader now handles
  Unicode in Maven XML and legacy Maven dependency forms, widening the set of
  POMs `jolt.deps` can resolve transitively. (#536)

## [0.6.3] - 2026-08-05

Adds `jolt.image` — write a running program's state to a file and restore it
in a fresh process, on another machine or another CPU architecture. State
travels, execution does not: no thread stacks, no continuations. Design in
RFC 0009; a working GUI example lives in jolt-lang/examples
(`image-dump-example`). (#533, #534)

### Added

- **`jolt.image/dump-world!` / `restore-world!` — save the program, not a
  variable.** Walks the var table and writes every var's root, so nothing in
  an application lists what its state consists of; a new `def` is in the
  image without touching the saving code. Code does not travel — a var whose
  root is a function is skipped, since the restoring process is the same
  build and already has it. `clojure.*`/`jolt.*` vars stay with the process
  being restored into; `user` is kept. `add-before-dump-hook!` /
  `add-after-restore-hook!` bracket the pair (quiesce on the way out, rebuild
  derived state on the way in), and `restore-world!` returns the number of
  vars rebound.
- **`jolt.image/dump!` / `read-image`** — the same machinery for a single
  value you name.
- **`scan` / `scan-world` / `dumpable?`** — dry runs that name the route
  through the graph to anything unwritable
  (`#'app.core/state -> :handlers -> "GET /x" -> #<procedure>`) instead of
  writing a subtly incomplete image. `dump!` refuses with the same path.
- **`register-handler!`** — teach the encoder a resource: a predicate, a
  fn that renders it as plain data, and a fn that re-acquires it on restore.
  Claimed at var roots, so a handler payload is ordinary state (functions
  become names, keywords re-intern).
- **Cross-architecture images.** The body is a machine-independent stream by
  construction — code travels by name, never as code objects — so an image
  written on arm64 reads on x86-64. Structural sharing, cycles, records,
  metadata, and every numeric type round-trip; interned keywords are
  re-interned on the way in, so restored maps look up correctly. The header
  pins the runtime: an image survives a machine or architecture change but
  not a Chez upgrade, and a mismatch is refused with the reason named.
- Not writable, by design: anonymous closures (store a named fn, or data to
  rebuild one from) and sorted maps/sets. Both are refused with a clear
  message, never silently dropped.

### Internal

- New `stateimage` gate (in `make ci`): pins the value/world round-trips and
  the Chez fasl behaviour the format assumes — what fasls, what is refused,
  machine-independence of data-only streams — so a Chez upgrade fails a test
  rather than someone's image.

## [0.6.2] - 2026-08-04

Rebuilds tracing on compile-time metadata, removing the per-entry ring push
that 0.6.1 left in place — tracing is now effectively free and on by default
everywhere, including built binaries. (#531, #532)

### Changed

- **Tracing is ~free, in dev mode and in built binaries.** The tail-frame
  ring, the per-entry push, the per-call line store, and the tail mark are all
  gone. The only runtime instrumentation left is one virtual-register store of
  a static `(fn . line)` pair at tail call sites; every call site additionally
  registers its static callee in load-time tables, and the reporter
  RECONSTRUCTS TCO-erased chains from those tables at throw time — backward
  from the throw-site pair through unambiguous tail edges, forward between
  live frames through unique tail-exit paths. Reconstruction can be
  incomplete (a fork in the static call graph stops it; a mutual-recursion
  cycle renders once, not per iteration) but never invented. Dev mode against
  `JOLT_TRACE=0` on the same binary: `fib` 7.1 → 0.9 ms (floor 0.7; was ~10×),
  `tak` at the floor (was ~9×), `binary-trees` 70.1 vs floor 68.0 (was 1.6×),
  `arrays`/`mathfns`/`loop-recur`/`mandelbrot` at floor parity. A zipper-heavy
  library test suite (rewrite-clj, ~10⁸ delegation tail calls) runs traced at
  untraced speed. An intermediate continuation-marks design was measured and
  rejected: Chez marks ballooned the heap to tens of GB at that call volume.
- **`jolt build` bakes tracing in by default.** A deployed binary's uncaught
  error names TCO-erased frames with exact lines — the site literals and
  tables carry everything; no source or marker files needed at run time.
  `JOLT_TRACE=0 jolt build` produces an untraced binary (build-time axis; the
  baked binary has no runtime knob). Built benches, traced vs untraced
  builds: `tak`/`binary-trees`/`arrays`/`mathfns`/`loop-recur`/`mandelbrot`
  within noise; `fib:30` 9.5 vs 7.7 ms (~0.6 ns/call — the tail-site store on
  tail-position arithmetic, which can throw and so must be recorded).

### Added

- **Host faults get real traces.** A raw Chez condition (a bad
  primitive-array index) has its site captured pre-unwind — in the cli run
  path and in built binaries' launchers — so the trace names the faulting fn
  and line. These previously fell back to a bounded history window, or
  nothing.
- **Erased frames recover at every spine level.** Forward gap-filling names
  the TCO-erased fns between any two live frames when the static call graph
  is unambiguous there — the old ring only ever recovered the innermost
  chain.

### Fixed

- An explicit `throw` in tail position reported its fn's definition line
  instead of the throw line.
- A trace could show a caller above its callee when the throw left live
  frames below a recovered chain.

## [0.6.1] - 2026-08-04

Undoes a dev-mode performance regression that shipped in 0.5.20 and 0.6.0, and
takes backtraces off the tail-frame history ring and onto the live continuation,
which is what made the regression unnecessary in the first place. Built binaries
were never affected in any release — they compile with tracing off — so this is
entirely about `jolt run` / `-M:alias`.

### Fixed

- **Up to 19× slower numeric code on the `jolt run` path (0.5.20, 0.6.0).** The
  tail-frame backtrace fix in 0.5.20 paired a history-ring save/restore around
  every non-tail call. It was applied downstream of every branch of the call
  emitter, so a call the inference had already reduced to a single machine
  instruction got wrapped too — a proven `(aget ^doubles a ^long i)` became

  ```scheme
  (let ((_tu$ (jolt-trace-save)))
    (let ((_tr$ (flvector-ref (jolt-array-vec a) i))) (jolt-trace-unwind! _tu$) _tr$))
  ```

  The `let` is the costly half: the restore runs after the call, so an unboxed
  flonum is held across it, lands on the heap, and takes the surrounding `fl+`
  chain with it. The cost tracked how well the inference had done — 19× on a
  flonum array loop, 1.9× on `vector conj`, 1.05× on lazy seqs. A proven
  `aget`/`aset` loop measured 10.4 ms on 0.5.19, 206.1 ms on 0.6.0, and 10.4 ms
  here; every phase of a real image pipeline paid 4.5–8.6× and is likewise back to
  its 0.5.19 timing. Tracing itself still costs (~10× on a `fib` microbenchmark
  against `JOLT_TRACE=0`) — that is the per-entry ring push, is unchanged by this
  release, and is why `JOLT_TRACE=0` exists.

- **Deep recursion lost the outermost frames of a backtrace.** The history ring
  holds 64 subproblems, so a 90-deep non-tail recursion reported `down (x64)` and
  dropped `-main` entirely. The spine now comes from the live continuation, which
  has no such bound, and the trace reports the true depth with its caller. This is
  the same failure the 0.5.20 fix set out to address; that fix covered calls that
  had already *returned*, never depth.

- **The AOT cache served artifacts across trace modes.** Whether tracing is on
  changes the emitted code, so a cached fasl is only valid for the mode that
  produced it, and the cache generation did not record which. A traced run that
  reused untraced artifacts silently reported **no** backtrace frames at all — the
  feature switched off by a cache hit. The generation is now keyed on trace mode.

- **Cached namespaces recorded a source path that no longer existed.** The cache
  compiled the emitted Scheme from a pid-unique temp and renamed it away, so
  `compile-file` baked the temp's name into every frame's source object. Nothing
  read that path before this release; the continuation-based backtrace does. The
  `.scm` is now published at its final name — still via temp + atomic rename, so a
  concurrent compiler never sees a half-written file — and compiled from there.
  `clojure.core/compile`'s artifact writer had the identical shape and is fixed
  alongside.

### Changed

- **Eval-path frames carry source objects.** Runtime-compiled code (an AOT cache
  miss) was a transient string: by the time anything threw, the text was gone, so
  a frame from that code could not point back into it. The eval path now reads
  each emitted form with `get-datum/annotations` under a synthetic source name and
  registers that text's `#|L<line>|#` markers under the same name first, so a
  frame's `(source-name . offset)` resolves to the original clj line even though
  the text itself is gone. Gated on tracing — with tracing off the path is the old
  plain `read`+`eval`, verbatim. Traces are unchanged; `JOLT_DEBUG_FRAMES=1` shows
  the resolved line per frame (`source=jolt-eval-src-1@278 -> clj:L4`).

- **Backtraces are rendered from the live continuation.** The reporter read the
  whole trace off the tail-frame history ring, with the continuation only as a
  fallback. That is backwards: the continuation *is* the stack, it is exact, and
  reading it costs nothing per call (the `call/cc` is paid at the throw). Each
  frame's clj line now comes from a `#|L<line>|#` marker the emitter leaves beside
  every traced call site, resolved through the frame's source object. The ring is
  consulted only for frames tail-call optimisation erased, which is the one thing
  the stack genuinely cannot hold. Trace output is unchanged apart from the
  deep-recursion fix above.

## [0.6.0] - 2026-08-03

Running third-party suites through each library's *own* runner, instead of a
bespoke harness that hand-listed namespaces and supplied its own deps, reached
code paths that had never executed. Most of this release is what that surfaced.

The largest single find was protocol identity. Dispatch keyed a method table by
the protocol's SIMPLE name, so two protocols named alike in different namespaces
shared one table and the later `extend` silently replaced the earlier one — a
wrong answer, not a crash.

### Added

- **`proxy` extends a concrete class by delegation.** It used to desugar to
  `reify`, which has no base, so a proxy over a concrete class answered only the
  methods its body declared and `proxy-super` threw unconditionally. jolt
  generates no classes, so a proxy now constructs a real base instance, answers
  what the body declares, forwards the rest, and `proxy-super` calls the base's
  own implementation. A proxy is an instance of its base and reports its class
  and host tags. A super naming an interface has nothing to construct and stays
  the reify it was.

  Delegation is not subclassing in one respect, recorded in
  `known-divergences.edn`: the base holds no reference back, so a base method
  calling an overridden method runs the base's version where the JVM re-enters
  the override. Overriding a leaf method — the common case — is identical.

- **`java.io.PrintStream`, and `System/setOut` / `System/setErr`.** Redirecting
  the process streams was previously withheld for want of the proxy support
  above.

- **A `URLStreamHandler` decides what its URL reads.** `openConnection` is the
  handler's, `openStream` is that connection's `getInputStream`, and `slurp` and
  `io/reader` route the same way. The constructors are now told apart by
  argument type the way the JVM's overloads are, so `(URL. context spec handler)`
  works.

- **A `deftype` or `reify` declaring `Iterable` or `Iterator` is seqable**, as on
  the JVM, walked lazily. `Seqable` wins over `Iterable` for a type declaring
  both, matching `RT.seqFrom`.

- **`clojure.test` reports like reference Clojure** — the blank line,
  `FAIL in (test-name) (file:line)`, the testing context and message, then
  `expected:` / `  actual:`. Every editor integration, CI parser and third-party
  reporter keys off that shape, and test.check's own suite asserts on it.
  Position comes from the reader rather than a stack walk. `*report-counters*`
  is incremented too.

- **`clojure.stacktrace`**, which Clojure ships and jolt did not. Frame lists are
  empty here — tail calls, already a recorded divergence — but the throwable
  line, `ex-data` and cause chain match exactly.

- `java.lang.reflect.Array` (`newInstance`/`getLength`/`get`/`set`),
  `Void/TYPE`, `System/arraycopy` with its overlapping-copy semantics,
  `Character/codePointAt`, `Murmur3/hashCombine`, `clojure.datafy`,
  `clojure.java.javadoc`, and Runtime's memory API.

### Fixed

- **Protocol dispatch keys by defining namespace**, not simple name. Resolved
  through `:refer` and `:as`; a symbol naming no protocol keeps its bare name,
  because that is how `value-host-tags` spells the tags a value reports.
- **`(. Class MEMBER)` reads a static field** when one is registered. It always
  emitted a static call, so a field's value was applied as a zero-arg procedure
  and came back **nil** — a silent wrong answer. `(. Class -MEMBER)` was rejected
  outright.
- **`java.io.File` compares by pathname under `=`.** `.equals` and `hash` already
  agreed, so two Files built from one path were unequal only through `=`. The
  two-arg constructor also joins with exactly one separator.
- **`println` and `prn` flush when `*flush-on-newline*`**, and
  `clojure.core/flush` dispatches to the writer `*out*` holds rather than only
  flushing the Chez port. The var existed and defaulted true with nothing
  reading it, so text sat in a writer's buffer.
- **`OutputStreamWriter` leaves the stream it wraps open**, and its flush reaches
  it. Transcoding the stream's port closes that port under R6RS, so
  `(.toString baos)` after wrapping one failed.
- `getPath` / `getFile` on a URL are the path component, not the spec minus a
  `file:` prefix; `io/reader` on a URL no longer reads the spec as a local path.
- A `reify` declaring `IFn` is `ifn?` and an instance of it.
- iconv issues the POSIX reset call, so a stateful charset emits its closing
  escape.
- `keys` / `vals` throw `ClassCastException` on a non-entry element.
- Accepts the sha an annotated tag carries as well as the commit it peels to,
  and the legacy `:sha` / `:tag` spellings.

### Changed

- **`(char n)` spans the Unicode scalar values.** jolt's strings are code-point
  indexed, so it could not rebuild a char `(first s)` had just handed out. This
  is a deliberate superset of the JVM's 16-bit char; the clojure-test-suite
  already treats that assertion as host-dependent, and jank and basilisp behave
  as jolt now does. Recorded in `known-divergences.edn`. Surrogates stay
  rejected.
- **An incomplete `make test` run can no longer read as a pass.** The gate runs
  as a sub-make behind a wrapper: a verdict line is printed either way, so the
  log can never end on a passing target — which also covers `make test | tail`.
  A complete pass writes a receipt naming the tree it covers, and `make
  gate-status` answers whether the working tree is gated. `-i` and `-k` are
  refused for gate targets.

### Library conformance

| library | before | after |
| --- | --- | --- |
| malli | 121 pass, 20 load-fail | **12,059** pass, 8 load-fail |
| honeysql | 832 pass | **2,842** pass |
| ring-core | 405 pass, 15 fail, 18 error | **446**, **5**, **5** |
| tick | 620 pass, 1 load-fail | **723**, 0 |
| Selmer | 525 pass, 1 error | **526**, **0** |
| tools.logging | 219 pass, 4 error | **226**, **0** |
| test.check | 230 pass, 15 fail | **236**, **10** |
| test.chuck | 98 pass, 22 fail | **110**, **17** |
| data.json | 320 pass, 2 error | **322**, **0** |
| markdown-clj | 180 pass, 2 error | **182**, **0** |
| data.codec | 1 pass, 11 error | **12**, **0** |
| hiccup | 385 pass, 1 fail | 386, **0** |
| rewrite-clj | 3,380 pass | 3,381 pass |

malli's fail and error counts also rise, because seven namespaces that used to
load-fail now run at all. Its residue is characterised in the manifest: 72
errors are sci, which does not fully load here (it reaches private
`clojure.core` internals by var), and 104 of the failures are one test that
round-trips values drawn with a fixed seed — a seed draws different values here
than on the JVM.

ring-core's multipart suite runs against jolt-lang/multipart, an RFC 7578
parser, through a shim registering the commons-fileupload2 class surface ring
reaches for. The shim is glue: it decides nothing about multipart syntax, which
is what keeps the suite worth running.


## [0.5.20] - 2026-08-02

A backtrace could show frames from calls that had already finished, and in the
common shape it pushed the frame you needed out of the trace entirely to make
room for them.

### Fixed

- **A backtrace no longer lists calls that already returned.** The tail-frame
  history keeps one entry per call reached, and its ring only ever moved forward
  — so a call that returned kept its place, and its frames printed under the ones
  that actually threw. Worse, once the ring filled they evicted the real caller.
  A `-main` that prints a value and then throws looked like this:

  ```
  Unhandled exception: Divide by zero
    trace:
      app/inner (src/app.clj:3)
      app/outer (src/app.clj:4)
      jolt.time.impl/type-of (jolt/time/impl.clj:7)     <- from the println,
      jolt.time.impl/jt? (jolt/time/impl.clj:78)           which had already
      ... 12 more of the same                              returned
  ```

  and now names the caller it was dropping:

  ```
  Unhandled exception: Divide by zero
    trace:
      app/inner (src/app.clj:3)
      app/outer (src/app.clj:4)
      app/-main (src/app.clj:7)
  ```

  The compiler now pairs a save/restore of the ring position around every
  non-tail call, so a returned call's entries are reused by whatever the caller
  does next. Tail calls are deliberately left alone: consuming their result to
  run the restore would make them non-tail and defeat tail-call elimination,
  which is the reason the history exists at all. This costs 1.9–3.1x on
  `jolt run` and **nothing** in a built binary, whose frame prologues are baked
  at build time with tracing off.

  One case still leaves residue: frames pushed by library code that the runtime
  itself called into (a type registering per-value `str`/`compare` arms, say)
  have no wrapped call site to unwind them. Those now sit below a complete
  spine rather than on top of a truncated one.

### Changed

- **Registering an arm whose predicate claims a runtime-owned type now fails
  loudly.** `=`, `hash`, `get`, `count`, `contains?`, `empty?`, `seq` and
  `compare` each answer their commonest types before consulting the registries a
  host type extends them through, so an arm matching one of those was silently
  skipped and its handler never ran. Registration now probes the candidate
  predicate and rejects it, naming the type. A shim that registered, say,
  `string?` for `count` fails at registration instead of being quietly ignored
  at every later call. Each registry checks only its **own** fast path — `get`
  answers records but not strings, `count` the reverse — so an arm that is legal
  for one and not another is still accepted where it belongs.

### Performance

- **`print`, `println` and `pr` resolve `*out*`, `*print-readably*` and
  `*print-namespace-maps*` through cached var cells** instead of rebuilding
  `"clojure.core/<name>"` and hashing it once per value printed. A/B/A in one
  session over a print-saturated workload, two runs: 3.5% and 5.5% faster, with
  drift of 0.15% and 0.33% between the A columns. Real programs print far less
  than that benchmark, so expect less. Reads still go through the binding stack,
  so `with-out-str` and `(binding [*print-readably* nil] …)` are unaffected.

### Internal

- Dependency-tree expansion moved out of `jolt.deps` into the vendored
  [Grenadine](https://github.com/clojurestar/grenadine) library, which now owns
  the tools.deps-compatible traversal, exclusion handling and version selection
  alongside the effective-POM builder and version comparator it already
  provided. Behaviour is unchanged — `-Stree`, `-Spath` and the resolution
  warnings all render identically.

## [0.5.19] - 2026-08-02

`print` was implemented as string conversion rather than as printing, so it
disagreed with `pr` on six types: a BigDecimal lost its `M`, a regex printed as
bare source, a UUID as bare hex, the infinities as `Infinity`/`NaN`, a bigint
lost its `N`, and a char nested inside a collection kept the backslash that
`print` is supposed to drop. On the JVM `print` is `pr` with `*print-readably*`
off, and that flag changes only strings and chars.

### Changed

- **`print`/`println`/`print-str` now render like `pr` with quoting off, not like
  `str`.** Previously `print` of a `2M` printed `2`, a regex printed `re`, and a
  UUID printed the bare hex string. It now shares the readable renderer with `pr`
  and only drops the string/char quoting, so those print as `2M`, `#"re"` and
  `#uuid "…"`, and a mixed coll prints `[s a 2M]` instead of `[s \a 2M]` — the
  JVM's `(binding [*print-readably* nil] (pr …))`. `str` is untouched (its
  contract is `.toString`). The quoting-off flag rides a virtual register rather
  than a per-value dynamic binding, which would have cost about 770ns a value.

### Performance

- **`pr`, `pr-str` and `print` skip the printer's arm registries for the value
  types the runtime owns** — numbers, strings, chars, keywords, symbols, booleans
  and nil now go straight to the renderer's base case instead of testing ~40
  registered host-type predicates that cannot match them, and `print-method` is
  resolved through a cached var cell instead of being looked up by name per
  value. Measured over 200k values, A/B/A in one session: `pr-str` 220 ms → 162 ms
  (1.36x), `print` 235 ms → 224 ms (parity — the delta is inside run-to-run
  drift). A registered arm that could match one of those types is rejected at
  registration, so the fast path cannot silently bypass a host shim's rendering.

## [0.5.18] - 2026-08-02

Two things a program cannot work without: knowing where it broke, and getting
randomness that is actually random. An uncaught error printed no location at all
for the ordinary shape — a `-main` that tail-calls the function that throws — and
`.printStackTrace` did not exist on the value a `catch` binds. Separately, every
jolt process replayed one identical stream of "random" values, so a fleet minted
colliding UUIDs, and the UUIDs were guessable even once they were unique.

### Changed

- **A runtime error names the fn, file and line it came from, without setting
  anything.** The tail-frame history that survives tail-call elimination is on by
  default when running from source (`jolt run`, `-m`, `-M`, `-e`, the REPL); it was
  behind `JOLT_TRACE` before. This is what a plain uncaught error looked like:

  ```
  Unhandled exception: Divide by zero
  ```

  and now:

  ```
  Unhandled exception: Divide by zero
    trace:
      app.core/boom (src/app/core.clj:4)
      app.core/-main (src/app/core.clj:8)
  ```

  Each line is the one reached **inside that frame** — where the innermost
  function threw, and where every frame above it made its call — the same thing a
  JVM stack trace reports per frame, rather than the line each function happened
  to be defined on. The compiler sets the current line before each call and a
  function's entry records its caller's, so a frame's own line is the one recorded
  by the frame below it. `.printStackTrace` snapshots the throwing line on entry to
  the `catch`, so it reports the fault rather than the handler.

  The reporter walked Chez's live continuation, which TCO erases a tail-called
  frame from — so for the ordinary shape, `-main` tail-calling a fn that throws,
  every frame was gone and the error printed with no location at all. A *non*-tail
  call always worked, which is why this kept looking fixed when it was checked.

  Set `JOLT_TRACE=0` to opt out. The cost is a ring push per entry in code compiled
  at runtime; core is unaffected (the seed prelude is already compiled), so a
  seq/string/map workload measures the same either way, and it is only visible in
  code that is almost entirely user-level calls — a fib microbenchmark pays about
  7x. A `jolt build` binary is unchanged: its prologues are decided at build time,
  so it carries no tracing and no per-call cost unless built with it on.

  Tracing itself also got ~2.5x cheaper even with the per-frame lines added
  (per-thread state moved from thread parameters, whose writes cost ~32ns each, to
  Chez virtual registers at ~1ns, and the ring sizes are powers of two so a wrap is
  a mask rather than a division).

### Added

- **`java.security.SecureRandom`**, implemented natively over the same OS
  entropy: `nextBytes`, `nextInt` (both arities), `nextLong`, `nextDouble`,
  `nextFloat`, `nextBoolean`, `generateSeed`, `setSeed`, and the `getInstance` /
  `getInstanceStrong` statics. `nextInt(bound)` rejection samples rather than
  taking a bare modulo, which would bias toward the low residues. It no longer
  auto-loads `jolt-crypto`: it is a JDK class on the JVM, and reaching for one
  should not make a program declare a dependency.

### Fixed

- **`rand`, `rand-int`, `Math/random` and `random-uuid` now differ between
  processes and between threads.** Chez starts its PRNG from a fixed seed and
  keeps the state per thread, so every jolt process replayed one identical
  stream and every forked thread restarted it from the top. Two unrelated
  processes agreed on every "random" value, and eight threads in one process
  drew eight identical UUIDs. Clojure runs these off a process-global
  `java.util.Random` seeded from the clock; jolt now seeds lazily on first draw
  per thread, from the clock mixed with pid, thread id and a counter.

- **`random-uuid` and `UUID/randomUUID` now draw from the OS CSPRNG.** They were
  built out of `random`, which is seeded from the clock — unique per process
  after the fix above, but still guessable by anyone who knows roughly when the
  process started. Clojure backs `random-uuid` with `SecureRandom` because v4
  UUIDs get used as session ids, CSRF nonces and reset tokens, where guessable
  means forgeable. Bytes now come from `/dev/urandom`, or `BCryptGenRandom` /
  `RtlGenRandom` on Windows. If a host offers no entropy source at all the
  fallback says so on stderr rather than degrading quietly.


- **`(java.util.Random.)` with no seed never worked.** It seeded from
  `(truncate (current-time))`, and `current-time` answers a time object rather
  than a number, so the no-arg constructor always threw. Seeded instances were
  unaffected and still reproduce the JVM's exact LCG stream.

- **`.waitFor` on a subprocess can no longer hang forever.** It issued a blocking
  `waitpid`, which parks in the kernel — and when `SIGCHLD` is `SIG_IGN`, POSIX has
  wait block until *every* child has terminated before failing with `ECHILD`, so a
  child that became a zombie beforehand left it parked for good, with the whole
  process at 0% CPU. A program that sets `SIG_IGN` itself or inherits it could hang
  on any `.waitFor`. It polls with `WNOHANG` now (0.2ms backing off to 10ms), the
  way the timed `waitFor` already did, so no signal disposition can park it.

  Found because tracing shifts timing enough to make the process suite hit this
  every run instead of rarely; the hang predates that and is not caused by it.

- **`.printStackTrace` exists on every exception, and prints the trace.** It was
  reachable only on a raw Chez condition, so on the value a `catch` actually binds
  — an ex-info, or any typed host throwable — it answered `No matching method
  printStackTrace found for java.lang.ArithmeticException`. It now prints
  `class: message` followed by the same backtrace an uncaught error reports, to
  stderr or to a `PrintWriter`/`PrintStream` passed as its argument.

  The cause was that `java.lang.Throwable`'s methods were restated in two places
  that drifted. They are one table now (`throwable-method`), inherited by every
  exception class the way the JVM inherits them from `Throwable`, which also filled
  in `.getLocalizedMessage`, `.getSuppressed` and `.fillInStackTrace` — each of
  which existed on one kind of throwable and not the other.

## [0.5.17] - 2026-08-01

Gaps and wrong answers on the `java.lang.String` surface, found by probing it after
`.toCharArray` turned out to be missing.

### Added

- **`.toCharArray`, `.strip` / `.stripLeading` / `.stripTrailing`,
  `.compareToIgnoreCase`, `.contentEquals`, `.regionMatches` (both overloads), and
  `String/join`.** `.toCharArray` answers a real `char[]` — the value `(char-array s)`
  builds and `(String. ca)` reads back. The strip family is `Character.isWhitespace`,
  where `.trim` cuts at `<= U+0020`, so strip removes the Unicode separators trim
  leaves (U+3000) but not the non-breaking spaces Java deliberately excludes from
  `isWhitespace` — the same predicate `clojure.string/trim` already used here, now
  also covering U+001C..U+001F, which are whitespace to Java but carry no Unicode
  White_Space property.

### Fixed

- **`.compareTo` answers an int.** It returned `-1.0` / `1.0` / `0.0`, so it read
  correctly through `neg?` / `pos?` but printed as a double and was never `= -1`.

- **`String/valueOf(char[])` is the characters.** It rendered the array itself, so
  `(String/valueOf (char-array "hi"))` came back `"#object[[C]"` where
  `(String. (char-array "hi"))` already gave `"hi"`.

## [0.5.16] - 2026-08-01

Chez's clocks and collector counters are readable from Clojure now, as plain
integers off `jolt.host`, which is enough for a profiler, a health endpoint or an
OpenTelemetry exporter to work from. `System/nanoTime` and `Thread.join` were
both wrong in ways that surfaced on the way there, and `.split` turned out to be
discarding its limit argument.

The release workflow's own fleet gates were testing the wrong binary, which is
why this is the first 0.5.16 to ship.

### Added

- **Telemetry primitives on `jolt.host`.** Two clocks (`wall-nanos`,
  `mono-nanos`), the collector's counters (`cpu-nanos`, `real-nanos`,
  `gc-count`, `gc-cpu-nanos`, `gc-real-nanos`, `gc-bytes`), the allocator's
  (`bytes-allocated`, `current-memory-bytes`, `maximum-memory-bytes`),
  `thread-id`, and the runtime's own identity (`scheme-version`,
  `machine-type`). Chez tracked all of it already, but only behind record types
  — time objects and sstats — that Clojure code can't do arithmetic on. The two
  clocks stay distinct on purpose: `wall-nanos` is the only one a remote
  collector can interpret and ntp can step it, `mono-nanos` never steps but has
  an arbitrary origin, so anything reporting both an absolute timestamp and a
  duration needs both and derives the timestamp from the pair.

- **`java.util.concurrent.TimeUnit`.** The seven constants, the `to*` conversions
  (truncating toward zero, like the JVM) and `sleep`. Nothing modeled it before,
  which meant every method taking a `(timeout, unit)` pair could not be called
  with one — and that is how each of them went unnoticed with its timeout argument
  discarded. `CountDownLatch.await`, `Future.get`, `ExecutorService.awaitTermination`
  and `ReentrantLock.tryLock` all read it now: the bounded overloads gave up
  immediately, waited forever, or (awaitTermination) read the amount as
  milliseconds outright, so `5 SECONDS` was five milliseconds.

### Fixed

- **The release's own fleet gates ran the wrong binary.** Every library gate and
  the examples gate unpacked the release tarball into the workspace root and then
  picked the jolt to test with `find . -name jolt -perm -u+x`, in a workspace that
  also holds the jolt checkout — whose `bin/jolt` is an executable file by that
  name. Which one won came down to directory traversal order, and the extracted
  directory carries the version in its name, so the order flipped between one
  release and the next: v0.5.16's gates all died on "No valid Chez Scheme
  executable found" against a binary that was fine. The tarball now unpacks into a
  directory of its own and is searched only there.

- **A rebuilt binary was killed on macOS.** `jolt build` wrote its output over the
  existing file, and macOS caches a code-signature verdict per vnode — so the
  rewritten binary kept the stale verdict and the kernel `SIGKILL`ed the next run
  with no output at all (`Killed: 9`). A rebuild-and-run loop over one output path
  worked a handful of times and then started dying for no visible reason, on a
  binary that ran fine the moment it was built somewhere else. The output is
  removed before the new one is written, so it lands on a fresh inode; a failed
  link now also leaves no binary rather than a half-overwritten one.

- **`.split` honors its limit, on both `String` and `Pattern`.** The limit argument
  was discarded outright, so `(.split "user:pass:word" ":" 2)` split three ways and
  anything separating a key from a value that may itself contain the separator — a
  URL header, a password, a status line's description — got the value truncated at
  its first separator. Positive limits cap the parts and leave the last unsplit,
  a negative limit keeps trailing empty strings, and 0 (the one-argument form)
  drops them. Interior empty fields survive too: `(.split "a::b" ":")` was
  `["a" "b"]` where the JVM gives three parts. Both methods answer a `String[]`
  now; `String.split` used to return a vector and `Pattern.split` a seq, so the
  same split printed two different ways.

- **A compile error names the expression that failed.** Only the unresolved-symbol
  diagnostic carried a position, so everything else raised while analyzing — an
  uncompilable form, a destructuring pattern the desugarer rejects, a macro that
  threw expanding — was reported at the enclosing top-level form's opening line,
  over thirty lines of the analyzer's own frames (`analyze-list`, `map-seq`,
  `seq->list`) naming nothing the reader could act on. Analysis failures carry the
  innermost positioned form's `file:line:column` now, and the internals trace is
  dropped, which is what the reporter already did for the one diagnostic that had
  a position.

- **A `proxy` method with several arities.** `proxy` accepts both
  `(name [params*] body*)` and `(name ([params*] body*) ([params*] body*) ...)`;
  only the flat form was handled, so the grouped one handed `reify` a body
  expression where an arglist belonged and died in destructuring — "unsupported
  destructuring pattern: (.read src buf off (min 1 len))" for a throttled
  `InputStream`.

- **`System/nanoTime` is monotonic.** It was `(* 1000000 (now-millis))` —
  wall-clock derived, so a clock step ran it backwards, and millisecond-granular,
  so any interval shorter than a millisecond timed as zero. It reads Chez's
  `'time-monotonic` clock now, which is the JVM's contract for it.

- **`Thread.join` honors its timeout and returns on an unstarted thread.** The
  timeout argument was discarded outright, so every bounded join was an unbounded
  one — a caller that joined a long-lived worker with a timeout deadlocked
  instead of giving up. Both forms also waited on the "thread finished" flag
  rather than on liveness, and that flag is never set on a thread that was never
  started, so `join()` on one blocked forever and `join(ms)` burned the whole
  timeout where the JVM returns at once. A negative timeout throws
  `IllegalArgumentException` instead of waiting indefinitely.

## [0.5.15] - 2026-08-01

Dependency resolution reads the POM Maven would. jolt used to take a jar's
transitive deps from whatever `pom.xml` the jar happened to package, which meant
a jar that ships without one — `metosin/malli` — contributed none at all, and
projects worked around it by listing them by hand. jolt now vendors Grenadine
and builds the effective POM from the repository, so inheritance, properties,
dependency management and exclusions all count. The CLI also grew the rest of
the `clj` `-S` option surface, which is how editors ask for a classpath.

### Added

- **Maven transitive deps come from the real effective POM.** jolt used to scrape
  the `pom.xml` a jar happened to package under `META-INF/maven/`, so a jar that
  ships without one — `metosin/malli` is one — contributed no transitive deps at
  all, and a project had to list them by hand. jolt now vendors
  [Grenadine](https://github.com/clojurestar/grenadine) as a git submodule under
  `vendor/`, alongside irregex and babashka fs/process, and builds the effective
  POM from the repository: parent inheritance, properties, dependency
  management, BOM imports, and `<exclusions>`, which the expander already
  honored but never received. Resolving malli picks up its five deps and their
  transitives instead of nothing. The cost is one small `.pom` fetch per
  dependency, cached in the local repository beside the jar.

  A POM jolt can't model no longer sinks the resolution: an unfetchable `.pom`
  (a hand-installed jar, an offline machine) or a version left `${unresolved}`
  because it comes from a profile now warns and falls back to whatever the jar
  packages. Grenadine checks every declared dependency before jolt filters by
  scope, so a test-scoped dependency jolt discards anyway was enough to abort.

- **`-Spath` prints the classpath and runs nothing**, like the clj CLI. It can
  come on either side of the alias options — `jolt -A:test:dev -Spath` and
  `jolt -Spath -M:test` both print the source roots that run would use, and
  `-X`/`-T`/`-Sdeps` compose with it the same way (`-T` replacing the project's
  own basis, as it does when running). Editors ask for the classpath this way
  before connecting; jolt only had `jolt path`, which took no aliases from the
  argv it was dispatched with, so Calva's `-A:test:dev -Spath` died on "unknown
  command or task: -Spath".

- **The rest of the clj option surface: `-Stree`, `-Strace`, `-Sdescribe`,
  `-Scp`, `-P`, `-Srepro`, `-Sverbose`.**
  They compose with the aliases the same way `-Spath` does.
  `-Stree` prints the dependency tree in the tools.deps format — a top dep
  unprefixed, what it pulled in indented under it with `.`, and a node that lost
  marked `X` with the reason (`:use-top`, `:older-version`, `:excluded`,
  `:superseded`, …); the expansion already made those decisions, it just wasn't
  recording them, and `-Strace` writes the same log to `trace.edn` in the
  tools.deps shape (`{:log [...] :vmap {...}}`). `-Sdescribe` prints the
  version, the deps.edn chain, and the cache locations as an edn map, without
  resolving a single dependency, so an editor can ask cheaply and offline. `-P`
  fetches every dependency and stops — the prepare step for a CI job or a
  container layer. `-Srepro` ignores `~/.clojure/deps.edn` for one run (the
  per-run form of `JOLT_NO_USER_DEPS`), and `-Sverbose` says which files the
  resolution reads and which caches it fetches into, on stderr rather than clj's
  stdout so `-Sverbose -Spath` still pipes.

- **`-Scp` runs against source roots given on the command line**, expanding no
  dependencies — `jolt -Scp "$(jolt -Spath)" -M:test` runs offline with nothing
  fetched. The deps.edn chain is still read, so aliases, `:main-opts` and
  `:tasks` work; tools.deps' `--skip-cp` draws the line in the same place. What
  goes with the expansion is a *dependency's* `:jolt/native` shared libraries —
  the project's own still load.

- **`-Sforce`, `-Sthreads N` and `-Jopt` are accepted and ignored**, so a tool
  that always passes them isn't rejected: jolt resolves its roots on every run
  (no classpath cache to force), fetches serially, and has no JVM. An `-S`
  option jolt genuinely doesn't have (`-Sman`, `-Spom`) now names itself as an
  unsupported option instead of being reported as an unknown deps.edn task.

### Fixed

- **An undeclared alias is a warning, not an error.** tools.deps skips an alias
  the deps chain doesn't declare and says so ("Specified aliases are undeclared
  and are not being used"); jolt threw instead, so an editor sending a fixed
  alias set got no classpath at all from a project that happens to declare only
  some of them. It now warns on stderr and carries on with the aliases that do
  exist.

- **`-A` no longer resolves the project twice.** It resolved and applied the
  deps before re-dispatching the rest of the argv, and every command it
  re-dispatches to (`run`, `build`, `repl`, `nrepl-server`, a task, `-e`,
  `-M`/`-X`/`-T`) resolves for itself — so each `-A` invocation walked the whole
  dependency tree twice and printed any resolution warning twice with it.

- **`bin/jolt` runs the same Chez as the rest of the build.** `make` provisions
  its own Chez when the one on `PATH` is a different version, but `bin/jolt`
  searched `PATH` itself, so a build could straddle two installs — the targets
  calling `$(CHEZ)` getting one and the targets shelling out to `bin/jolt` the
  other. That surfaced as whichever primitive the older Chez predates
  (`variable flvector? is not bound` on a 9.x), or, once `make devboot` had run,
  as `incompatible fasl-object version`, since a fasl only loads in the Chez
  that wrote it. `bin/jolt` now takes `$JOLT_CHEZ`, which the Makefile exports.

  Separately, the devboot image now records which Chez built it, and `bin/jolt`
  falls back to source mode when that isn't the one about to run it or when it
  has since been upgraded in place. Neither shows up in the image's input list,
  so the cache read as current while nothing in jolt explained the failure.

- **A built binary serves its own source for a shadowed namespace.** Install
  roots are first-wins, but the binary baked them last-wins, so a namespace
  present on two roots — a vendored library shipping a facade under a jolt name
  — reached the binary as the wrong file while `bin/jolt` kept the right one.
  The namespace itself is compiled in and kept working; what broke was
  `io/resource`, which is how orchard maps a namespace back to a file, so an
  editor could jump to the wrong source.

### Changed

- **A deps.edn `:mvn/local-repo` now outranks the `JOLT_LOCAL_REPO`
  environment variable**, matching how tools.deps treats explicit configuration.
  `GRENADINE_LOCAL_REPOSITORY` sits between them as the shared environment
  default; `JOLT_LOCAL_REPO` still works.

## [0.5.14] - 2026-08-01

Editor tooling works: jolt publishes its source roots as `java.class.path`,
`jolt.nrepl` gained the version and error-history seams an nREPL middleware needs,
and `clojure.test` report maps carry `:expected`/`:actual` again, so a custom
reporter can say what it compared. Together these let jolt-lang/nrepl serve the
cider-nrepl op set to CIDER and Calva. A stale `PWD` no longer wins over the real
working directory, and `keys`/`vals` throw on an element that isn't an entry
instead of returning nonsense.

### Added

- **`java.class.path` answers with the resolved source roots.** jolt's classpath
  is its source roots — the project's `:paths`, every dependency's root, and the
  roots jolt ships — and the loader now publishes them through the system-property
  table. Editor tooling ported from the JVM discovers project sources through that
  property, so with it unset orchard's namespace scan, compliment's classpath
  completion sources and cider-nrepl's `classpath` op all quietly returned nothing.

- **`jolt.nrepl`: `register-version!`, REPL history vars, and the last error's
  backtrace.** Middleware could register ops but not versions, so an editor had no
  way to learn what dialect the server speaks (CIDER refuses the cider-nrepl ops
  without a version entry); `register-version!` is the seam, beside
  `register-ops!`. `evaluate` now sets `*1`/`*2`/`*3` and `*e` like every other
  nREPL server, and records the backtrace of the exception in `*e`
  (`last-error-backtrace`) — a jolt exception carries no stack of its own, and the
  backtrace is only readable where it was caught, so tooling that presents the
  error afterwards had nothing but the message. `*capturing-thread*` names the
  thread whose output an eval is capturing, so middleware that forwards server
  output doesn't send an eval's own output twice.

### Fixed

- **`clojure.test` report maps carry `:expected` and `:actual`.** Assertions
  folded both into a rendered `:message`, leaving every custom reporter — CIDER's
  test op, test.check, matcher-combinators, any TAP/JUnit reporter — with nothing
  to report: a failure said what it printed but not what it compared. `:expected`
  is now the form as written and `:actual` the form with its arguments evaluated
  (or, for an error, the throwable itself rather than its message text), matching
  clojure.test. `(is (instance? C x))` reports the class of `x` on both branches,
  and `is` yields the value it tested, both like the reference.

- **`clojure.core/hash-combine` hashes its second argument.** It is
  `(Util/hashCombine x (Util/hash y))` — a seed and a VALUE — but jolt passed `y`
  straight to the integer combiner, so `(hash-combine 0 "a")` threw out of
  `bitwise-and` instead of hashing. Any ported library that folds `hash-combine`
  over values died on the first non-number.

- **A keyword's `.hashCode` is the Java hash, not its hasheq.**
  `Keyword.hashCode()` is `sym.hashCode() + 0x9e3779b9`; jolt answered with the
  murmur-based hasheq, so a keyword's `.hashCode` disagreed with the JVM while a
  symbol's agreed.

- **`.listFiles` / `file-seq` keep the form of the path they were given.** Like
  `new File(this, name)`, listing a relative directory yields relative children;
  jolt resolved the base to an absolute path first, so every child came back
  absolute and a caller relativizing the results against the directory it passed
  in (classpath scanning) got `../..`-prefixed garbage.

- **`java.util.Map`'s default methods on the HashMap shim.** `putIfAbsent`,
  `computeIfAbsent`, `computeIfPresent`, `compute`, `merge`, `replace` and
  `forEach`, with the JVM's return values and its treatment of a nil mapping as
  absent.

- **A stale `PWD` no longer decides `user.dir`.** `PWD` is exported by the shell
  and is not updated by a process that changes directory itself, so any tool that
  ran jolt after a `chdir` resolved every relative path against the directory it
  started in. `user.dir` now prefers `JOLT_PWD`, then the real working directory,
  and honors `PWD` only where it agrees with it.

- **`keys` and `vals` throw on an element that isn't an entry.** Both indexed
  every element blindly, so `(keys ["ab" "cd"])` handed back `(\a \c)` and
  `(keys [1 2])` gave `(nil nil)` where the JVM throws — silent nonsense in place
  of an error. Anything that is not a two-element vector now raises the same
  `ClassCastException`, naming the same class. A vector of pairs still walks as a
  seq of entries, which is a documented superset.

## [0.5.13] - 2026-08-01

Locale-sensitive formatting works: `NumberFormat/getCurrencyInstance`,
`SimpleDateFormat`'s month and day names, and `String/format`'s decimal separator
all honor a `Locale`, with the per-locale data supplied by jolt-lang/time through
a new extension-point seam. `io/resource` returns a `java.net.URL` like the JVM,
`:use` honors `:exclude`, and a mismatched delimiter reports its position instead
of hanging the reader.

### Fixed

- **`:use` honors `:exclude`, and `(:refer-clojure :exclude …)` lands in the ns
  being defined.** Two host namespace bugs, one visible failure surface: a library
  test ns that `:use`s two namespaces exporting the same name got the WRONG one.
  `use` registered its refer-all with no record of the spec's `:exclude`, so with
  `(:use [a] [b :exclude [f]])` the bare `f` resolved to `b/f` — the later use
  shadowed the earlier, exclusion or not — instead of falling through to `a/f`.
  Excluded names are now recorded per (ns, target) and skipped in the refer-all
  walk, so resolution falls through exactly like load-lib's filtered refer.
  Separately, the `refer-clojure` macro registered its exclusions at macroexpansion
  time under the analysis-time ns, so a `(:refer-clojure :exclude [==])` clause in
  an ns form excluded nothing (the ns it named didn't exist yet); the expander now
  emits a runtime registration call that runs after the form's `in-ns`, and unwraps
  the ns macro's quoted args the way the JVM's splice-into-`refer` does. This is
  what was behind core.logic's nominal suite residue (64/36/6 → 106/0/0): the test
  ns's plain `fresh` was silently nominal's `fresh`, and fd.clj's `-rator`
  syntax-quotes qualified to `clojure.core/==` instead of
  `clojure.core.logic.fd/==`.

### Changed

- **`byte-array` elements are signed bytes, −128..127, like the JVM's `byte[]`.**
  They were unsigned 0..255, so `(vec (byte-array [255 128]))` was `[255 128]` where
  the JVM gives `[-1 -128]`, and every numeric look at a high byte disagreed:
  `(neg? b)` never fired, `(= b -1)` was never true, `(reduce + bytes)` summed to a
  different number, and a `(bit-and b 0xff)` mask that is load-bearing on the JVM
  was a no-op here. Nothing errored — the answers were just quietly different.

  This is one representation change across every producer and consumer, not a
  per-call-site patch: `na-byte-of` is the one place a value entering a byte array is
  narrowed (`Byte.byteValue()` semantics — truncate toward zero, low 8 bits, fold the
  sign), `na-bv->bytearray` the one place raw bytes become a byte array, and
  `na-bytearray->bv` the one place they go back. `byte-array` / `.getBytes` /
  `String.` / stream reads / `Files/readAllBytes` / `jolt.fs` / `io/copy` /
  `ByteBuffer` / Base64 / `Random/nextBytes` / `jolt.ffi` read-array/write-array all
  route through those three, so bytes survive any round-trip byte-exactly. `aset` on
  a byte array narrows rather than storing raw — the JVM rejects `(aset bytes 0 200)`
  because it can see 200 is an Integer, and jolt has one integer type, so narrowing
  is what keeps the array's range invariant true for `aget`/`seq`/`String.`.
  `InputStream.read()` stays unsigned 0..255, which is its contract and the only way
  a caller can tell `0xff` from end-of-stream.

  `(byte-array [-1.9])` is now `-1`, not `-2` — the JVM's `d2i` truncates toward
  zero where this floored.

- **`format`'s `%x` / `%X` / `%o` are unsigned conversions.** They printed a signed
  magnitude, so `(format "%x" -1)` was `"-1"` — wrong under any width. The JVM takes
  the width from the argument's type (`Byte` 8 bits, `Short` 16, `Integer` 32, `Long`
  64); jolt unifies every integer as one type and so takes the narrowest width that
  holds the value. That is the JVM's answer whenever the value's origin type is the
  narrowest that holds it, so an unmasked byte out of a `byte[]` prints two digits
  and an int-sized value eight — which is what the common hex-dump and
  percent-encoder idioms need, and it keeps ring-codec and cognitect aws-api's signer
  correct unmodified. A long whose value fits narrower is the one case that
  diverges (`(format "%x" (long -1))` is `"ff"` here, 16 digits on the JVM); it is
  entered in `known-divergences.edn` under `:integer-box-model`. `(bit-and b 0xff)`
  pins the width explicitly and is identical on both.

- **`clojure.java.io/resource` returns a `java.net.URL`, like the JVM.** It returned a
  `java.io.File`, which `io.ss` papered over by answering `getProtocol`/`getFile` on a
  File. Callers that branch on the real type broke: Selmer's `render-file` does
  `(instance? java.net.URL path)`, took the `:else` branch on a File, and died on
  `(.startsWith ^File …)`. Both branches now return a URL — a `file:` URL for a hit on
  a source root, a `jar:`-classed embedded resource (class `java.net.URL`) for a file
  baked into a built binary — so the "same surface whichever branch served it"
  invariant holds in `make test`, not only inside a built binary. The File URL-compat
  kludge is gone; a File no longer answers URL methods, as on the JVM.

  A URL is now a first-class source too: `slurp` / `io/reader` / `io/input-stream` /
  `.openStream` read a `file:` URL's target (a non-file protocol raises, as the JVM
  does, rather than returning empty content) and `io/file` strips the scheme. These
  had to land before the return-type flip or the common `(slurp (io/resource …))`
  idiom would throw.

### Added

- **`jolt build` compiles the runtime half of its flat source once and keeps the
  fasl.** A build emits one flat Scheme file — jolt's runtime (`rt.ss`, the
  `clojure.core` prelude, the compiler image, the loader) followed by the app — and
  handed the whole thing to Chez every time. The runtime half is byte-identical for
  every app a given jolt builds in a given mode (verified: two unrelated apps
  produce the same 3.0 MB to the byte), and compiling it is ~2.6s. It is now emitted
  to its own `runtime.ss`, compiled once per (content, mode), and the fasl reused;
  the two units are loaded into the boot in order, so the runtime's defines still
  precede the app's reads.

  A small app's build is mostly that one compile, so this is most of its build time:
  `examples/hiccup-app` goes from 3.13s to 0.50s. A large app amortizes it against
  its own work (`examples/ring-app` loses ~2.6s of ~42s). Cached under
  `~/.jolt/runtime-cache` (`JOLT_RUNTIME_CACHE_DIR`), newest 8 entries kept;
  `JOLT_RUNTIME_CACHE=0` opts out and `JOLT_NO_FLAT_SPLIT=1` restores the one-file
  build. Skipped for `--tree-shake` (which rewrites the prelude per app), for
  `--library`, and for cross builds.

- **`JOLT_BUILD_PROFILE=1` reports each build phase's wall-clock time**, including a
  breakdown inside the two expensive ones (the whole-program fixpoint and the emit
  walk). `bench/build-phases.sh` drives it across build modes and prints the split
  between jolt's own passes and Chez's compile. A build's cost divides between those
  two and they want unrelated fixes, so which one dominates is worth being able to
  see rather than assume — it is not the same for a small app as for a large one.

### Fixed

- **`.toAbsolutePath` was a no-op on a relative path in a built binary, so every
  `fs/glob` under a relative root came back unusable.** A user-facing relative path
  resolves against user.dir, which is `JOLT_PWD` → `PWD` → `"."` — the chain
  `System/getProperty "user.dir"` answers with. `project-relative` implemented only
  the first link, and `JOLT_PWD` is exported by `bin/jolt` but by nothing in a built
  binary, which never cd's away and so needs none. There the path came back
  unresolved, `jfile-abs` returned a relative string in defiance of its own
  contract, and babashka.fs's `match` — which relativizes each result against
  `(absolutize "")` whenever the glob root is relative — subtracted an absolute cwd
  from a relative entry: `(fs/glob "examples" "**")` yielded
  `../../../../examples/sample.clj`. Nothing threw; every subsequent open just
  missed. `project-relative` and `jfile-abs` now share one `jolt-user-dir` helper,
  so neither can implement half the chain again.

  The dev launcher masked this end to end — it always exports `JOLT_PWD`, so no
  `bin/jolt` run could reproduce it — and `test/chez/fs-test.clj` rooted every case
  at an absolute temp dir, so the one gate that runs a built binary never exercised
  a relative path. It now asserts that a relative path absolutizes under user.dir
  and that `relativize` undoes `absolutize`, the round-trip `match` performs.

- **Java regex translation now matches the JVM on 17 long-tail `Pattern` edge cases.**
  The `Pattern`→irregex translator (`host/chez/java/regex-translate.ss`) now agrees
  with `java.util.regex.Pattern` on accept/reject for flag groups, character-class
  intersection, inverted ranges, malformed quantifiers, and class-only escapes:
  - empty and unknown flag groups (`(?)`, `((?){0,0})`, `(?c:Z)`) now compile, while
    a dangling `*`/`+`/`?` after a body-less flag group (`(?)?`) is rejected;
  - `&&` intersection with an empty side means "everything" (`[&&x]`, `[x&&]`,
    `[%-&&&]`, `[x&&&&]`), and a leading `&&` with no left operand (`[&&&]`) still
    rejects;
  - inverted character ranges (`[b-a]`, `[]-X]`, `[x-\cx]`, `[{\x{10000}-}]`, and the
    nested `[[[[{-\c}]]]]`) now reject;
  - a quantifier with min greater than max (`{1,0}`) now rejects even with no
    preceding atom;
  - `\Q..\E` (empty) and `\R` are rejected inside a character class;
  - `\e` is now ESCAPE (U+001B), not a literal `e`.
  20 JVM-certified rows added to `test/chez/corpus.edn`.

- **`conj` of a map into a `defrecord` merges the map's entries, as on the JVM.**
  The default record `conj` handler treated its argument as a single `[k v]` pair and
  `nth`'d it, so `(conj (map->R {:a 1}) {:b 2})` threw
  "nth not supported on this type: clojure.lang.PersistentArrayMap" instead of
  merging; `merge`-ing a map into a record hits the same `conj` path. This surfaced
  through test.chuck: `instaparse.failure/augment-failure` does
  `(merge <Failure> {:line … :column …})`, so a regex that fails to parse raised an
  uncatchable `UnsupportedOperationException` where the library (and the JVM) raise a
  catchable `ExceptionInfo {:type ::regexes/parse-error}`. A map argument now folds
  its entries; a `[k v]` pair or `MapEntry` is unchanged.

- **`clojure.pprint`'s `simple-dispatch` and `code-dispatch` are multimethods, so
  libraries can extend them.** They were plain functions that `case`d on a type
  keyword, so `(. clojure.pprint/simple-dispatch addMethod Tie pprint-tie)` — which
  core.logic's nominal namespace does — failed with "No matching method addMethod",
  and `clojure.core.logic.nominal.tests` could not load. Both are now `(defmulti …
  class)` with methods for the same interfaces the reference uses
  (`IPersistentVector`/`-Map`/`-Set`, `PersistentQueue`, `ISeq`, `IDeref`, `nil`,
  `:default`; `code-dispatch` adds `Symbol`), each arm still calling the per-type
  printer it always did, so built-in output is unchanged — a defrecord still prints
  as a bare map, as it does on the JVM.

- **A sub-process that could not be waited on hung the caller forever.** The reap
  loop retried on any `waitpid` failure, including `ECHILD` — the child already
  reaped by something else, which no number of retries changes. The loop holds the
  process's mutex, so it did not merely spin: every other method on that process
  deadlocked behind it, silently and indefinitely. This is what sat on a CI gate for
  3h42m. `EINTR` is now the only retried failure; an unwaitable child resolves to a
  status (128+signal when jolt signalled it, else 0 — the JVM always reaps its own
  children and so always knows, jolt cannot recover a status the kernel consumed).

  The condition is reachable through no fault of the program: with `SIGCHLD` set to
  `SIG_IGN` the kernel reaps every child itself, and that disposition survives
  `exec`, so jolt can inherit it from any parent. The first spawn now restores
  `SIG_DFL` when it finds `SIG_IGN`, leaving a real inherited handler alone.

- **`(.availableProcessors (Runtime/getRuntime))` always answered 1.** It was
  hardcoded, so nothing sized to the machine — `pmap` in particular ran a fixed
  4-wide window regardless of how many cores were available. It now reports the
  processors this process may actually use: `sched_getaffinity` on Linux, so a
  process confined by `taskset` or a cpuset sees its real limit rather than the whole
  machine (what the JVM and `nproc` report); `hw.logicalcpu` on Darwin;
  `NUMBER_OF_PROCESSORS` on Windows. `pmap` sizes its look-ahead from it, as Clojure
  does. A cgroup CPU quota is not yet reflected (jolt-j4sd).

- **`{n}` in a regex meant `{n,}`.** The translator handed irregex an unbounded
  upper bound for an exact count, so every exact repetition matched greedily past
  it: `(re-find #"\d{4}" "20260729")` returned the whole string instead of `"2026"`,
  `(re-matches #"\d{4}" "20260")` matched where the JVM returns nil,
  `(re-seq #"\d{2}" "123456")` gave one element instead of three, and
  `#"(?:%[0-9a-f]{2})+"` ran past the last percent-escape — which is how
  ring-codec's `percent-decode` came apart. `{n,}` and `{n,m}` were always right;
  only the comma-less form was wrong.

- **`jolt <task>` lost to a same-named directory.** A bare argv token is dispatched
  as a file to run before a `:tasks` lookup, and the "is this a file" test was
  `file-exists?`, which is true for a directory too. `test` is a `:tasks` entry AND a
  `test/` directory in every jolt project, so `jolt test` was dispatched as a path
  and died in `load-file`'s decoder — `failed on #<binary input port test>: is a
  directory` — instead of running the task. That is why every library's CI spells out
  `jolt -M:test`.

- **`Base64` handed back an opaque host buffer instead of a `byte[]`.**
  `.decode` / `.encode` return `byte[]` on the JVM, so `(vec (.decode dec s))` is
  ordinary Clojure; here they returned a raw Chez bytevector that no collection
  dispatcher knows, so that threw `Don't know how to create ISeq from` and callers
  had to route every result through `String.` first. Both return a byte array now,
  and `bytes?` is true of them.

- **`Random/nextBytes` produced a different stream from the JVM for the same seed.**
  It drew 8 bits per byte, consuming the LCG four times as fast as
  `java.util.Random`, which draws one `nextInt()` per four bytes and takes them
  low-to-high. Every other `Random` method already matched; this one did not, so a
  seeded byte fill was not reproducible against the JVM.

- **`io/copy` from a `File` to anything but another file went through text.** A File
  source was only treated as a byte source when the destination was also a file;
  everything else fell through to slurping it as UTF-8, which replaced each
  non-UTF-8 byte with U+FFFD. `(io/copy f stream)` on a binary file returned
  corrupt bytes.

- **`Arrays/toString` printed a jolt vector.** `"[1 2]"` rather than the JVM's
  `"[1, 2]"` — no commas, a `nil` element rendered empty instead of `null`, and a
  string element came out `pr`-quoted.

- **`Integer/toString` with a radix uppercased its digits** (`"-FF"` for
  `(Integer/toString -255 16)`, where the JVM gives `"-ff"`), and `Long` was missing
  `toHexString` / `toOctalString` / `toBinaryString` / `toString` / `compare`
  altogether. `Character/isLetter` and `isLetterOrDigit` were missing too — aws-api's
  request signer classifies each UTF-8 byte of a URI through them.

- **A compile-time error pointed at the top of the enclosing form, not at the
  expression that failed.** The only position available to the reporter was the one
  the loader records per TOP-LEVEL form, so an unresolved symbol partway into a
  long `defn` was reported at the `defn`'s opening line — 280 lines above the
  offending name in the case that prompted this. The analyzer now tracks the
  innermost enclosing form that carries reader metadata and attaches its
  `:line`/`:column`/`:file` to the diagnostic, which the human report and the
  `JOLT_DIAG=edn` map both prefer over the coarser one. The reference compiler
  reports the same position for the same file, down to the column.

  The form is tracked, not its position map, because building the map allocates and
  this runs for every list form the analyzer walks; the map is built once, on the
  error path. `analyze-list` saves and restores the cell around its children, so a
  finished sibling subtree cannot leave a deeper position behind for a later
  sibling's diagnostic — the same thing `Compiler.analyzeSeq` does by pushing
  thread bindings of `LINE`/`COLUMN`, for the same reason. A release build of
  `examples/ring-app` takes the same 43s it did before.

- **A compile-time error printed the analyzer's own call stack as its "trace".**
  Around thirty frames of `analyze-list` / `analyze-seq` / `map-seq` / `seq->list`,
  which are jolt compiling the form rather than anything from the program, and they
  pushed the message and the location off the top of the report. Such an error is
  raised while ANALYZING, so there is no user call stack to show, and on the
  open-world path a user frame would carry no location anyway. A diagnostic
  carrying `:jolt/error` now reports message and location only. A runtime error's
  trace is unchanged.

- **`make devboot`'s cache turned source-map registration off**, so the dev CLI's
  traces printed bare procedure names where the released binary prints
  `ns/name (file:line)`. `emit-image.ss` disables both var-cell caching and source
  registration at load time — a build must emit byte-identical output carrying no
  absolute paths — and the image loads the build subsystem eagerly, so it baked the
  build settings. The var-cache half of this was fixed in 0.5.11; source
  registration was missed. Both are restored now. The symptom was that the
  source-mapped-trace smoke checks passed in script mode and failed only against a
  fresh cache.

## [0.5.12] - 2026-07-29

Stack traces from a build, and from a binary built without direct-linking, now
carry the file and line they came from. `#{1 1}` is a read error, as on the JVM,
and `:as-alias` aliases without loading — both at the REPL and through a build.

### Fixed

- **An open-world build's stack traces had no namespace, file or line.** A
  direct-linked build registers each fn def's source, so an uncaught error maps its
  frames to `app.util/deep-boom (…/util.clj:24)`. The registration was gated on
  direct-link, so `jolt build --no-direct-link` printed a bare `deep-boom` with
  nothing to locate it. The build turns `source-reg` on when it is not
  direct-linking — the same switch the runtime eval path already sets, so an
  open-world binary now reads like a `jolt run` trace. A direct-link build is
  unchanged and nothing registers twice.

- **`#{1 1}` compiled to `#{1}` instead of being a read error.** The JVM rejects a
  duplicate element when the reader builds a set literal
  (`PersistentHashSet/createWithCheck`); jolt only checked on the DATA path, so
  `(read-string "#{1 1}")` threw while the same literal in a source file quietly
  became a one-element set. Map literals were already checked. Elements compare as
  read, like the JVM: two symbols are distinct, two equal lists are not, and the
  runtime builders (`set`, `hash-set`) still dedupe silently.

  Neither check runs in the build's scan mode, which is a fix in its own right: an
  auto keyword whose alias is not registered yet keeps the ALIAS TEXT as its
  namespace there, so `#{::o/x :o/x}` read as two copies of `:o/x` and the
  duplicate check rejected it — failing the build of a namespace that loaded fine.

- **`:as-alias` loaded the namespace, and did not alias it.** Clojure 1.11's
  `:as-alias` establishes the alias without loading the target, for a namespace that
  may not exist yet or exists only to qualify keywords; `load-lib` picks its loader
  with `need-ns (or as use)` and falls to `(create-ns lib)`. jolt loaded the target
  and then dropped the alias on the floor, so the namespace's side effects ran and
  `::o/x` was still an invalid token. A spec that also carries `:as`, or that
  arrives through `use`, still loads.

  `jolt build` got both halves wrong too, independently of the loader: its require
  scan counted an alias-only spec as a dependency, so the target was emitted into
  the binary and its top level ran there, and the emitted `ns` prelude replayed
  `:as` but not `:as-alias`, so the alias was missing at runtime. Combining
  `:refer` with `:as-alias` throws on both jolt and the JVM — the target is not
  loaded, so there is nothing to refer — with different message text.

- **A `jolt build` failure reported no location.** The build has three walks that
  process a source file without evaluating its forms — the require scan, the
  whole-program inference walk, the emit walk — and none reaches
  `jolt-enter-form!`, which is what records where we are. So a failure in any of
  them printed `Unhandled exception: …` over a trace of runtime procedure names
  (`rdr-form->data`, `bld-ns-requires`, `dfs`) and said nothing about which file it
  was reading. They record it with `jolt-enter-file!` now.

  That is a bare set rather than a `parameterize` on purpose: the uncaught reporter
  runs from the CLI's guard, outside every dynamic binding the failing walk held,
  so a parameterized value has already unwound by the time it is read. It is the
  same reason `jolt-enter-form!` sets rather than binds, and why `load-jolt-file*`
  restores on normal return only. Entering a file also clears any leftover
  line/column, which belonged to whatever was last evaluated somewhere else — a
  build error pointing into `jolt/main.clj` would be worse than one pointing
  nowhere.

  The frame names themselves are unchanged. Only a direct-link or AOT build
  registers procedure sources, so on the open-world path a frame maps to a bare
  name; that is the documented trade-off in `source-registry.ss`, and the location
  line is what carries the actionable part.

## [0.5.11] - 2026-07-29

A warm AOT cache no longer replays a second copy of the stdlib namespaces a
library requires, which had been silently undoing whatever that library
registered over them, and `apply` no longer realizes an infinite seq before
handing it to a variadic fn. `examples/ring-app` builds. `*allow-unresolved-vars*`
and `*compile-path*` now do what they do on the JVM, and a batch of conformance
work from the compliment and orchard suites lands with them.

### Added

- **`clojure.core/compile` and a working `*compile-path*`.** `*compile-path*` was
  a var jolt exposed with the JVM's default and nothing behind it, and `compile`
  did not exist at all. Both now work the way core.clj and `Compiler.compile`
  describe: `(compile 'my.lib)` binds `*compile-files*`, loads the lib, and writes
  its compiled form under `*compile-path*`; a nil `*compile-path*` raises
  `*compile-path* not set`. The artifact is a Chez fasl of the emitted Scheme —
  the same thing the AOT cache produces — beside the `.scm` it was built from and
  a `.meta` describing what it was built against, in place of the JVM's `.class`
  files. Like the JVM, the compile carries through the lib's whole load closure,
  and the output directory has to be a source root (jolt's classpath) before a
  later load will pick it up, so `(compile 'app)` into a directory you then put on
  the roots gives you a project that runs with no source present.

  `RT.load` prefers a `.class` to its `.clj` on mtime. jolt compares a content
  hash instead — the rule the AOT cache already decides by, and immune to a bare
  `touch` — and refuses an artifact outright unless the jolt version and runtime
  fingerprint in `.meta` match, since a fasl from another build calls runtime
  helpers that may be gone. `.meta` also records the direct requires and their
  hashes, so editing a namespace this one requires invalidates it; a change
  further down the graph does not, the same discipline JVM AOT needs.

- **`areduce` and `amap`.** Index loops over `alength`/`aget`/`aset`/`aclone`,
  all of which jolt already had, so they were never JVM-only — they had been
  parked in the JVM-only macro suite beside `gen-class`. `orchard.profile` needs
  them.

- **`java.util.Arrays/sort`.** Sorts in place and returns void, so it writes back
  through the array's own backing rather than building a new one, and its
  comparator argument routes through the same seam `sort` uses. `list-sort` is a
  stable merge sort, matching `Arrays.sort` over objects.

- **`clojure.repl`, and a `java.lang.Thread` model.** `run`/`start`/`join`/
  `isAlive` with `instance?` against `Runnable`, `Integer/compare` as a 3-way int
  comparison, `Keyword/table` reflectively visible, and `NoSuchFieldException` in
  the throwable hierarchy.

### Fixed

- **A cached namespace swallowed the install-owned namespaces it required, and
  replaying them undid what its siblings registered.** The AOT capture teed every
  form compiled while a namespace loaded. A cacheable require redirected that — the
  nested `aot-capture-load` opens its own port — but an install-owned require
  bypasses the cache entirely and so never did, and its forms landed in the
  *requiring* namespace's artifact. `jolt.time` is a 14-line `ns` form; it cached as
  412 KB carrying whole second copies of eight `jolt/time/*` stdlib namespaces.

  On a cache hit those copies replay after the require that already loaded them
  properly, so any top-level registration a sibling namespace layered on top gets
  undone. `jolt.time.local` registers an ISO-only `java.time.LocalDate/parse` that
  ignores a formatter; `jolt.time.fmt` overrides it with the pattern-aware one. Cold,
  the override held. Warm, `local`'s baked copy landed back on top of it, and
  `(t/parse-date "2020/02/02" (t/formatter "yyyy/MM/dd"))` silently parsed as ISO —
  `substring: 11 and 11 are not valid start/end indices`. Deterministic: cold green,
  warm red, `JOLT_AOT_CACHE=0` green.

  The capture is now bound to the file it was opened for, so no nested load can
  append to it, whether the cache handles that namespace or bypasses it. `jolt.time`
  caches as 582 bytes — its `ns` form, which is all it has. `clojure.core/compile`
  shares the capture and had inherited the same bug.

- **`*allow-unresolved-vars*` affects resolution.** `clojure.core/*allow-unresolved-vars*`
  read `false` and did nothing; the analyzer consulted a separate
  `jolt.analyzer/*allow-unresolved-vars*` that only jolt's own nREPL knew to bind.
  There is now one var, clojure.core's, read through `jolt.host/allow-unresolved-vars?`
  the way `Compiler.resolveIn` reads `RT.ALLOW_UNRESOLVED_VARS` — and like the JVM
  only for an unqualified symbol with no mapping, so `resolve`/`ns-resolve` still
  answer `nil` and a qualified symbol still throws. Bound true, jolt emits a
  late-bound var-ref in the compiling namespace, so a name defined by a later eval
  resolves; the JVM's `UnresolvedVarExpr` emits no bytecode and fails later with a
  `VerifyError`, which is tracked in `known-divergences.edn`.

- **`apply` realized a lazy rest before every variadic call.** `(apply (fn [& xs]
  (take 3 xs)) (range))` returns on the JVM, where `RestFn.applyTo` hands the seq
  to the variadic arity unrealized; here it allocated until the process died.
  `orchard.profile-test` reaches it through `(apply baz (range))` and took a
  machine down through swap exhaustion. The cause was the calling convention, not
  `apply`: an emitted variadic arity is a plain Chez `(lambda (a b . rest) …)` and
  a Chez rest parameter must be a proper list, so the tail had to be realized to
  cross that boundary — `jolt-apply` had a hard-coded exception for `concat` and
  nothing else. Variadic arities now bind their rest through `jolt-rest-seq`, each
  emitted variadic closure registers its variadic arity's fixed-param count, and
  `jolt-apply` peels that many plus one and passes the remainder as a box. Only
  registered callees ever see a box, which keeps the ~115 hand-written Scheme
  variadics that read their rest list directly working. Peak RSS on the repro goes
  from unbounded past 2.6 GB to 69 MB.

- **The reader took any qualified `->x`/`map->x` call for a record literal's
  factory form.** Ordinary code calls those functions too — `(u/->long n)`
  throughout jolt.time — and the data path applies a factory form, so reading such
  a file as data applied an unbound var. A build reads every source file as data
  to scan its requires, so nothing depending on jolt-lang/time could be built.
  Reader-built factory forms are marked by identity in a weak side table now, like
  `rdr-map-order`, and the name test is gone.

- **`jolt build` emitted the app section with the loader's order appended last.**
  The static require closure drops install-owned files, so a stdlib namespace an
  app namespace requires arrived only through the loader hook and landed behind
  its callers — the binary died at startup with `Attempting to call unbound fn:
  #'jolt.time.impl/register-type!`. The hook's order is dependency-correct by
  construction, so it leads now, with closure entries the hook never saw in front.

- **`proxy-super` was a function**, so its method-name argument was analyzed as an
  expression and `(proxy-super reset)` in `clojure.tools.logging/log-stream`
  failed to resolve `reset`. It is a macro now, as on the JVM, still throwing when
  the body runs since a proxy desugars to a reify with no superclass.

- **`jolt -Sdeps '{…}' build` reached `cmd-build` with `jolt.host/build-binary`
  unbound.** The launcher loads the build driver on demand and looked for `build`
  at argv[0] only, but `-Sdeps` and `-A` re-dispatch the rest of the argv.

- **An unresolved symbol in a nested body was late-bound instead of reported.**
  The analyzer only raised "Unable to resolve symbol" for a symbol at the top
  level of a compilation unit; inside any fn, loop or let body it bound the name
  to a var in the compile ns whose root is an unbound sentinel, so a typo surfaced
  much later as a type error on whichever unbound reference was used
  arithmetically first — usually not the symbol that was misspelled. A missing
  `areduce` presented as `'#[jolt-var-unbound-v1 "orchard.profile" "i"] is not a
  number'. The check applies wherever the symbol appears now, matching the JVM.
  Legitimate forward references are unaffected: `declare` and `(def name)` intern
  a resolvable cell first. Four latent forward references fell out, all of which
  JVM Clojure would reject too.

- **`io/resource` returned two incompatible types.** A path on a source root came
  back as a jfile, carrying a URL-compatibility surface; a path in the embedded-
  resources table came back as a bare record with no methods and no class arm, so
  `.getPath` threw and `(class r)` read `:object`. Which branch served a stdlib
  path depended on whether `target/dev/flat.so` was fresh, which is why
  `orchard.meta-test` kept moving between 63 and 67 passing assertions with no
  relevant code change.

- **`-e` printed its result with the `str`-style printer**, so a nested string
  lost its quotes and a char its reader syntax: `["hi" \c 1]` printed as
  `[hi \c 1]`. Clojure's REPL prints with `pr`, which is what makes a printed
  result read back as the value it names. `nil` still prints as nothing, matching
  `clojure -M -e nil`. `str`, `print` and `println` are untouched.

- **Comparators were coerced in three unrelated places and only one knew about
  Comparator objects.** `sort` tested how the value was built rather than what it
  can do, so a `deftype` Comparator threw ClassCastException, and `sort-by` and
  `sorted-map-by`/`sorted-set-by` invoked the value directly and threw for `reify`
  and `deftype` alike. All four go through one `__comparator-fn` seam now, which
  asks whether the value has a `compare` method. Plain fns, 3-way or boolean, are
  unchanged.

- **An explicit `{:arglists '([x])}` in a `defn`/`defmacro` attr-map was
  discarded**, because both assembled the derived parameter vectors last. The
  derived value is a default the attr-map overrides now, matching the JVM's order:
  name metadata, then derived, then attr-map, then docstring. `^{:arglists …}` on
  the *name* still does not win, because the JVM ignores it there.

- **Conformance fixes from the compliment and orchard suites.** syntax-quote
  lowers metadata as templates, qualifies class tags to FQNs and strips reader
  position keys; `defmacro`/`def` land docstring, attr-map, arglists and
  class-typed `:tag` metadata on the var; `get-method` dispatches through `isa?`;
  jrec gains its collection methods; `jolt-write` goes through a rebound `*out*`
  writer like the JVM; `empty?`/`with-out-str` regressions fixed and an unknown
  object renders as `#object[…]`.

### Changed

- **Static fields are a registry keyed on class + field**, rather than a string
  pair hard-coded inside `Class.getDeclaredField`'s cond. `Keyword/table` is its
  first row.

- **Dropped the unused `__register-seq!` seam** (`get!`/`empty!`/`count!`/
  `contains!`). It had no caller anywhere — not the stdlib, jolt-core, the tests,
  the vendored libraries or the conformance libraries — and never shipped in a
  release, so nothing external can depend on it.

## [0.5.10] - 2026-07-28

An optimized build no longer discards a `throw` written in a map value that the
map's only reader never looks at.

### Fixed

- **An optimized build could swallow a `throw`.** The inline pass admitted
  `:throw` to `safe-op?`, the predicate that marks an IR node as safe to move.
  `pure?` and `total?` both fall through to `safe-op?` for anything that isn't an
  `:invoke`, so both accepted a throw, and `total?` is what `elim-let-structs`
  consults before dropping a scalar-replaced map binding whose values are never
  read. The result was that `(let [m {:a 1 :b (throw "boom")}] (:a m))` folded to
  `1` under `--opt --direct-link`: the binding disappeared and took the throw with
  it, so a release binary returned a value where the interpreter and the JVM both
  raise. `:throw` stays in `safe-op?`, because an inlined body may contain one and
  splicing it preserves it, but `pure?` and `total?` now reject it explicitly. A
  throw is relocatable and never discardable. `test/chez/inline-throw-app` covers
  it end to end through a `--opt --direct-link` build, next to the existing case
  for a throwing sibling behind a non-pure operator like `/`.

### Changed

- **A numeric shim extends the tower through `register-num-arm!` instead of
  assigning core vars.** `java/bigdec.ss` reached into nineteen runtime vars with
  `set!` at load time, which put the core's arithmetic, predicate, cast and
  comparison entry points in a shim's hands and left `predicates.ss` holding the
  jbigdec representation for `==`. `seq.ss` now owns the extension point, in the
  same shape as `register-eq-arm!` and `register-compare-arm!`: a shim hands over
  `(lambda (prev) handler)` and a handler declines what it cannot take by calling
  `prev`. An op name is the runtime var it extends with the `jolt-` prefix
  stripped, so nothing has to be memorized and a name that doesn't follow the rule
  raises when the shim loads. bigdec registers its arithmetic, predicate, cast and
  `==` arms this way and its ordering through the existing `register-compare-arm!`,
  and the core no longer names jbigdec in `==`.
- **The `seqable?` shim check lives with the class table.** `post-prelude.ss`
  carried its own list of `jhost` tags that are `Iterable` on the JVM, duplicating
  knowledge that belongs to `java/host-static-classes.ss`. It now calls
  `jhost-seqable-shim?`, defined next to the `ArrayList`/`HashSet`/`HashMap` arms
  that own it.
- **The Chez compatibility preamble moved to the top of `rt.ss`.** The global
  `error` shadow and the expression-position `cond-expand` shim were defined in
  `regex.ss`, partway through runtime bring-up, so everything loaded before it saw
  an un-normalized `error`. They now sit at the top of `rt.ss`, which every load
  path enters first.

## [0.5.9] - 2026-07-28

An interrupted git fetch no longer leaves a dependency unresolvable on every run
that follows.

### Fixed

- **An interrupted git fetch no longer poisons the dependency cache.**
  `ensure-git` created the cache directory with `mkdir -p` and then cloned into
  it, so the directory existed before the clone had produced anything. Interrupt
  the fetch (a `^C` while `jolt serve` resolves deps is enough, since the
  `SIGINT` reaches the child `git`) and the empty directory stayed behind: `git`
  cleans up a clone directory only when it created that directory itself. Every
  later run found the path and took it for a finished checkout, so the dependency
  contributed no source root and the run failed far from the cause, with `Could
  not locate ring_chez/adapter.jolt (or .clj/.cljc) on the source roots` for a
  dep deps.edn plainly declared. Deleting the directory by hand was the only way
  out. A fetch now clones, checks out, and updates submodules in a staging
  directory beside its destination, and moves it into place only once all three
  succeed, so the cache holds nothing but finished checkouts and a failure at any
  step removes the staging directory instead of leaving a trap. Completeness is
  recorded by a `.jolt-git-ok` marker, with `.git` accepted for a checkout an
  earlier jolt cloned in place, so an already-poisoned cache also heals itself on
  the next run.

## [0.5.8] - 2026-07-27

The AOT cache no longer serves stale code after a length-preserving source edit,
and the gate runs about 2.7x faster.

### Changed

- **The gate runs about 2.7x faster.** `make -j8 ci` drops from 338s to 124s.
  The build-driving gates (`buildsmoke`, `shakelocal`, `depssmoke`,
  `staticnativesmoke`, `buildlibsmoke`) shelled out to source-mode `bin/jolt`,
  where a `jolt build` costs ~12.5s against ~2.5s through a prebuilt binary, and
  `buildsmoke` alone drives 26 of them. They now take `testbin` and default
  `JOLT_BIN` to `target/release/jolt`, the way `smoke` and `cts` already did:
  those five together go from 713s to 161s. `buildsmoke` keeps one explicit
  `bin/jolt` build at the end so the source-mode driver stays gated, and
  `JOLT_BIN=bin/jolt` puts any of them back in script mode. `testbin` itself is
  now rebuilt only when something it bakes in is newer than the binary —
  unconditional rebuilds were free under `make -j ci` but charged every
  single-gate run 18s, enough to make `make buildlibsmoke` slower with the new
  prerequisite than without it.
- **`make gateboot` precompiles the gate boot preamble, taking a pass gate from
  ~1.5s to ~0.14s.** The two dozen gate scripts spent nearly all of their runtime
  loading the same six runtime files from Chez source. `make gateboot` compiles
  exactly that preamble to `target/dev/gate.so`, and the gates use it when it is
  present and newer than everything that went into it, falling back to the source
  loads otherwise. Opt-in and unreferenced by any other target, the way `devboot`
  is, so CI is unaffected unless someone builds it; the win is iterating on a
  single gate. It needs its own image rather than reusing `target/dev/flat.so`
  because that one also loads `loader.ss`, which the gates deliberately skip.
  `JOLT_GATEBOOT=1` reports which path was taken.
- **The runtime boot preamble lives in one file.** Eight gate scripts each
  carried their own copy of the same eight `load` lines; they now load
  `host/chez/gate-boot.ss`. `make-gateboot.ss` generates the image from
  `bld-runtime-manifest`'s prefix rather than a hand-written list, and
  `manifestcheck` pins `gate-boot.ss`'s literal fallback against that same
  prefix, so the runtime, the fallback, and the image cannot drift apart.

### Fixed

- **The AOT cache served stale code after a source edit that did not change the
  file's length.** The cache keys a namespace's compiled fasl on the source's
  byte length plus `equal-hash` of its content, on the assumption that a false
  share needs a collision in both. But Chez's `equal-hash` on a string is not a
  content hash: it samples about 26 characters no matter how long the string is
  (the first 6, roughly 15 strided, the last 5), so for any real source ~99% of
  the bytes never reached the key. Length was doing all the invalidation work,
  and any length-preserving edit — `42` to `99`, `<` to `>`, `inc` to `dec`, a
  rename to an equal-length name — produced a byte-identical key and quietly
  loaded the previous compile. Nothing else catches it: there is no mtime or
  size check behind the filename, so an existing `.so` is treated as valid.
  The cache now keys on a full-content FNV-1a hash, which reads every byte, at
  a cost of one linear pass over source that is about to be compiled anyway
  (6.4ms for all 3MB of runtime source, once per process). The length prefix
  stays on as a second factor.
- **Two jolt builds reporting the same version no longer share a cache
  generation.** The generation directory folds in a fingerprint of the runtime
  itself, precisely because `git describe` reports the same `…-dirty` for every
  build out of one working tree. That fingerprint used `equal-hash` too, so a
  length-preserving change to the runtime left both builds in one generation,
  each loading the other's fasls — the exact failure the fingerprint exists to
  prevent. Both the source-tree fingerprint and the one a binary bakes in now
  use the content hash.
- **`make aotfingerprint`** (added to `ci`) — pins that every byte of a source
  affects the hash, that the hash is reproducible across processes, and that a
  one-character length-preserving edit moves the namespace key, the source-tree
  fingerprint, and the fingerprint a built binary bakes. `aot-cache-smoke`'s
  existing invalidation case did this same `42`→`99` edit and passed throughout,
  because its 36-byte fixture put the change inside the sampled window; it now
  also drives a multi-kilobyte source with the value mid-file.

## [0.5.7] - 2026-07-27

A `.jolt` source extension, `-e` and `:main-opts` fixes across the CLI entry
points, and the arity gate that the 0.5.6 regression would not have survived.

### Added

- **`.jolt` is a source extension alongside `.clj` and `.cljc`.** A namespace can
  live in `foo.jolt`, and it is the same language: the reader, analyzer, and
  emitter never look at the extension. The point is to mark intent, so a reader
  can tell at a glance that a file uses jolt-specific interop and is not portable
  Clojure. It resolves first, ahead of `.clj` and `.cljc`, so a library can ship a
  portable `foo.cljc` next to a `foo.jolt` that wins on jolt, the way `.clj` wins
  over `.cljc` on the JVM. Everything a `.clj` works with works here: `require`,
  a bare `jolt foo.jolt` script argument, `clojure.core/load`, `data_readers.jolt`,
  the AOT cache, and `jolt build`.
- **`make oparity`** (added to `ci`) — every numeric fast-path op at every arity
  it admits, derived from `op-registry` rather than hand-listed, so a
  specialization added later is covered the moment it lands. Each case asserts
  that the specialized form compiles, that it agrees with the generic `apply`
  path, and that the emitted code actually contains the specialization — the last
  one being what the hand-written probes kept missing, since a case that silently
  fails to specialize otherwise passes for the wrong reason. Reverting 0.5.6's
  n-ary fold turns it red on the original symptom.

### Fixed

- **An alias's `:extra-paths` now precede the project's `:paths` on the source
  roots.** jolt appended them instead, which is the opposite of the clj CLI:
  `clojure -A:t -Spath` prints `test src`, jolt's `path` printed `src test`. The
  order decides which copy of a namespace loads, since the loader takes the first
  root that has it, so a `:extra-paths` directory that deliberately shadows one of
  the project's own files was silently ignored. `:extra-paths` also precede an
  alias's `:replace-paths`, and combine in alias-selection order, both matching
  clj. Dependency roots still come last.
- **`-e` composes with `-Sdeps`, `-A`, `-M`, and a project's `deps.edn`.** `-e` was
  handled entirely in the launcher, before `jolt.main` was loaded, so it never
  resolved a project and anything that re-dispatched into `jolt.main` first —
  `jolt -Sdeps '{...}' -e EXPR`, `jolt -A:test -e EXPR` — died with `unknown
  command or task: -e`. `jolt.main` now has its own `-e` arm that resolves the
  project (paths, deps, native libraries) and then evaluates through the same
  launcher primitive, so the two paths cannot drift. A bare `jolt -e EXPR` still
  takes the launcher's fast path when the project directory has no `deps.edn`
  (nothing to resolve, and it skips loading `jolt.main`); with a `deps.edn`
  present it resolves the project, so `jolt -e "(require 'my.app)"` now works
  from a project directory. The stdin forms (`-e -` and a bare `-`) follow the
  same rule.
- **`:main-opts` may be an `-e` expression.** `apply-main-opts` understood only
  `["-m" NS]`, so a `deps.edn` alias or task declaring `:main-opts ["-e" "..."]`
  failed with `unsupported :main-opts`.
- **`-M` takes main options from the command line.** `jolt -M -e EXPR` and `jolt
  -M -m NS` threw `alias(es) [] have no :main-opts`. The selected aliases'
  `:main-opts` now precede the ones given on the command line, matching the clj
  CLI, and when no alias declares any the command line supplies them on its own.
  Only an empty command line with no `:main-opts` is still an error.
- **`(unchecked-add x)`, `(unchecked-multiply x)` and `(unchecked-subtract x)` on
  a `^long` operand no longer crash.** They raised a runtime arity error against
  the two-operand primitive. jolt's own overlay has always taken one operand —
  `(apply unchecked-add [8])` is `8` and `unchecked-subtract` is `-8` — so the
  inline path contradicted the rest of jolt rather than only the JVM, which
  rejects these at one operand outright. Found by the new arity gate.
- **`op-registry` named a bigdec primitive that does not exist.** `"mod"` carried
  `:bd "jbd-mod"`, and nothing anywhere defines `jbd-mod`. It never reached
  emission, since only `quot`/`rem` are assigned the bigdec kind — but the `^long`
  set beside it does list `mod`, so making the two symmetric would have emitted an
  unbound identifier and broken every bigdec `mod` at load. It also reserved the
  name against user shadowing for nothing. Dropped; bigdec `mod` goes through the
  generic path, which was already correct and now has a corpus row.

## [0.5.6] - 2026-07-27

Fixes a 0.5.2 regression: long arithmetic with more than two operands did not
compile at all.

### Fixed

- **`+`, `-`, `*`, `min` and `max` take any number of long operands again.**
  `(+ (long a) (long b) (long c))` failed to compile with `invalid syntax
  (jolt-l+ ...)`. 0.5.2 moved `^long` arithmetic off Chez's variadic `fx+` onto
  jolt's own overflow-checking `jolt-l+`, which is binary, but the back end kept
  splicing every operand into one call, so the expander rejected the form. Any
  3-or-more-operand arithmetic over long-typed operands was affected — an integer
  literal counts as one, so `(+ (long a) (long b) 5)` was enough — while a single
  double operand hid it, the flonum ops being variadic. Under `*unchecked-math*`
  the same splice produced a runtime arity error instead of a compile error.
  N operands now lower as a left fold of the binary op, which is also the
  reference semantics: `(+ a b c)` is `(+ (+ a b) c)`, so each step is
  overflow-checked separately rather than the sum being checked once at the end.
- **`(+ x)`, `(* x)`, `(min x)` and `(max x)` compile over a long operand.** The
  other end of the same gap: a binary op has no one-operand form either, so these
  hit the same syntax error. They emit the operand, which is already coerced and
  needs no further check. `(- x)` and `(/ x)` are not identities and keep their
  call.

## [0.5.5] - 2026-07-27

Two diagnostic fixes: a stack frame now carries its own source location even when
another namespace defines the same function name, and `satisfies?` says what went
wrong instead of throwing an empty message.

### Fixed

- **A trace frame resolves to its own `ns/name (file:line)` when another namespace
  defines the same short name.** The host names a frame after the function's short
  name, so two namespaces defining one name collided in the source registry, which
  dropped the location rather than risk attributing the frame to the wrong file.
  The fallback was right but the collision was constant: every project defines
  `-main` and so does jolt, so the outermost frame of a typical trace never had a
  location. A function that registers a source map now gets a per-var frame name.
  Core keeps its short names — the seed and `jolt build` are unaffected.
- **`satisfies?` on something that is not a protocol names what it was given.** It
  threw with an empty message, so a caller had nothing to go on. Passing a host
  interface still throws, as it does on the JVM; the message now reads
  `satisfies? expects a protocol, got: java.lang.CharSequence`.

## [0.5.4] - 2026-07-26

Ten host-interop fixes, found by running a real library's test suite end to
end. The Cognitect test-runner works against jolt now; before this it reported
`Ran 0 tests` on any project.

### Fixed

- **A list built by `clojure.lang.PersistentList/create` answers `list?`.** It
  reported class `PersistentList` and satisfied `instance?
  clojure.lang.IPersistentList` but `list?` was false, because jolt marks the
  head cell of a real list and that constructor built unmarked cells.
  `clojure.tools.reader` reads every list through it and
  `clojure.tools.namespace`'s `ns-decl?` asks `list?`, so namespace discovery
  found nothing and the Cognitect test-runner ran no tests at all.
- **`clojure.test` deselects a test by its `:test` metadata.** `clojure.test`
  finds tests by scanning vars for that key, so tooling deselects one by
  removing it — the test-runner's `-v`/`-i`/`-e` do exactly that and restore it
  afterwards. `run-tests` ran straight from the registry `deftest` populates and
  never re-read the metadata, so all three options silently selected everything.
- **`.lookingAt` and `.matches` anchor at the region start.** Both anchor there
  on the JVM, not at the cursor `.find` advances, so a `.lookingAt` after a
  `.find` re-anchors at the beginning instead of resuming. A successful match
  now also moves the cursor past itself, so a following `.find` continues after
  it rather than re-finding what was just matched.
- **`unchecked-add-int` and its family wrap at 32 bits.** They were aliased to
  the long ops and wrapped at 64: `(unchecked-multiply-int 100000 100000)` gave
  `10000000000` instead of `1410065408`. Any 32-bit hash mixing was silently
  wrong.
- **`(str x)` uses a deftype's declared `toString`.** It is `x.toString()` on the
  JVM; jolt printed the field map instead. `pr-str` is unchanged, which is the
  same split the JVM makes.
- **The regex functions take a `CharSequence`, not only a `String`.** A library
  matching over a window of a larger string passes its own implementation;
  jolt now realizes one through the type's `toString`.
- **`slurp` of a missing path throws `java.io.FileNotFoundException`.** It threw
  a raw host condition, so a caller catching that class never saw it — a common
  way to test whether an argument is a path or content.

### Added

- **`clojure.core.protocols`**, with the `CollReduce`, `InternalReduce`,
  `IKVReduce`, `Datafiable` and `Navigable` protocols, for libraries that extend
  them to their own types.
- **`clojure.lang.LispReader$StringReader`**, which libraries instantiate to read
  a string literal with Clojure's own escape rules; the literal is parsed by the
  same code jolt's reader uses, so the escapes agree.
- **`java.util.regex.Matcher.lookingAt`** and **`Pattern.flags`**.

## [0.5.3] - 2026-07-26

Stack traces from `jolt run` name their frames the way an AOT build's do.

### Fixed

- **A trace off the runtime path shows `ns/name (file:line)`, not a bare frame
  name.** The renderer could already print the mapped form; nothing populated the
  source map outside an AOT or `JOLT_TRACE` build, so an uncaught error under
  `jolt run` listed bare Chez procedure names with no namespace and no location.
  A fn def now registers its source on the runtime eval path too — one hashtable
  insert per def at definition time, no per-call cost. The tail-frame history
  that recovers TCO-erased frames still costs a push per call and stays opt-in
  behind `JOLT_TRACE`. A frame whose short name is shared across namespaces
  (every project's `-main` and jolt's own, say) keeps printing bare rather than
  risk attributing it to the wrong source.
- **A `def` evaluates to its var when a source registration follows it.** The
  registration was spliced as the last form of a `begin`, so the `def` took its
  `nil` as the form's value and `(pr-str (defn f [] 1))` gave `nil` instead of
  `#'user/f`. Latent since the tail-frame history landed — it only reached code
  compiled with `JOLT_TRACE` set, which the corpus gate never exercised.

## [0.5.2] - 2026-07-26

Compiler-flag and `^long` arithmetic fixes that let clojure/test.check load,
a dropped-argument bug in optimized builds of multi-collection `map`, and three
correctness fixes in the per-namespace compile cache.

### Fixed

- **`map`, `mapv` and `mapcat` over more than one collection work in an
  optimized build.** The inference pass rebuilt such a call as the function plus
  a single collection, so `(map f c1 c2)` compiled to `(map f c1)` and the
  two-argument function was then applied to one element. The runtime compile
  path does not run that pass, so the same source worked under `jolt run` and
  failed only once built. Sibling patterns for `get` and `reduce` truncated an
  over-arity call the same way instead of leaving it for the runtime to report.
- **The compile cache distinguishes the runtime that filled it.** Cached
  namespaces were keyed on the jolt version, which does not identify a build:
  `git describe` reports the same `…-dirty` for every edit in a working tree, so
  successive builds out of one checkout shared a key and each loaded the
  previous runtime's compiled output. Application binaries carry no version at
  all and so shared one key across unrelated programs. Each build now carries a
  fingerprint of its own runtime, and a runtime that cannot be identified does
  not use the cache.
- **Editing a namespace invalidates the ones that depend on it.** A cached
  namespace was keyed on its own source alone, but what it compiled to also
  depends on what its dependencies contributed — macro expansions above all — so
  editing a macro left every consumer running expansions of a definition that no
  longer existed. The key now folds in the key of each namespace required, which
  makes it transitive: a change three namespaces down invalidates the whole
  path.
- **The dev boot cache no longer halves the speed of the code it runs.** The
  image `make devboot` builds loads the build subsystem eagerly, and that turns
  per-site var-cell caching off so the seed mint and `jolt build` stay
  byte-deterministic. Since the image saved that setting, every namespace
  compiled at runtime under the cache resolved each var by name on every access
  — about half speed on var-reference-heavy code, in a cache whose purpose is
  faster iteration. It restores the runtime setting after loading the build
  driver. Released binaries were never affected; they load that subsystem
  lazily.
- **A file's top-level `(set! *unchecked-math* true)` works.** It threw "Can't
  change/establish root binding"; the reference binds the var around every file
  load, so the form is legal and its effect ends with the file. The loader bound
  `*warn-on-reflection*` and `*assert*` but not this one, and the AOT path lost the
  effect separately — an optimized build decides whether `+`/`-`/`*` lower to their
  wrapping forms while it emits, which happens before the boot-time `set!` runs, so
  the flag is now applied as emission walks past it. clojure/test.check sets the
  flag at the top of `random.clj` and so could not be loaded at all.
- **`^long` arithmetic covers all 64 bits.** `+`, `-`, `*`, `inc` and `dec` on
  `^long` values raised once a value passed the Chez fixnum boundary at 2^60 —
  `(- x 1)` on an ordinary long threw instead of computing. They now compute
  generically and throw `ArithmeticException` at the 2^63 edge the hint actually
  promises, matching the reference on both the value and the message. The other
  long ops already did this; `+ - *` were left on the raw fixnum ops on the
  assumption that `*unchecked-math*` rewrote them first, which only holds when the
  flag is on.

### Changed

- **Superseded compile-cache generations are collected.** Keying on the runtime
  means the cache moves whenever jolt is rebuilt, so a build loop would leave a
  full generation behind each time. A run now keeps the three most recently used
  and drops the rest. `JOLT_CACHE_DIR` still selects the location, and
  `JOLT_AOT_CACHE=0` still opts out.

## [0.5.1] - 2026-07-26

Optimized builds type recursive walks over record trees, and a
devirtualization bug that could return a wrong value is fixed.

### Fixed

- **A protocol call on a record-or-nil receiver no longer devirtualizes.** In an
  optimized closed-world build the inference took the devirtualization target
  straight off the receiver's type without checking whether it could be nil, and
  because such a site caches its first resolution, a receiver that was a record
  on one call and `nil` on the next got the cached implementation instead of a
  dispatch. With a record that has no fields that returned a wrong value where
  Clojure raises `IllegalArgumentException`; with fields it surfaced as an
  untyped host error. Only a receiver proven non-nil devirtualizes now — a
  `some?`/`nil?` guard narrows one back, so the fast path is kept wherever it is
  sound.

### Changed

- **Recursive walks over record trees are typed and read fields by slot.** The
  whole-program pass could not follow a record through a nilable recursive
  position, so a tree walker's parameter stayed untyped and every field read
  went through the generic keyword lookup. Four things blocked it: a `defn`'s
  self-recursive call resolves through the function's own name rather than its
  var and so never picked up the function's inferred return type (which meant a
  recursive constructor poisoned its own record's field types); the parameter
  fixpoint had no priming phase, so a recursion whose argument is computed from
  the parameter pinned it at the top type; joining two views of the same record
  widened any field only one side carried; and a field read off a record-or-nil
  discarded the field's type entirely. `binary-trees` runs 2.5× faster
  (165ms→67ms, about 1.8× JVM Clojure). The first two apply to any
  self-recursive `defn` in an optimized build.

## [0.5.0] - 2026-07-25

The CLI is `jolt` now, not `joltc` — a rename worth a minor version even
though `bin/joltc` still works as a shim. Alongside it: `deps.edn` handling
that follows tools.deps rather than approximating it, Linux binaries that run
on distributions back to CentOS 7, and another round of numeric performance
work.

### Added

- **Dependency resolution matches tools.deps.** The expansion engine is now the
  one from `clojure.tools.deps` — version map, exclusion tree, and orphan
  cutting ported directly — so `:exclusions` are honored, a library pulled at
  two versions resolves to the newest (a top-level coordinate still pins), and
  children orphaned by that choice are dropped. Maven versions order by
  ComparableVersion semantics without a JVM; git coordinates compare by commit
  ancestry. New coordinate handling: `:local/root` may point at a `.jar` (it is
  extracted and its pom supplies transitive deps), and `:git/tag` with a short
  `:git/sha` resolves the tag to its commit and verifies the prefix. Custom
  `:mvn/repos` are consulted after Clojars and Central.
- **The deps.edn chain and the tools.deps CLI surface.** A user `deps.edn`
  ($CLJ_CONFIG, else $XDG_CONFIG_HOME/clojure, else ~/.clojure) merges under
  the project's; `-Sdeps '<edn>'` merges an extra map last; `JOLT_NO_USER_DEPS`
  opts out of the user file. `-X:alias [ns/fn] [k v …]` invokes `:exec-fn` with
  `:exec-args` (k v pairs and a trailing map merge over it, `:ns-default` /
  `:ns-aliases` qualify the symbol), and `-T:alias` does the same with the
  project's own paths and deps replaced by the tool's. Libraries declaring
  `:deps/prep-lib` are named in a warning, since jolt runs no prep step.
- **deps.edn aliases follow tools.deps semantics** (#453). Alias maps combine
  with the reference merge rules — lifted directly from
  `clojure.tools.deps.edn` into `jolt.deps.edn` — and the full args-map key set
  applies: `:extra-deps`, `:override-deps`, `:default-deps`, `:replace-deps`
  (legacy `:deps`), `:extra-paths`, `:replace-paths` (legacy `:paths`), and
  last-wins `:main-opts`. A leading `-A:…` now carries its aliases into the
  dispatched command, so `jolt -A:jolt path`, `-A:x -M:y`, and `-A:… build`
  all resolve with them. An undeclared alias is an error, as in tools.deps.
- **The jolt-lang/time library autoloads from the source roots.** Referencing a
  `java.time` formatting/zone class (`ZoneId`, `ZonedDateTime`,
  `DateTimeFormatter`, …) with the library on the deps loads its `jolt.time`
  install namespace automatically — `(require '[tick.core :as t])` works
  directly in a project that declares the dependency, e.g. via a `:jolt` alias.

### Changed

- **The CLI is named `jolt` now, not `joltc`.** The dev launcher is `bin/jolt`,
  the built binary is `target/<profile>/jolt` (`jolt.exe` on Windows), release
  archives are `jolt-<version>-<target>.tar.gz` containing a `jolt` binary, and
  the Makefile targets are `jolt` / `jolt-release` / `jolt-debug` / `joltsmoke`.
  `bin/joltc` remains as a compatibility shim that execs `bin/jolt`. The
  `install` script installs `jolt` and falls back to the `joltc`-named assets
  for releases up to 0.4.15; the Homebrew formula switches to the new name
  automatically on the next release bump. The cross-compile variable
  `JOLTC_TARGET` is now `JOLT_CROSS_TARGET`.
- **Linux release binaries run on much older systems** (#455, fixes #452). The
  Linux build now happens inside manylinux2014 with ncurses/tinfo/zlib linked
  statically, dropping the glibc requirement from 2.35 to 2.17 — so the
  published binary runs on CentOS 7+, Ubuntu 14.04+, Debian 8+, and Amazon
  Linux 2+ instead of demanding a 2023-or-newer distribution.
- **Out-of-range `aget`/`aset` on a primitive array throws
  `ArrayIndexOutOfBoundsException`** with the JVM's message (#458). It
  previously surfaced as an untyped host condition that `(class e)` reported as
  `:object` and that a `catch` of an unrelated exception class could swallow.

### Performance

- **Mixed `long`/`double` arithmetic no longer falls off the fast path** (#454).
  An integer operand in an otherwise-flonum expression now coerces instead of
  forcing generic dispatch, and integer-literal loop counters take JVM `long`
  semantics. `mathfns` went from ~22.7× the JVM to ~1.5×, `loop-recur` from
  ~8.3× to ~1.6×, `mandelbrot` to ~1.6×.
- **Primitive `double` array access is roughly 3× faster** (#457, #461). The
  index takes a fixnum-first path, and — where the pass has proven the array
  and index types — the backend now emits the flvector read/write inline
  instead of calling a wrapper whose flonum return had to be re-boxed on every
  element. The `arrays` benchmark went from ~18.6× the JVM to ~6×.
- **Generic `inc`/`dec` open-code their numeric fast path** (#458) rather than
  calling through a procedure, matching how `+`/`-`/`*` already worked.

## [0.4.15] - 2026-07-22

Two numeric fast paths for hot array and math code, both hint- and
inference-driven.

### Changed

- **Primitive `double`/`float` arrays are unboxed.** A double/float `jolt-array`
  is now backed by a Chez flvector (unboxed flonums) rather than a boxed vector;
  the collection dispatchers (`count`/`seq`/`nth`/`ref-put!`/`aclone`) and
  `java.util.Arrays` go through backing-agnostic helpers, so behavior is
  unchanged. A `^doubles`/`^floats` array hint — on a param **or** a `let`-binding
  — lets `(aget a i)` lower to a direct `flvector-ref` typed `:double` and
  `(aset a i v)` to a direct `flvector-set!`, so a read/fill loop over a primitive
  array stays unboxed on both ends and the surrounding arithmetic unboxes to
  `fl+`/`fl*` instead of the generic `jolt-nth` + numeric-tower path.
- **`java.lang.Math` over proven flonum operands lowers to the native op.** When
  every operand is a `:double` (or an int literal coerced to one, with at least
  one genuine double), a Math call emits the native Chez flonum op
  (`flsqrt`/`flatan`/`flexpt`/…) typed `:double`, so it keeps flonum contagion in
  the enclosing expression. Untyped args and all-integer forms like `(Math/abs 5)`
  stay the generic host-static call.
- **Hot 1-dim `aget`/`aset`/`alength` lower to the array-aware native ops**
  (`jolt-nth`/`jolt-aset3`/`jolt-count`), skipping the clojure.core overlay's
  var-deref + reduce/seq alloc. Multi-dim forms fall back to the overlay.

## [0.4.14] - 2026-07-21

### Fixed

- A GUI app started from an nREPL session no longer aborts on macOS with "API
  misuse: setting the main menu on a non-main thread." The nREPL server parks in
  `park-until-interrupt` (for clean `^C` shutdown), which did not activate the
  main-thread pump, so `jolt.host/call-on-main-thread` fell through and ran
  `g_application_run` inline on the nREPL worker thread — GTK quartz aborted when
  it set the main menu off the main thread. `park-until-interrupt` now doubles as
  the pump: it drains queued jobs and runs each on the primordial thread, idling
  via an interrupt-checked `sleep` poll so `^C` is still delivered and the shutdown
  hooks still run.

### Added

- **`jolt.host/call-on-main-thread-async`** — a fire-and-forget hop onto the main
  thread, so a GUI framework's `run` can schedule the boot and return immediately,
  leaving the nREPL session live for reactive edits. The blocking
  `call-on-main-thread` and the external `run-main-pump` pump API are unchanged.

## [0.4.13] - 2026-07-21

### Changed

- Closed the reader-side half of the lazy-realization race. The tail force
  (`seq-more`) and lazy-node force (`force-lazyseq`) kept an unlocked fast-path
  read of the realized flag and value as their first case, taken even in
  multi-threaded programs. Because the writer stores the value and the flag with no
  barrier between them, on a weak memory model like ARM64 a lock-free reader could
  observe the flag set while the value was still the thunk, the same leaked-closure
  crash the earlier writer-side fix described. Once a second thread exists, every
  access now goes through the per-node and per-cell mutex, reads included, so the
  reader synchronizes against the writer's release. Single-threaded programs keep
  the fully lock-free fast path. Host-runtime change only; the minted seed is
  unaffected.

- Fixed a latent concurrency bug in lazy sequence realization. A `cseq` seq cell
  memoizes its tail under mutable `tail`/`forced?` fields with no synchronization,
  so once a lazy-seq node was realized its underlying cell chain was shared across
  threads (every future/agent walking the same seq reads the *same* cells) and two
  threads could both force a cell's tail and publish the fields non-atomically — a
  third reader could then observe `forced?` set with `tail` still the thunk,
  leaking a closure out as a seq and crashing. The cell's tail force (`seq-more`)
  is now guarded by a lazily-created per-cell mutex under the same `jolt-mt?` flag
  the lazy-seq node uses, so it stays lock-free in single-threaded programs and
  takes double-checked locking once a second thread is spawned. This was exposed
  by the new concurrent-realization unit guard and is otherwise unchanged in
  behavior; the minted seed is unaffected (host-runtime change only).

- Lazy sequences are noticeably faster in single-threaded programs, which is the
  common case. Every lazy-seq node used to allocate an OS mutex when it was created
  and acquire it on first realization, so that concurrent futures or agents could
  not run the body twice. But iterate, repeat, cycle, and every map/filter chunk
  tail is a lazy node, so idiomatic pipelines paid a mutex allocation and lock per
  node, and per element for iterate. A node now carries no mutex and realization
  takes no lock until the process actually spawns a second thread. A global flag
  flips the first time `fork-thread` runs (via future, agent, core.async, or a
  subprocess), after which realization falls back to the original double-checked
  locking on a mutex created lazily per node. This is race-free because a single
  thread is either forking or forcing, never both, and `fork-thread` establishes
  happens-before so the spawned child sees the flag. The lazy-seq/HOF benchmark
  (`bench/seqs.clj`) drops about 26% (roughly 1200ms to 890ms on an M-series
  machine); tight-loop and persistent-collection benchmarks are unchanged.
- `every?`, `some`, and the `not-every?`/`not-any?` derived from them are faster
  over chunked collections. They walked a sequence cell by cell with
  `seq`/`first`/`next`, which re-coerces to a seq and allocates a step cell per
  element and threw away the tight index loop a chunked source like `range` or a
  vector already supports. They are now expressed over `reduce` and `reduced`, so a
  chunked source drives `reduce`'s index loop while a lazy seq is still stepped one
  cell at a time, and `reduced` preserves the short-circuit and laziness (an
  infinite seq with an early counterexample still terminates). A scan-heavy probe
  (`every?` over many small ranges) drops about 30%. The `bench/seqs.clj` aggregate
  is unchanged because its `every?` component is a small slice of the total; the win
  shows up in code that leans on these predicates. `every?` lives in the kernel tier
  so it is expressed with `fn*`, and both functions are part of the minted seed.
- Chunked `map` and `filter` allocate less per chunk. Both realized a chunk by
  copying the source vector's 32-element trie leaf into an intermediate pvec and
  then re-reading that copy to build the output, and `filter` additionally built a
  Scheme list, reversed it, and converted it to a vector. They now read the source
  leaf directly into the output chunk, skipping the intermediate copy (and, for
  `filter`, the list round trip). The leaf resolution is identical to the previous
  code, so chunk boundaries and the rare non-leaf-aligned window behave exactly as
  before. On its own this is in the noise on `bench/seqs.clj` because the per-chunk
  lazy-seq node cost dominated; stacked with the lazy-seq mutex change it accounts
  for roughly another 4% (about 30ms) on that benchmark.
- Transducers are faster and no longer slower than the equivalent lazy pipeline.
  Each transducer stage's reducing fn was a variadic `(lambda a (case (length a)
  …))`, so calling it with two arguments allocated a rest list and walked
  `(length a)` on every element, then forwarded through the general variadic
  invoke. Each stage is now a `case-lambda` with the exact transducer arities
  (init, complete, step), so there is no rest list and no length check, and the
  step calls the downstream reducing fn and the mapping/predicate fn through the
  fixed-arity fast paths. The map transducer keeps a trailing variadic clause for
  its multi-input arity, so the single-input hot path stays allocation-free. On a
  2,000,000-element pipeline `transduce` drops about 23% and `into` with an xform
  about 22%; a transducer pipeline is now faster than the lazy-seq equivalent, as
  it should be, where before it was slower.
- The `jolt build` subsystem no longer runs at every startup. Following #433,
  `build.ss` (with the `emit-image.ss` and `dce.ss` it inlines) was still emitted
  as eager top-level forms in the boot image, so its ~100 defines ran on every
  process start, and the runtime `.ss` source it reads during a build was
  registered into the resource table each start — about 20ms on every invocation,
  none of it touched by `run`, `-e`, `repl`, `version`, or any non-build command.
  The fully-inlined build subsystem is now baked as a source string and `eval`ed
  into the top-level environment on the first `jolt build`, with the `.ss` embed
  registration moved into a thunk fired at the same point. Non-build invocations
  pay nothing.
- Iterating a record's keyword map is about 1.8x faster. The persistent array
  map's order list now carries `(key . value)` pairs instead of bare keys, so the
  `pmap-fold` / `pmap-fold-fwd` iteration scans entries directly instead of doing
  one HAMT lookup per key — the hot path for folding the 64-entry keyword maps
  defrecord ext maps produce (a full `vals` fold drops from ~5.9us to ~3.2us). A
  new `order-replace` updates a replaced key's value in place so `assoc` on an
  existing key keeps both its position and value; no behavioral change.

## [0.4.12] - 2026-07-21

### Changed

- joltc startup is about 4x faster. The CLI entry namespaces (`jolt.main`,
  `jolt.deps`, and their on-demand Clojure closure) were baked into the binary as
  `(load-namespace …)` boot forms, which re-analyzed and re-emitted them from
  Clojure source on every process start because a Chez boot file re-runs its
  top-level forms each `Sbuild_heap`. That was roughly 380ms, about 70% of the
  startup floor, paid by every invocation. They are now emitted to Scheme at build
  time via the same path an app build uses and marked loaded, so at boot the vars
  are installed by running compiled code like the rest of the runtime image. A
  trivial `joltc prog.clj` drops from ~0.51s to ~0.12s. This is the base floor the
  per-namespace AOT cache (0.4.10) could not touch, since install-owned namespaces
  are never cached.
- joltc startup drops a further ~15% (~130ms to ~110ms on an M-series machine).
  The build subsystem (`build.ss` plus the `emit-image.ss`/`dce.ss` it inlines) and
  the runtime `.ss` source embeds it reads are used only by `jolt build`, but they
  ran their defines and registered their bytes at every startup. They are now baked
  as source and loaded lazily on the first `jolt build`, so `run`, `-e`, and every
  other command skip them. No behavior change to `jolt build`; the standalone binary
  is also slightly smaller.

## [0.4.11] - 2026-07-20

A base java.time API in core that works with no dependency, as a single
implementation rather than two (RFC 0008). Core previously registered a partial
java.time surface in Scheme (Instant, LocalDateTime, ZoneId, DateTimeFormatter,
FormatStyle) that was both incomplete — `Instant/now` worked, `LocalDate/now` did
not — and a second copy of logic the jolt-lang/time library already implements in
Clojure. The Scheme shim is gone; the boundary now sits at the java.time value
types.

### Added

- **java.time value types in core, no dependency.** Instant, LocalDate /
  LocalTime / LocalDateTime, Duration, Period, Year / YearMonth / MonthDay, and
  the Month / DayOfWeek / ChronoUnit / ChronoField enums live in core under
  `stdlib/jolt/time` as portable Clojure, aggregated by a core-owned
  `jolt.time.base` that autoloads the first time interop resolves one of them. A
  date-free program never triggers the load, so it pays nothing.

### Changed

- **Formatting and zones are the jolt-lang/time library, as the single
  implementation.** DateTimeFormatter, FormatStyle, ZoneOffset, ZoneId,
  ZonedDateTime / OffsetDateTime, localized formatting, and java.util.Locale are
  the library — core carries no second copy. Referencing one of those without the
  library now gives an error that names the dependency instead of a bare "Unknown
  class", on both the static and constructor paths.
- **`.toInstant` bridges through the base.** `inst-time.ss` keeps the
  always-available java.util / java.text layer (Date, sql.Date/Timestamp,
  Calendar, TimeZone, SimpleDateFormat) and the `#inst` literal; its `.toInstant`
  routes a Date, `#inst`, or FileTime to the base Instant, autoloading the base so
  the bridge needs no dependency. `now()` fixes on UTC in the base; the library
  refines it to the system zone.

### Removed

- **The Scheme java.time shim.** The partial Instant/LocalDateTime/ZoneId/
  DateTimeFormatter/FormatStyle surface previously implemented in Scheme is
  removed in favor of the Clojure base.

## [0.4.10] - 2026-07-20

Per-namespace AOT/compile cache for required libraries: a disk-backed cache that
fasls a required namespace's emitted Scheme on first load and loads the `.so` on
subsequent runs, recovering most of the per-run recompile cost for library
requires. Keyed by source content hash + jolt version, so any source edit or
compiler change misses automatically. Default ON for a built `joltc`; the dev
`bin/joltc` opts out (volatile dev compiler). Measured ~28% startup speedup on a
4-library require (cold 2.81s → warm 2.03s).

### Added

- **Per-namespace compile cache.** When a disk-backed namespace is required, the
  emitted Scheme is teed off the existing load path (preserving the interleaved
  analyze→eval semantics — forward macro refs, `defrecord`/`defprotocol`, data
  readers, and transitive requires all reproduce on cache hit) and fasled to
  `~/.jolt/aot-cache/<jolt-version>/v1/<ns>-<content-hash>.so`. The cache filename
  embeds a content hash of the source, so editing a namespace invalidates it
  automatically (no mtime tracking). On the next run the `.so` is loaded directly
  instead of recompiled.
- **`JOLT_AOT_CACHE` env var** — `0`/`false`/`no`/`off` opt out. Default ON for a
  built `joltc`; the dev `bin/joltc` script sets it to `0` (a volatile dev compiler
  whose "dev" version tag wouldn't invalidate across edits, and whose startup is
  already covered by the devboot cache).
- **`JOLT_CACHE_DIR` env var** — override the cache root (default
  `~/.jolt/aot-cache`). Useful for tests and CI isolation.
- **Safety gates.** Install-owned namespaces (embedded in the binary) are never
  cached; `:reload` / `:reload-all` bypass the cache so live editing always wins.
- **`make aotcachesmoke`** (added to `ci`) — deterministic correctness gate:
  miss/hit/invalidate, macro def-then-use, `defrecord`, data readers, transitive
  require, `:reload` bypass, install-owned never cached.
- **`make aotcacheperf`** — cold-vs-warm wall-clock measurement (needs Maven jars
  locally; not in the default gate).
- **Git deps can omit `:git/url`.** A git coordinate whose lib name encodes a
  known host resolves its clone URL the way tools.deps does — `io.github.OWNER/REPO`
  clones from GitHub, and likewise for `com.github.*`, `io.gitlab.*`/`com.gitlab.*`,
  `io.bitbucket.*`/`org.bitbucket.*`, and `ht.sr.*` (Sourcehut). An explicit
  `:git/url` still wins; a git coordinate with neither a URL nor an inferable host
  now reports an actionable error naming the fix instead of being silently skipped.

## [0.4.9] - 2026-07-20

Better compile diagnostics, borrowing a few ideas from Carp: near-miss name
suggestions, machine-readable error output, and an opt-in success-type lint.

### Added

- **"Did you mean?" suggestions for an unresolved symbol.** When a bare symbol
  doesn't resolve at the top level, the compile error now lists the closest
  in-scope names by edit distance, drawn from the current namespace's vars,
  `clojure.core`'s publics, and the lexical locals. `(prinltn 1)` reports
  `Unable to resolve symbol: prinltn in this context (did you mean print, printf,
  println?)`. A symbol with no near match still gets the bare message.
- **Machine-readable diagnostics (`JOLT_DIAG=edn`).** With `JOLT_DIAG=edn`, an
  uncaught error is emitted as a single line of valid EDN to stderr instead of
  the human report, so an editor or tool can read it back. The map carries the
  human `:message` and the source `:line`/`:column`/`:file`; an unresolved-symbol
  error also carries structured `:type`/`:symbol`/`:suggestions`/`:ns`. The
  underlying analyzer error now attaches that data as ex-data on the thrown
  `ex-info`, so it is available programmatically even in the default human mode.
- **Opt-in success-type lint (`JOLT_CHECK`).** With `JOLT_CHECK` set to a truthy
  value, each runtime-compiled top-level form is run through the existing
  success-type checker (RFC 0006) and any findings print to stderr as located
  warnings, e.g. `1:10: warning: \`+\` requires a number, but argument 2 is a
  keyword`. Off by default (zero cost, no behavior change); a checker error never
  breaks a compile. Only runtime-compiled code is linted — `clojure.core` and the
  prelude are baked into the seed at build time and are not re-checked.

## [0.4.8] - 2026-07-20

Dependency downloads no longer shell out to `curl` — jolt fetches Maven jars over
its own cert-verifying HTTPS.

### Changed

- Maven dependencies download over HTTPS through jolt itself instead of shelling
  out to `curl`. A new `jolt.mvn-http` does a minimal cert-verifying HTTPS GET
  (a raw socket via `jolt.ffi`, TLS over the system OpenSSL with peer verification
  + SNI + hostname check), so a dependency jar is never fetched over an
  unauthenticated transport. It loads the real OpenSSL lazily — on macOS the
  Homebrew `openssl@3` (the protected `/usr/lib` copy can't be loaded); on Linux
  the distro `libssl`/`libcrypto`; on Windows the `libssl-3-x64.dll` DLLs via
  Winsock (the Windows path is implemented but not yet validated on a Windows
  host). A repo that can't be reached is skipped, non-fatal. `git` (git deps) and
  `unzip` (jar extraction) are still shelled out; `curl` is gone.

## [0.4.7] - 2026-07-19

Library conformance (flatland/ordered; babashka.http-client via jolt-lang/http-client),
a proxy-over-interface fix, Maven cache invalidation, and quieter default output.

### Added

- **`pr`/`pr-str` honor a user `(defmethod print-method SomeType …)`** for a
  deftype/defrecord, rendering through it into a `StringWriter` instead of the
  default `#ns.Name{…}` form. An unqualified `(defmethod print-method …)` in a
  library loaded via `require` now extends `clojure.core/print-method` (implicit
  `refer-clojure`) instead of building a dead per-namespace shadow.
- **Java collection interop on native collections.** `.cons`/`.assoc`/`.without`/
  `.assocN`/`.disjoin`/`.pop`/`.asTransient`/`.hashCode` and the transient
  `.conj`/`.persistent`/… now dispatch on a vector/map/set (and its transient), so
  a deftype built on the `clojure.lang.*` interfaces (flatland/ordered) works.
  `conj`/`contains?`/`disj`/`get`/`transient`/`persistent!`/`hash` route to a
  deftype's own `cons`/`containsKey`/`disjoin`/`get`/`asTransient`/`persistent`/
  `hasheq` methods. `instance?` on a deftype now walks its declared interfaces'
  ancestry (a `IPersistentMap` is a `Counted`/`Associative`/`IPersistentCollection`).
- A collection's `.hashCode` is now the `java.util.Map`/`Set`/`List` hashCode
  (previously the Murmur3 hasheq), so a jolt collection hashes equal to a library
  type computing the Java hashCode. `clojure.lang.APersistentMap/mapHash` is shimmed.

### Changed

- Progress/informational output is quiet by default; set `JOLT_DEBUG` to surface
  it. `jolt.deps` no longer prints its fetching / using-cache / skipping /
  added-natives lines on a routine run (a program pulling a native-declaring
  library used to barf a `[jolt.deps] … not auto-loaded` line every time), and the
  "static member registered twice" drift warning — which also fires when two
  libraries legitimately shim the same class — is likewise gated. Genuine
  problems (an unresolvable dependency, a failed extraction, a malformed
  `deps.edn`) still print unconditionally. `JOLT_DEBUG` is the knob to re-enable
  the diagnostics when debugging dependency resolution or static-shim drift.

### Fixed

- `(proxy [SomeInterface] [] (method [args] body))` now works — it desugars to a
  `reify` over the same interfaces (`this` is bound in the method body), instead of
  throwing "proxy is unsupported". Only `(proxy [ThreadLocal] …)` keeps its
  dedicated form. This unbreaks clj-http-lite (its trust-all `HostnameVerifier`)
  and any library that proxies an interface. `proxy-super` / calling an inherited
  concrete superclass method is still unsupported (jolt has no superclass).
- A bare imported deftype/defrecord class name resolves to its class value, equal
  to `(type instance)` — `(= SomeType (type inst))` holds, and a flat
  `(:import a.b.Type)` binds the name.
- Maven jar extraction re-extracts when the jar is newer than the last extraction
  (`.jolt-ok` was trusted forever, so a rebuilt/refetched jar — a SNAPSHOT, or a
  coord reinstalled into `~/.m2` — was never re-read), and the `.jolt-ok` marker
  is written only after a successful `unzip`, so a failed/partial extraction is no
  longer cached as complete.

## [0.4.6] - 2026-07-19

Cross-compilation, and a stdin namespace-switch fix.

### Added

- **`jolt build --target <machine> --target-pack <dir>`** cross-compiles an app
  for another Chez machine, and `build-joltc.ss` cross-builds joltc itself — which
  restores the x86_64-macos release artifact (cross-built on the arm64 runner).
  `build.ss` already split at the machine boundary (steps 1-3 emit machine-neutral
  `flat.ss`); a cross build retargets only step 4 under the target pack's Chez
  `xpatch` and links the target kernel with the target cc. A "target pack"
  (assembled by `tools/cross-compile/make-pack.sh` from a ChezScheme cross
  checkout) supplies the boots/kernel/`scheme.h` + xpatch + link-libs + static
  lz4/zlib. `--library` and `:jolt/native` cross builds are not supported yet.

### Fixed

- **`jolt -` / `-e` honor an `(ns …)` switch.** Stdin and `-e` compiled every
  top-level form in a hardcoded `user` namespace, so an `(ns …)` form's switch was
  ignored — a later `(refer …)`/`def` into the switched-to namespace wasn't visible
  to a following form's analysis. They now compile each form in the current
  namespace, re-read per form, like loading a file. Fixes
  `ys -T jolt prog.ys | jolt -` (a compiled YAMLScript program switches ns then
  refers its stdlib in). Process substitution `jolt <(ys …)` already worked.

## [0.4.5] - 2026-07-19

Sub-process working-directory fixes: a spawned child now runs in the user's cwd,
and an unresolvable program fails like the JVM.

### Fixed

- **Spawned children inherit the user's cwd.** A child process ran in jolt's OS
  cwd — the repo root its launcher `cd`s to — instead of the user's cwd. A JVM
  child inherits `user.dir`; jolt preserves the user's cwd in `JOLT_PWD`, so a
  child now defaults to `JOLT_PWD` and a relative `:dir` resolves against it (like
  `ProcessBuilder.directory`). Before, `(sh ["ls"])` listed the jolt repo.
- **`System/getProperty "user.dir"` is the user's cwd.** It returned `PWD` (the
  repo root after the launcher's `cd`); it now prefers `JOLT_PWD`, so `user.dir`
  and spawned-child cwds agree.
- **Missing program throws like the JVM.** `ProcessBuilder.start` resolves the
  program before spawning and throws `IOException("…No such file or directory")`
  when it can't be found (absolute / slash-relative file must exist; a bare name
  must be on `PATH`), instead of letting the shell fail at `exec`.

## [0.4.4] - 2026-07-19

Sub-process support: `jolt.process` (vendored babashka.process) runs over a new
host `ProcessBuilder` / `Process` layer, with `clojure.java.shell` alongside it.
Also a build-scanner fix so `joltc build` no longer chokes on `::alias/kw`
keywords.

### Added

- **`jolt.process` — sub-process spawning.** `jolt.process` is now the
  [babashka.process](https://github.com/babashka/process) API. Jolt vendors
  babashka.process over a new `java.lang.ProcessBuilder` / `java.lang.Process`
  host shim (`host/chez/java/process.ss`) built on Chez `open-process-ports` for
  stdin/stdout/stderr pipes plus the pid, and libc `waitpid` / `kill` (via FFI)
  for exit codes, liveness and signals. `process`, `sh`, `shell`, the `$` macro,
  `check`, `pipeline`, `destroy`/`alive?` and stream/file/inherit redirects all
  work; `:dir`, `:env`/`:extra-env`, and stdin feeding are supported. `exec`
  (GraalVM-only) is not re-exported. `jolt.process` is the curated public surface
  (require `babashka.process` directly if you prefer).
- **`clojure.java.shell`.** The standard `clojure.java.shell/sh` (and
  `with-sh-dir` / `with-sh-env`) now run, over a new `Runtime.exec` host method
  and the ProcessBuilder shim.
- **Shim class identity is registry-derived.** The new `ProcessBuilder` /
  `Process` / `ProcessBuilder$Redirect` shims register one tag→FQN row each in the
  central `jhost-tag->fqn` registry, so `instance?` and `class` derive from the
  class graph with no per-class arm — the same seam the java-value shims use.
- **AOT namespace pre-registration.** A `jolt build` binary now registers every
  namespace in its closure before any app form runs, so a load-time `(require 'x)`
  of an AOT'd namespace no-ops instead of hunting for absent source — needed by a
  namespace that conditionally requires a later, var-less one (babashka.process
  requires babashka.process.pprint, which only carries a `defmethod`).

### Fixed

- **`joltc build` require scanner accepts `::alias/kw` keywords.** The build's
  namespace scanner reads source before any namespace is loaded, so an
  alias-resolved auto keyword can't resolve yet; it is now read leniently in a
  scanner-scoped mode instead of failing the build with `Invalid token: ::alias/kw`.
  (#416)

## [0.4.3] - 2026-07-18

Compiler architecture consolidation: the per-op fact tables, the IR schema, the
`jolt.host` surface, and the class model each get a single source of truth, and all
~25 module-level pass/inference/emit atoms fold into one per-compilation context so
the compiler is reentrant. Plus var-metadata parity (`:ns` is a `Namespace`, defs
carry source position) and a fix for declaration-only vars in built binaries.

### Added

- **Var metadata carries source position.** `def`/`defn` attach `:line`/`:column`/
  `:file` to the var, like the JVM Compiler — what `spec` instrument and `expound`
  read. User code and loaded files carry it; a `clojure.core` var minted without a
  reader position does not (documented).
- **`:ns` in var metadata is a `Namespace`.** `(class (:ns (meta #'x)))` is now
  `clojure.lang.Namespace` instead of a string; it still prints as the namespace name.

### Changed

- **One compilation-unit context.** The pass/inference/emit state that lived in ~25
  module-level atoms across the analyzer passes and the back end now lives on a single
  per-compilation `unit`, threaded explicitly. A compilation is reentrant — two units
  never see each other's state — and the whole-program fixpoint no longer mutates
  shared config while a checker reads mid-estimates. The three record-shape registries
  collapse into one install.
- **Per-op facts derive from one registry.** The `native-ops`, fast-path, arity, and
  classifier tables the back end and the passes need are derived from a single
  `jolt.op-registry`, so a per-op fact is edited in one place and the mirrors can't
  drift.
- **The IR schema is written down and validated.** `jolt.ir` documents every op and its
  required keys; `JOLT_IR_VALIDATE` checks each form entering and leaving the pass
  pipeline in dev.
- **The `jolt.host` surface is pinned.** A manifest lists every `jolt.host` name, checked
  against the `def-var!` sites and the `jolt-core` references, so the host contract can't
  silently drift.
- **Java-layer dedup.** Class-model arms (count, str-render, instance checks) route
  through named registries with priority instead of last-writer-wins `set!` chains;
  `regex-translate.ss` moved into the java layer.

### Fixed

- **Declaration-only vars are discoverable in built binaries.** A no-init `def` now
  carries position metadata, so it emits `set-var-meta!` then `declare-var!` — and
  `declare-var!` must mark the already-interned cell resolvable. Without it, a
  `(declare x)` or a no-root `(def ^:dynamic *x*)` was missed by `find-var`/`resolve`/
  `ns-interns` in an AOT binary (only there — interactive use masked it).
- **A no-init `def` with metadata evaluates to its var**, not `nil` (`(var? (def x))`).
- **The seed mint fails loudly on a dropped overlay form.** A form that fails to compile
  in the converged fixpoint pass now aborts the re-mint instead of silently deleting the
  var while the byte-fixpoint still converges.

## [0.4.2] - 2026-07-18

The bulk of a focused compiler review: identifier hygiene, the numeric tower,
macro fidelity, reader/namespace behavior, typed throws, laziness/sorted
collections, syntax-quote, `eval`-embedded constants, and multimethod dispatch —
each change regression-tested and gated (`--opt` soundness pinned by a build
assertion). Deliberate divergences from the JVM are now documented in
`known-divergences.edn`.

### Fixed

- **Locals named after emitted runtime heads no longer miscompile.** A local
  bound to a name the back end emits as a bare Scheme head — `keyword`,
  `integer->char`, `case-lambda`, `dynamic-wind`, `host-new`,
  `record-method-dispatch`, and others — shadowed the emitted form and crashed
  (`(let [keyword 5] :a)` errored instead of returning `:a`). The muncher's
  shadow set now covers every such head.
- **`munge-name` is injective.** Distinct locals like `a'` and `a_PRIME_` munged
  to the same Scheme identifier, so one silently captured the other's value.
  Symbol characters are now escaped reversibly.
- **Subnormal doubles print correctly.** `(pr-str 4.9E-324)` produced a corrupt
  `"5.0E-256.0"` (a mangled Chez precision suffix); subnormals now round-trip.
- **`bigdec` is exact for ratios and scientific notation.** `(bigdec 1/4)` was a
  bigdec with a *ratio* in its unscaled field (so `(+ (bigdec 1/4) 1M)` gave
  `5/4M`); it now yields `0.25M`, `(bigdec 1/3)` throws like the JVM, and Inf/NaN/
  garbage strings throw `NumberFormatException`.
- **`==` handles BigDecimal operands** (`(== 3M 3)` threw) and, on a mixed long/
  double set, the `apply`/HOF path now agrees with the call-position result
  instead of comparing exactly (`(apply == [9007199254740993 9007199254740992.0])`).
- **`Math/round` / `clojure.math/round`** no longer crash on `##NaN`/`##Inf` or
  overflow to a bignum — they follow Java semantics (0, saturate, half-up).
- **`hash` of BigDecimals and negative/large ratios** matches the JVM (every
  bigdec previously hashed to one constant; ratios used the wrong integer hash).
- **`clojure.math` expm1/log1p keep precision near zero and hypot doesn't
  overflow**; the `Math/*` statics route to the same implementations.
- **Bit operations require a long operand** — a double/ratio (or `bit-not` on a
  non-integer) throws `IllegalArgumentException` instead of truncating or leaking
  a raw error; `bit-set`/`bit-flip` wrap to 64 bits.
- **`clojure.math/floor-div`/`floor-mod` return a long**, and `parse-double`
  trims whitespace and accepts a trailing `f`/`d` type suffix.
- **`case` treats composite constants as literals.** A vector/map/set test
  constant was evaluated (so `(case [1 2] [a b] …)` matched on the values of
  `a`/`b`); it is now quoted like a symbol or list constant.
- **`case`/`condp` throw `IllegalArgumentException`** (not `ex-info`) when no
  clause matches, so `(catch IllegalArgumentException …)` works like the JVM.
- **`for`/`doseq` nest `:let`/`:when`/`:while` in source order.** A `:while`
  after a `:when` no longer sees elements the `:when` filtered out, multiple
  `:while` clauses all apply, and `doseq` runs in constant space instead of
  realizing a `for` comprehension. `(for [x [2 4 3 6] :while (even? x) :when (> x 3)] x)`
  is now `(4)`.
- **`if-let`/`if-some`/`when-some` reject a malformed binding vector**, and
  `assert` expands to nothing when `*assert*` is false at compile time.
- **Taking the value of a macro is a compile error** (`(partial when …)` no longer
  silently yields the macro's expansion as data), and `get-method`, `methods`,
  `prefer-method`, `remove-method`, `remove-all-methods`, and `prefers` are
  functions, so they work under `map`/`apply`/`partial` like the JVM. (`instance?`
  stays a macro — jolt's class model precludes the fn form.)
- **`lazy-seq` forces its body exactly once and caches a thrown failure.** Two
  threads racing to realize the same cell could run the thunk twice; a thunk that
  threw left the cell unrealized so the next access re-ran it. Forcing is now
  guarded per cell, and a thrown condition is cached and re-raised.
- **`rsubseq` with two bounds** no longer returns `()` — it seeks from the end
  bound and walks predecessors (`(rsubseq (sorted-set 1 2 3 4 5) >= 2 <= 4)` is
  `(4 3 2)`).
- **`subseq`/`rsubseq` require a sorted collection** and throw `ClassCastException`
  on a plain map/vector instead of silently returning `nil`.
- **`with-meta`/`meta` work on sorted maps and sets** (previously threw).
- **`(take 0 coll)` doesn't realize the source** (it was forcing the first chunk).
- **`contains?` throws on a lazy seq or fn** like the JVM, instead of returning a
  silent `false` (it already threw for eager seqs).
- **`empty?` works on a transient collection.**
- **Kernel and collection errors throw typed exceptions.** `peek`/`subvec` and the
  `conj`/`nth`/`count`/odd-map-literal error paths threw bare strings or untyped
  conditions that a `(catch SomeException …)` wrongly caught; they now throw
  `ClassCastException` / `IllegalArgumentException` / `IndexOutOfBoundsException` /
  `UnsupportedOperationException`, and an odd-length map literal (`{1}`) raises
  `IllegalArgumentException` instead of crashing.
- **`throw-jvm` resolves any simple exception name through the class hierarchy**, so
  `(class e)` reports the full name (e.g. `java.lang.RuntimeException`) rather than a
  bare `RuntimeException` for names outside its short table.
- **Misordered `try` clauses and wrong-arity `recur` are compile errors.** A body
  expression after a `catch`, a second `finally` (or one that isn't last), and a
  `recur` whose argument count doesn't match the enclosing `loop`/`fn` are rejected
  at compile time instead of silently miscompiling or failing only at runtime.
- **`read-string` of a syntax-quote matches the JVM in more cases.** `` `() ``
  read as data was `(clojure.core/list ())` (evaluating to `(())`); it is now
  `(clojure.core/list)` = `()`. An interop head or fully-qualified class name in a
  read-time backquote (`` `.foo ``, `` `foo. ``) stays bare instead of being
  qualified to the current namespace, matching the compile path.
- **`eval` accepts an embedded BigDecimal, `#inst`, or `#uuid` value.** A form
  containing one of these values (read via `read-string`, or spliced by a macro)
  failed with `unsupported form`; the analyzer now emits it as the same constant a
  source literal produces. (Long / BigInt / Ratio already worked.)
- **Multimethods: preference conflicts, transitive preference, printing, and
  errors match the JVM.** `prefer-method` now throws `IllegalStateException` on a
  contradictory preference; a preference resolves an ambiguity transitively through
  the hierarchy (a preferred parent settles a child); a multifn prints as
  `#object[clojure.lang.MultiFn 0x0 "name"]` instead of dumping its record; the
  ambiguous-dispatch error names the dispatch value and the conflicting methods; and
  `defmulti` returns the var (not the multifn).
- **`*data-readers*` entries may be a fn or var**, not only a symbol — a tag bound
  to `inc` now applies it (`#t/tag 5` → `6`).
- **`--opt` no longer swallows an exception from dead code.** Scalar-replacement
  treated arithmetic (`+`/`min`/`zero?`/…) as never-throwing, so a throwing but
  unread initializer — `(let [m {:a (+ x "s")}] (:b m))` — was dropped and returned
  `nil` in an optimized build where dev/release threw. A discarded expression must
  now be *total* (never throws); merely-pure expressions are still relocated and
  duplicated (record scalar-replacement is unaffected).

## [0.4.1] - 2026-07-17

Correctness patch: the first round of a focused compiler review (correctness and
architecture), plus two loader fixes surfaced while running a real dependency
tree. Every behavioral change is regression-tested and, where it only shows in an
optimized build, pinned by a `--opt` build-smoke assertion.

### Fixed

- **`nil?`/`some?` folded to the wrong constant in optimized builds.** When
  inference proved a value nil, `jolt build --opt` folded `(nil? x)` to `false`
  and `(some? x)` to `true` — inverted — so an `if`/`if-some`/`when-some` gated
  on it took the wrong branch in a release binary (dev/interpreted mode was
  unaffected). The fold now matches: nil? true, some? and every type predicate
  false.
- **A `loop` that rebinds a record-typed outer local crashed under `--opt`.** The
  inference pass left the loop variable with the outer local's record type, so a
  slot read like `(:x p)` devirtualized to a raw record access and blew up when
  the loop actually carried something else — the common
  `(let [x (init)] (loop [x x] … (recur (f x))))` shape. Loop variables (and a
  `(fn f …)` self-reference) now correctly shadow the outer binding during
  inference.
- **`min`/`max` returned a float where they should return the original operand.**
  `(min 2.5 1)` returned `1.0` in optimized/release builds instead of `1` (dev
  gave `1`). Double contagion no longer applies to `min`/`max`, which return an
  argument unchanged.
- **`clojure.math` and `Math/*` leaked complex numbers.** Out-of-domain real
  inputs returned a Chez complex — `(Math/sqrt -1.0)` gave `0.0+1.0i` — instead
  of `##NaN`. `sqrt`, `pow`, `log`, `log10`, `log1p`, `asin`, and `acos` now
  return `##NaN` off their real domain, matching Java; in-domain results and
  `##NaN`/`##Inf` are unchanged.
- **`compare-and-set!`, `swap-vals!`, and `reset-vals!` were not atomic.** The
  overlay redefined them as check-then-act compositions that lost updates under
  real threads (futures/agents), shadowing the atomic mutex/CAS implementations.
  The atomic versions are restored.
- **Any missing namespace crashed with an opaque error.** `require` of a
  namespace with no source file raised `incorrect number of arguments 3 to
  throw-jvm` instead of a catchable `FileNotFoundException` naming the file —
  a stray argument in the loader's not-found path.
- **A failed nested `require` was blamed on the wrong file.** The reported source
  location pointed at the last form of a dependency that had just loaded
  successfully, not the `ns` form that issued the failing require. The loader now
  restores the source position after each nested load.

## [0.4.0] - 2026-07-17

Strict-resolution and default-fast-builds release: a five-dimension audit
(architecture, dead code, duplication, correctness, performance) followed by
two implementation waves (PRs #376–#388), every behavioral change certified
against reference JVM Clojure 1.12.5.

### Changed

- **Unresolved symbols are compile errors.** Top-level and operator-position
  references to undefined symbols throw "Unable to resolve symbol" at analyze
  time in every entry path (`-e`, files, `run`, built binaries) instead of
  silently producing unbound-var values that pattern-matched as truthy. Fn
  bodies still auto-declare (matching JVM-with-`declare` semantics); the nREPL
  path keeps late binding for interactive redefinition.
- **`-e` and file loading evaluate one top-level form at a time**, like the
  JVM: a `require` in one form is visible to the reader and analyzer of the
  next, so `joltc -e "(require '[x :as a]) ::a/k"` resolves. As a CLI
  convenience, `-e` auto-quotes `require`/`use` vector args.
- **Plain `jolt build` now direct-links and runs whole-program inference** —
  measured 2.5x on cross-namespace call loops with no flags. A plain `def` is
  frozen in the binary; `^:redef`/`^:dynamic` defs stay var-routed so runtime
  redefinition and `binding` keep working. Opt out with `--no-direct-link`,
  `--dev`, deps.edn `:jolt/build {:direct-link false}`, or
  `JOLT_NO_WP_INFER=1` for the inference fixpoint alone.
- **Vars are non-dynamic unless marked**, like the JVM: `binding` a var
  without `^:dynamic` metadata throws, `set!` of a dynamic var with no thread
  binding throws instead of mutating the root, and `(def ^:dynamic *x*)`
  declares bindable. All runtime-defined dynamic vars (`*out*`, `*1`,
  print flags, `&form`/`&env`, …) carry the tag.
- **`import` is a macro** (its specs are never evaluated, so bare
  `(import [java.nio.file Path])` works under strict analysis) and binds host
  class short names to class values; built binaries now run their `:import`
  clauses (they previously never did). `defmulti` interns its var at analysis
  like the JVM, so a reference later in the same form resolves.
- Errors across the runtime throw **typed JVM exceptions** — 79 sites that
  raised untyped host conditions are catchable by class:
  `(catch NoSuchElementException …)` for iterator exhaustion,
  `FileNotFoundException` for missing requires, `NumberFormatException`,
  `IndexOutOfBoundsException`, `ClassCastException`, `IllegalStateException`,
  `ArityException`, and friends, all oracle-verified. Broad
  `(catch Exception …)` continues to work everywhere.

### Added

- `jolt.deps/add-deps`: resolve an inline `:deps` map (git / local / Maven
  coordinates) at runtime and add the roots to the loader — the
  `babashka.deps/add-deps` idiom, detection included:
  `(when (System/getProperty "jolt.version") ((requiring-resolve 'jolt.deps/add-deps) '{:deps {…}}))`.
- `*jolt-version*` and `(System/getProperty "jolt.version")`: the release tag
  baked into binaries (else `git describe`, else `"dev"`); never nil under
  jolt, so it doubles as am-I-on-jolt detection.
- **Maven/gitlibs cache sharing with the JVM toolchain**: jars live at their
  standard `~/.m2/repository` paths (bidirectional reuse with clj);
  `:mvn/local-repo` in deps.edn relocates the repository like tools.deps,
  `JOLT_LOCAL_REPO` overrides from the environment; git deps reuse existing
  tools.gitlibs checkouts read-only and honor `$GITLIBS` for cache placement.
- Dev boot cache: `make devboot` precompiles the runtime so source-mode
  `bin/joltc` starts in ~0.3s instead of ~1.5s, with automatic staleness
  fallback. `jolt.main`/`jolt.deps` are AOT'd into the `joltc` binary
  (CLI commands no longer recompile them per invocation).
- Multimethods memoize isa?-resolved dispatch (invalidated by `defmethod`,
  `remove-method`, `prefer-method`, and hierarchy changes) with fixed-arity
  fast paths.

### Fixed

- for/doseq: `:while` can reference a preceding `:let` binding, and modifiers
  nest in written order (`:when`-skipped elements never reach a later
  `:while`).
- `extends?` sees inline `defrecord`/`deftype` protocol implementations
  without polluting `(extenders P)`; `select-keys` preserves metadata.
- Reader: `::alias/kw` with an unknown alias throws Invalid token instead of
  silently minting the wrong keyword; `\backspace`/`\formfeed` round-trip
  through pr; `*print-readably*` and `*print-namespace-maps*` are honored.
- `format`: unknown directives throw instead of emitting literal text while
  consuming the argument; `%s` renders nil as `"null"`.
- Deref of a failed future throws `ExecutionException` wrapping the original
  as its cause. `clojure.string/split` on zero-width matches splits between
  characters. Bit-shift counts mask to 6 bits; unary `bit-and`/`bit-or`/
  `bit-xor` throw `ArityException` (the raw variadic host primitives no
  longer leak through value positions). `(keyword 5)` returns nil. Var meta
  `:name` is a symbol. Transient read ops throw after `persistent!`.
  `System/gc` never throws (a guarded no-op while threads are active).
- Records: `assoc`/`dissoc` build the new record with one allocation and
  direct slot reads (~28% faster); `with-meta` on vectors shares structure
  (O(1), ~173x on kilo-element vectors); string hashing drops a per-hash
  UTF-16 allocation and caches like `String.hashCode` (18x on string-keyed
  lookups); bignum hashes are JVM-exact int32.
- Whole-program inference: the per-namespace IR cache stayed aligned past
  macro forms — under `--opt` every form after the first macro in a namespace
  had been silently compiled from the next form's IR, corrupting macro
  expanders.
- Startup/memory: embedded sources ship as UTF-8 bytevectors (~10MB steady
  RSS); the `joltc` boot GC peak is tunable; `ns-has-vars?` is O(1);
  stdout/stderr flush on every exit path (output no longer lost when the
  process exits while helper threads wind down).

### Internal

- The conformance corpus gate asserts `:expected :throws` rows raise on jolt
  and gates the crash bucket against an exact-label baseline; `jolt build`
  brackets each baked namespace with RT.load-parity compiler-var bindings;
  `jolt-load-string` no longer leaks a binding frame when the loaded source
  throws; the tree-shaker recognizes metadata-carrying defs as prunable and
  roots `global-hierarchy`.

## [0.3.3] - 2026-07-16

Full-codebase audit release: seven review rounds plus follow-ups (PRs
#362-#373), every behavioral fix certified against reference JVM Clojure.

### Fixed

- Build: `--embed` resources are baked into the binary at build time (shipped
  binaries no longer re-read build-machine paths at startup); tree-shaking is
  sound for redefined vars (duplicate-fqn refs union); binary namespace roots
  derive from the require graph, so namespaces loaded before the build hook
  (data-reader helpers and their requires) ship correctly.
- core.async: `alts!`/`alts!!` use handler registration — an alts put and an
  alts take on an unbuffered channel rendezvous instead of livelocking, and
  blocked alts no longer busy-poll. Fixed-buffer channels with transducers get
  real backpressure; pending rendezvous puts park through `close!` until a
  taker consumes their value (JVM-verified); `timeout` channels share one
  timer thread.
- Hashing: record hashes are JVM-exact defrecord hasheq (a bignum overflow
  into unchecked fixnum ops previously made equal values hash differently,
  nondeterministically); collections cache their hasheq lazily; vector/map/
  set hashes are value-identical to the JVM.
- Inference soundness: a `reduce` accumulator seeded `:double` no longer
  forces a coercion crash on nil-returning reducers; same-named records in
  different namespaces resolve exactly instead of by suffix; user `^double`
  hints survive HOF seeding; locals named like runtime identifiers
  (`jolt-nil`, `fl+`, …) are munged instead of shadowing.
- Reader/regex: mid-pattern `(?i)` applies to the remainder and `(?-i)`
  actually removes flags; `\Q…\E` quantifier scope, strict `\p{…}`, Java
  octal escapes, possessive quantifiers as atomic groups; radix-aware `N`
  literals (`042N` ⇒ `34N`); positioned EOF errors in string escapes;
  top-level `#?@` throws; record literals construct records; `#!` is a
  to-EOL comment (clojure reader only — EDN rejects it); syntax-quote
  resolves through the full alias/refer/core chain (`` `map `` ⇒
  `clojure.core/map`); core macros resolve as vars with `:macro` meta.
- clojure.test: `(is (instance? C x))` actually asserts; every assertion
  dispatches through the `report` multimethod; interned `:test`-meta tests
  run inside `:once` fixtures.
- Destructuring `:or` defaults are `get`'s not-found argument (JVM-exact:
  eager, sibling bindings in scope) — `{:or {b (inc a)}}` no longer throws.
- Laziness: `not-empty` uses `seq` (no more hanging on infinite seqs);
  `pmap` is semi-lazy with bounded look-ahead; `pprint` honors
  `*print-length*` by stopping; `when-first` tests the seq.
- Java compat: `io/copy` between files copies bytes (binary files no longer
  corrupted through a UTF-8 round-trip); deleting a non-empty directory
  throws/returns false; parsed timezone offsets apply; FQN and short class
  names share one statics table; bitwise `Math/getExponent`;
  `awaitTermination` actually waits; `ReentrantLock` is reentrant;
  interruptible bodies unwind their timers; `getAbsoluteFile` shares
  `getAbsolutePath`'s base; `(System/getenv)` reads the environment directly
  (multi-line values intact); shared counters and caches are mutex-guarded;
  string `index-of`/`last-index-of` from-args clamp like the JVM; `assert`
  messages evaluate at failure time.
- Memory: caught exceptions no longer root the captured continuation (a
  catch-complete hook clears it after the handler finishes; traces intact).
- On hosts with an unverified `struct stat` layout (e.g. aarch64 Linux),
  `getPosixFilePermissions`/`getOwner` throw a clear
  `UnsupportedOperationException` instead of reading garbage.

### Changed

- The whole-program shake's hand-maintained name lists are gate-verified; the
  17 run-gate scripts share one harness; `--opt` builds reuse the
  whole-program pass's analysis at emission; one mode→Chez-parameters table;
  the layered `Files` registrations collapse to one block per class; dead
  code across the runtime removed (shakesmoke byte-identity verified).
- The long-only integer boxing model is documented as the SPEC feature
  `:numerics/long-only` (`(short x)` range-checks but boxes as Long).

### Performance

- `subseq`/`rsubseq` seek from the comparator bound and walk lazily
  (O(log n) instead of materializing the collection); string scans stop
  allocating per candidate offset (`.indexOf` −20%, `replace` −12%);
  regex literals compile once per source string (~30× on literal-in-loop
  patterns); collection-as-map-key lookups no longer rehash O(n) per probe.

## [0.3.2] - 2026-07-15

### Changed

- Built binaries use roughly a third less memory. The launcher registers the
  appended boot image as a region of the executable (read through a file
  descriptor at startup) instead of holding a resident copy — 7–14 MB less
  depending on the app, on every platform. Tree-shaken binaries with no runtime
  eval now boot from `petite.boot` alone, dropping the bundled Chez compiler:
  another ~5 MB of memory and ~1 MB of binary size (macOS/Linux). A hello world
  goes from ~34 MB to ~22 MB resident; default (REPL-capable) builds keep the
  compiler and still save the boot copy.

## [0.3.1] - 2026-07-14

### Added

- Map destructuring follows Clojure 1.13.0-alpha4: idents after `&` in
  `:keys`/`:syms`/`:strs` (and the `!` variants) are keys, not binding symbols;
  `:or` accepts key→val entries; `:defaults name` binds a map of the resolved
  defaults; `:select name` binds a map of the mentioned keys, filled from `:or`
  and selecting deeply through nested map patterns. Adds `some-vals`.

### Fixed

- `(. Class staticMethod args)` now dispatches statically for the value classes
  (`Long`/`Integer`/`String`) and any registered/fully-qualified class, matching
  the `Class/staticMethod` slash form.
- `load-string` and `eval` handle source containing reader literals (`#inst`,
  `#uuid`, `#"regex"`): `load-string` reads raw forms like file loading, and
  `eval` self-evaluates opaque host values built by `read-string`.

## [0.3.0] - 2026-07-14

### Changed

- **Breaking:** `java.time.*` is no longer built into core — it is the
  [jolt-lang/time](https://github.com/jolt-lang/time) library. The full surface
  (`LocalDate`/`Time`/`DateTime`, `Instant`, `ZonedDateTime`, `OffsetDateTime`,
  `Duration`, `Period`, `Year`/`YearMonth`, zones with DST, `DateTimeFormatter`)
  is now portable Clojure over the value-semantics seams below, with
  [juxt/tick](https://github.com/juxt/tick) on top; tick's full suite passes. A
  program using `java.time.*` must depend on the library. Core keeps the `#inst`
  / `java.util.Date` layer and the libc zone/locale primitives (`tz-primitives`).

### Added

- `jolt.deps` resolves Maven coordinates. A Clojure library's Maven JAR carries
  its `.clj`/`.cljc` source, so a `:mvn/version` dep — including one pulled in
  transitively (tick declares its deps as Maven) — is fetched from Clojars/Central,
  extracted, and its `pom.xml` read for further transitive deps, with no JVM.
  Skips test/provided/optional deps, pure-Java or ClojureScript-only artifacts,
  and the clojurescript toolchain.
- Core value-semantics seams a library uses to give its own host values full
  Clojure semantics: `__register-eq!` / `__register-hash!` / `__register-str!` /
  `__register-pr!` / `__register-compare!`, and `__register-class!` so those
  values answer `class`/`type` and dispatch protocols extended to their class.
- `jolt.host/set-instant-ctor!` — the `#inst`/`Date` layer's `.toInstant` yields
  a library-owned instant, so `Date` and a library `Instant` are one representation.
- `java.util.Date` is now `Comparable` (`compareTo` / `clojure.core/compare`).

## [0.2.8] - 2026-07-13

### Added

- `jolt.fs` is now the [babashka.fs](https://github.com/babashka/fs) API. Jolt
  vendors babashka.fs over a new `java.nio.file` host shim — `Path`, `Files`,
  `FileTime`, file attributes, POSIX permissions, symbolic links, and directory
  walking with symlink-cycle detection. `jolt.fs` re-exports it as the public
  surface (require `babashka.fs` directly if you prefer). Symbolic links,
  creation time, and permissions — which the previous `java.io.File`-based
  `jolt.fs` could not do — now work through the shim's `stat`, `realpath`,
  `symlink`, `chmod`, and `getpwuid` bindings.
- A `java.nio.file` interop surface: `Paths`/`Path`, `Files` (predicates,
  create/delete/copy/move, read/write, temp files, `walkFileTree`,
  `newDirectoryStream`, attributes), `FileTime`, `PosixFilePermissions`,
  `FileVisitor`/`FileVisitResult`, and the `LinkOption`/`CopyOption`/`OpenOption`
  enums.
- `jolt.util/import-vars` — re-export a namespace's public vars as bakeable
  delegating definitions (functions and macros, with an `:exclude` set). The
  pattern for putting a public face on a vendored library; how `jolt.fs` wraps
  babashka.fs. Works in an AOT-built binary, unlike an `intern` over
  `ns-publics`.

### Fixed

- A built binary now includes a namespace's forms that follow a non-matching
  reader conditional. The AOT emission reader stopped at the first `#?(:cljs …)`
  (with no `:clj` branch), silently dropping every later `def` — so an AOT-built
  app crashed on an unbound var when it called one. This surfaced with
  babashka.fs (many cljs-only conditionals); a build-smoke fixture now builds a
  binary that uses the vendored library and checks it runs.

### Changed

- The documentation moved to the site ([jolt-lang.github.io](https://jolt-lang.github.io));
  the repo `docs/` folder is gone and the README links to the live pages.

### Notes

- `zip`/`unzip`/`gzip`/`gunzip` need `java.util.zip`, which Jolt does not shim
  yet, so those babashka.fs functions are excluded from `jolt.fs`.

## [0.2.7] - 2026-07-13

### Fixed

- `read-string`/`read` expand a syntax-quote at read time, like the JVM reader:
  `` (read-string "`(a ~b c)") `` returns the `(seq (concat (list 'ns/a) …))`
  form with symbols namespace-qualified against `*ns*` and auto-gensyms shared
  within a form, instead of a raw `(syntax-quote …)`. (edn and tools.reader are
  unaffected.)
- A qualified or aliased trailing-dot constructor — `(some.ns/Type. args)` or
  `(alias/Type. args)`, as SCI builds `sci.impl.types/Reified.` — now
  constructs the cross-namespace deftype instead of erroring "Unknown class
  \<ns\>"; a namespaced head never reached the constructor path before.

### Added

- The joltc CLI runs a bare file: `joltc FILE` (the `run` subcommand is now
  optional, like bb), and a `FILE` of `-` reads the program from stdin — so
  `joltc run -`, `joltc FILE`, and `joltc -` all work with piped input. A token
  that isn't a file still resolves as a deps.edn `:tasks` entry.

## [0.2.6] - 2026-07-13

### Fixed

- `defmacro` re-heads its generated expander with `clojure.core/fn`, not a bare
  `fn`, so a macro *named* `fn` — like prismatic/schema's `s/fn`, whose namespace
  does `:refer-clojure :exclude [fn]` — no longer resolves `fn` to the
  half-defined macro and fail at load with "Don't know how to create ISeq from:
  :object". Fixed in both the spine and the analyzer.
- `(class x)` returns a real class rather than the `:object` fallback for a few
  values whose class wasn't registered, so using one where a cast or `seq` is
  expected now reports the JVM's message: an unbound var value is
  `clojure.lang.Var$Unbound` (an exact match — the JVM throws the same
  `ClassCastException` for `(def x (+ x 1))`); a `reify` is a stable
  `clojure.lang.IObj$reify__0` placeholder (its JVM name is an unreproducible
  per-eval `ns$eval$reify__N`); `promise`/`future` match the JVM's stable
  enclosing-fn prefix, `clojure.core$promise$reify__0` / `$future_call$reify__0`.

### Added

- `resolve` gets the 2-arg `(resolve &env sym)` arity (nil when `sym` is a local).
- A `deftype`/`defrecord` type token (its constructor closure) is a full class
  value: `class?` is true, it carries `java.lang.Class` dispatch tags, `instance?`
  works when it's passed by value, and `.getName`/`.getSimpleName` answer off its
  tag. A named fn reports its own `ns$name` class plus `AFunction`/`IFn` tags —
  so a protocol extended to a Class value or a specific fn's class dispatches.
  (These, with `clojure.lang.MultiFn` `.addMethod` interop, `with-test`, and an
  `IdentityHashMap` shim, are what let prismatic/schema load, compile, and run.)
- The joltc CLI reads from stdin: `joltc -` runs a program read from stdin as a
  script, `joltc -e -` reads the expression from stdin; both set
  `*command-line-args*` from the trailing argv.

## [0.2.5] - 2026-07-12

Driven by running more libraries: camel-snake-kebab and clj-rss now pass their
suites, claxon passes its byte-parsing tests, and pretty passes four of its six
test namespaces. clj-rss runs over a new `clojure.data.xml` emitter shipped in
[jolt-lang/xml](https://github.com/jolt-lang/xml) v0.0.2.

### Fixed

- A char value reports `java.lang.Character` for protocol dispatch, so a
  protocol extended to `Character` matches a char. It reported nothing, so
  `(extend Character …)` never dispatched (camel-snake-kebab's separator split).
- Record literals `#pkg.Record{…}` read their map/vector values as data, like
  the JVM: `#user.Foo{:content ("a" "b")}` keeps the list instead of evaluating
  it as a call, while a nested record literal is still constructed.
- `(set! (.field obj) v)` compiles, matching `(set! (.-field obj) v)` — an
  instance-field write via the `.name` form was rejected.
- A chained numeric comparison with a `^long`/`^double` operand,
  `(<= 0x21 value 0x7e)`, expands to `(and (op a b) (op b c))` — the fast binary
  op received three arguments and emitted invalid code.
- `(String. bytes offset length charset)` decodes the requested slice; it
  decoded the whole array, ignoring offset/length.

### Added

- Clojure 1.12 qualified instance-method syntax `(ClassName/.method target
  args…)`, lowering to `(.method target args…)`.
- `clojure.lang.Compiler/CHAR_MAP` (the munge map).
- `java.util.WeakHashMap`, `java.util.Collections` (synchronized/unmodifiable/
  empty views), and `java.util.concurrent.atomic.Atomic{Reference,Integer,Long,
  Boolean}`.
- `java.util.concurrent.ExecutorService` / `Executors` backed by a real task
  queue and worker threads — a single-thread executor runs tasks strictly FIFO.
- `java.util.concurrent.locks.ReentrantLock`, `java.net.URI` `getUserInfo`,
  `System/console`/`lineSeparator`, `java.lang.Byte/toUnsignedLong`, and
  `java.nio.ByteBuffer` `slice` plus absolute/relative single-byte `get`.

## [0.2.4] - 2026-07-11

### Fixed

- Destructuring a rest pattern positionally walks the seq like the JVM:
  `(let [[[k v] & ks] a-map] …)` bound `k`/`v` to nil because the positional
  elements read `(nth coll i nil)` even when `&` is present. This silently
  broke `clojure.spec.alpha`'s `keys` conform — `s/valid?` accepted maps whose
  nested key specs failed.
- `empty?` is seq-based like the reference implementation: any seqable value
  answers (including the `java.util` collection shims) and a non-seqable
  raises `IllegalArgumentException` instead of an opaque host error.
- A deftype declaring a `clojure.lang` collection interface now matches the
  JVM at both ends: `instance?`/`map?`/`coll?`/`associative?` answer through
  the declared interface and its ancestry, and calling a declared-but-
  unimplemented method throws `AbstractMethodError` instead of falling back to
  the bare-deftype fields-as-map behavior.
- `inst?` is a real instance check covering `java.util.Date`, its `java.sql`
  subclasses, and `java.time.Instant` — the old tagged-map probe crashed on
  sorted collections and missed `Instant`.
- Throwables and reader conditionals no longer leak their internal map
  representation through `map?`/`coll?`/`ifn?`/`seqable?`/`instance? IObj`.
- Java regex hex and unicode escapes (`\xHH`, `\x{…}`, `\uHHHH`) translate to
  their characters before reaching the regex engine, which mis-parsed them.
- `keys`/`vals` accept any seq of map entries — `(keys (filter pred a-map))`
  works like `RT.keys`.
- A transient carries its source map's representation: an array map round-trips
  through `transient`/`persistent!` as an array map and reports
  `TransientArrayMap`; a hash map stays hash-ordered (previously everything
  came back in array mode).
- The `instance?` macro evaluates a var or local holding a Class value —
  `(def c (class x)) (instance? c y)` works — and `class?` recognizes Class
  values instead of always returning false.
- `clojure.pprint`'s cl-format engine: parametrized directives (`~5A`, `~2{`,
  `~20<`, …) rejected their own parameters, and a forward `~n@*` goto never
  moved. Both fixed, and the missing `~F`, `~$`, `~C`, `~R` (radix/roman), and
  `~(` case-conversion directives are implemented, so `(cl-format nil "~,2f" x)`
  and friends work. A JVM-certified subset of the upstream cl-format suite now
  runs as a standing gate.

### Added

- The JVM class model fills out across the board, driven by running type-
  introspection libraries (lasertag, expound, fireworks all pass or reach
  their documented ceilings): ~20 exception/error constructors with hierarchy
  placement, `java.util.ArrayDeque` and `HashSet`, `(class x)` for the
  `java.time` values, Agent/Volatile/Var/Delay/MultiFn/ReaderConditional/
  MapEntry, sorted and transient collections and hash-mode maps, JVM-shaped
  function class names and the `#object[…]` printed form, `Matcher`
  `.start`/`.end`, `String` `.repeat`/`.isBlank`, `getDeclaredFields`
  reflection over modeled types, a minimal `DateTimeFormatterBuilder`, and a
  `clojure.main` namespace with `demunge`.
- `clojure.test/*testing-contexts*` is a real bindable dynamic var and
  `testing` binds it; `testing-contexts-str` added.

### Changed

- Small sets preserve insertion order through the same array-mode backing that
  small map literals use (past 8 elements they go hash-ordered), so sets and
  maps share one deterministic iteration story. The `java.util` HashMap and
  HashSet shims iterate in insertion order too.
- Record fields fed a mix of integers and floats (`:num`) unbox in protocol-impl
  arithmetic at monomorphic call sites: whole-program builds emit a
  flonum-specialized clone per eligible impl (a `:num` field read beside a
  proven-double operand, where Clojure double contagion already fixes the
  result type), and devirtualized call sites resolve the clone while
  megamorphic dispatch keeps the shared impl. Mono-dispatch ~9% faster;
  results are bit-identical.
- Proven numeric sites and the protocol inline cache's warm-hit scan compile
  to Chez's per-site unsafe primitives (`#3%fl*`, `#3%vector-ref`): the type
  and bounds checks they skip are exactly the ones the compiler already
  proved redundant, so semantics are unchanged while megamorphic protocol
  dispatch gets ~4% faster. Checked `^long` arithmetic keeps its raising
  overflow behavior — fixnum ops are never emitted unsafe.
- `(double x)`, `(long x)`, `(int x)`, and `(float x)` casts feed the typed-
  arithmetic fast path the way `^double`/`^long` hints do: `(* (double x) 2.0)`
  compiles to flonum ops. The casts keep their full checked semantics
  (ClassCastException on a non-number, `(long ##NaN)` is 0, int range
  enforced), so they are a portable escape hatch where inference can't prove
  a type.
- BigDecimal literals follow JVM double contagion in compiled arithmetic:
  `(+ 1.5M 2.0)` is 3.5 (a Double) on the flonum fast path. Mixed
  bigdec/double expressions with non-literal bigdecs keep the generic
  (already correct) path.

- Whole-program builds infer record field types from the constructor
  arguments: a field every `(->Ctor …)` site fills with a flonum reads as a
  double (arithmetic over it unboxes, through protocol-method returns and
  reduce accumulators), and a field holding a record-or-nil narrows guarded
  reads to the direct accessor. No hints needed; conflicting or escaping
  constructors soundly leave fields untyped.

## [0.2.3] - 2026-07-11

### Fixed

- Release and optimized builds compile at Chez optimize-level 2, not 3 — level
  3 is unsafe mode (fx/fl/car operations skip their type checks) and jolt's
  error semantics depend on those raising: an optimized binary returned
  `(take nil coll)` instead of throwing and looped forever on a nil-count
  `repeat`. Costs ~8-13% on dispatch/allocation benchmarks, nothing on
  numeric ones.
- The standalone `joltc` binary's `-e` matches the script driver: trailing
  args bind `*command-line-args*`, the first `--` ends option parsing, and an
  uncaught throw reports its source location. Both entry points now share one
  dispatch (`cli-core.ss`), guarded against re-diverging by the load-manifest
  check.

### Changed

- The smoke and clojure-test-suite gates run against a freshly built joltc
  binary (10x faster boot than script mode): `make test` drops from ~12 to
  ~3 minutes (`make -j` parallelizes the rest), and the gates now exercise
  the shipped artifact — which is how both fixes above were found.

## [0.2.2] - 2026-07-10

### Added

- Refs and STM: `ref` (with `:validator`/`:meta`), `dosync`, `alter`, `commute`,
  `ref-set`, `ensure`, `sync`, `io!`, with serialized transactions on a single
  global lock; refs participate in watches/validators/metadata, and
  `*loaded-libs*` is a real ref over the loader registry (the tools.namespace
  reload pattern works). Transactions buffer writes and commit atomically:
  a thrown `dosync` rolls back, other threads never see uncommitted values,
  watches fire once per changed ref after commit, agent sends inside a
  transaction are held until commit, and transaction state does not leak into
  threads spawned inside a `dosync`. `(class (ref 0))` is `clojure.lang.Ref`,
  and `ref-min-history`/`ref-max-history` take the setter arity.
- `jolt.parser`: a general monadic parser-combinator core (`jolt.parser` +
  `jolt.parser.{basic,combinators,monad,position}`), adapted from rm-hull/jasentaa,
  with added combinators (`eof`, `between`, `sep-by`, an `optional` default-value
  arity, and the `digit`/`letter`/`alpha-num` character classes). Parse failures
  raise a jolt `ex-info`.
- `jolt.infix`: built-in infix math notation via the `infix`/`$=` macros and
  `from-string` (ported from rm-hull/infix), built on `jolt.parser`.
- Rounded out the `java.lang.Math` static surface: `atan2`, `sinh`, `cosh`,
  `tanh`, `cbrt`, `hypot`, `rint`, `floorDiv`, `floorMod`, `copySign`,
  `toRadians`, `toDegrees`, `log1p`, `expm1`.
- `java.text.ParseException` as a constructable/catchable host exception class,
  including `.getErrorOffset`.

### Changed

- `joltc` with no arguments starts a REPL, like `bb` and `clj` (piped stdin
  evaluates and exits). The nREPL server is the bare command
  `joltc nrepl-server [port]` — the flag spelling `--nrepl-server` is removed;
  `help` and `version` work as bare commands; an unknown command points at
  `joltc help`.
- Records store their fields inline (one heap object per record instead of a
  descriptor + separate values vector), and a typed non-nilable field read
  emits the receiver's direct per-arity slot accessor — no dispatch, one load.
  A retention-heavy construction microbenchmark allocates 25% less and runs
  ~44% faster; the mono-dispatch benchmark improves ~2.6x (101 → 39 ms,
  ~2.8x of JVM from ~7.8x). Nilable receivers keep the nil-safe read path
  (gate-pinned), and generic reads dispatch on the descriptor's field count.

### Fixed

- Reading a declared-but-unset var returns the `Var$Unbound` sentinel from
  every surface — a plain read, `@#'x`, and `var-get` all yield the same
  object (printing as `#object[clojure.lang.Var$Unbound …]`) instead of two
  of the three throwing; `bound?` still reports false.
- The self-host byte-fixpoint runs in CI: the seed rebuild is byte-identical
  on the pinned source-built Chez, so a seed source edited without a remint
  fails the gate on every platform.
- A tree-shaken binary crashed at startup when the project registered data
  readers (`data_readers.clj`): the emitted launcher re-scanned the source roots
  and eagerly reloaded each reader namespace through `jolt-compile-eval-form`,
  which a no-eval `--tree-shake` build has dropped. Data readers and reader
  namespaces are now baked once and not re-scanned at runtime, so a
  `(read-string "#my/tag …")` resolves its reader in the binary as it does under
  `joltc run`.
- Tree-shake soundness: a reader fn reached only through the baked
  `*data-readers*` map — including one registered programmatically via
  `alter-var-root`, not just via `data_readers.clj` — is now a DCE root, so the
  shake no longer prunes it and degrades `read-string` to a call error. App-form
  reference collection unions an IR walk (`:var`/`:the-var` nodes) with a text
  scan of the emitted Scheme, so a `(var-deref "ns" "nm")` a macro splices in
  with no IR node still roots its target.
- `jolt build --library`: the launcher guard now wraps the prologue (native
  loads + source-root setup) as well as the export-publish body, so an init
  failure anywhere reports and returns non-zero instead of leaving
  `jolt_lookup` silently returning `NULL` for every name.
- A warmed monomorphic protocol-call site in a direct-linked build now honors a
  runtime `extend-type`: the per-site cache carries the protocol epoch and
  re-resolves when an extension bumps it, so every dispatch path serves the new
  implementation.
- `--opt` builds no longer fold away a throwing operation: `/`, `quot`, `rem`,
  `mod`, `even?`, and `odd?` are not treated as pure, so
  `(:a {:a 1 :b (/ 1 0)})` raises `ArithmeticException` like Clojure instead of
  folding to `1`.
- A var read in a call or collection literal now evaluates in source order
  against a mutating sibling: `(f (do (def y 2) 0) y)` passes `[0 2]` like
  Clojure instead of reading `y` before the mutation.
- List libspecs whose second element is a keyword — `(:require (ns :only [x]))`
  — parse as libspecs everywhere (previously `require`/`use` mis-read them as
  prefix lists); the JVM rejects that shape outright, so this is a documented
  superset.
- A tree-shaken binary that queues agent sends inside a `dosync` no longer
  prunes `send` (the STM commit path resolves it by name at runtime); a new
  gate asserts every such runtime reference is a shake root.

## [0.2.1] - 2026-07-09

### Added

- `Throwable->map` (`:via`/`:cause`/`:data` over the `ex-cause` chain).
- The 11 core dynamic vars the JVM defines that were missing (`*agent*`,
  `*repl*`, `*compile-path*`, `*source-path*`, …), with real context behavior:
  `*agent*` is bound inside agent actions, `*repl*` and the `*1`/`*2`/`*3`/`*e`
  history work in `joltc repl`, `*file*`/`*source-path*` bind during loads, and
  `*command-line-args*` carries app args for `run` and `-m`.
- `clojure.test/test-var` and `test-vars`; `run-tests` discovers tests attached
  via `:test` var metadata, and `deftest` vars carry `:test` metadata.

### Changed

- `ns-map` returns every visible mapping (imports, refers, interns) and
  `ns-refers` includes the implicit `refer-clojure`, matching the JVM.
- Maps print with comma-separated entries (`{:a 1, :b 2}`).
- Double printing follows `Double.toString` (plain decimal only in
  `[1e-3, 1e7)`, otherwise `d.dddE±x`); `pr` of a beyond-long integer carries
  the BigInt `N` suffix.
- `hash-map` results iterate in insertion order up to the array-map threshold,
  like ClojureScript.

### Fixed

- The numeric fast path keeps `=` exactness-aware: `(= ^double-x 0)` is `false`
  like the JVM, and `:long` typing comes only from an explicit `^long` hint —
  an unhinted integer loop keeps arbitrary precision instead of raising a
  fixnum overflow.
- `require` honors `:reload`, `:reload-all`, and `:verbose`; a namespace whose
  load throws can be required again after the file is fixed; a data reader
  that resolves but throws surfaces its error (naming the tag) instead of
  silently degrading.
- `joltc -e EXPR args…` binds the trailing args as `*command-line-args*`
  (nil when empty), and the first standalone `--` is consumed as the POSIX
  end-of-options marker in every arg-taking path (`-e`, `run FILE`, `-m`,
  `-M` aliases, tasks, and `build` flags); later `--` stay literal.
- `(?x)` COMMENTS-mode regexes follow Java: whitespace (including newlines —
  multi-line patterns previously matched nothing) and `#`-comments are
  stripped, even inside character classes, and a mid-pattern cluster works.
- `$` matches before a final newline like Java; `\<`/`\>` are literal escapes;
  regex literals keep the backslash of an escaped quote in their source.
- `clojure.string/split-lines` drops trailing empty strings.
- `clojure.pprint` no longer emits trailing spaces before line breaks.

## [0.2.0] - 2026-07-09

### Added

- `jolt.fs` — file-system utilities in the standard library (predicates, glob,
  recursive copy/delete, move, `which`, temp dirs), shaped after `babashka.fs`.
- Data readers work in ahead-of-time binaries: reader namespaces are compiled in
  and `*data-readers*` is baked, so runtime `read-string` of `#tag` literals
  works in built executables.
- Reader errors report `file:line:column` in the message and carry
  `:file`/`:line`/`:column` in `ex-data`.
- [yamlstar](https://github.com/yaml/yamlstar) and
  [jolt-lang/yaml](https://github.com/jolt-lang/yaml) (libyaml bindings with a
  `clj-yaml.core` compat layer) are listed as supported libraries.

### Changed

- Performance round one: protocol dispatch goes through per-descriptor tables
  with polymorphic inline caches, record constructors inline, dynamic invoke and
  var access are cheaper, and collection equality/hash/reduce walk vector chunks
  directly. Geometric mean on the benchmark suite improved from ~6x to ~2.8x of
  JVM Clojure.
- Release builds run the inference passes (dispatch caches, devirtualization,
  constructor inlining) by default — 3.4x on dispatch-heavy code. Inlining and
  scalar replacement additionally require `--opt` with direct linking; projects
  can opt in via `deps.edn` `:jolt/build {:opt true}`.
- Optimized builds compile at Chez optimize-level 3 with compressed fasl output
  (−37% binary size).
- `defcfn` resolves its foreign symbol lazily on first call, so an optional
  `:jolt/native` library that is missing no longer aborts startup — a missing
  symbol is a catchable error at the call site.
- `spit` writes atomically (temp file + rename), so a crash mid-write can no
  longer truncate the target.
- The host class model (`instance?`, class tokens, type tags, `supers`) derives
  from a single class graph instead of parallel hand-maintained tables.

### Fixed

- Tree shaking soundness: `ns-publics`-family reflection triggers the
  keep-everything bail, a `defonce` no longer silently disables the whole shake,
  and data-reader functions are kept as roots.
- Native build link line: static archives precede system `-l` flags, paths are
  quoted, and Windows builds pass `--export-all-symbols`.
- Exceptions from `go`/`thread`/`Thread` bodies and data-reader load failures
  surface on stderr instead of being swallowed.
- A malformed `deps.edn` fails with a clear error instead of being ignored.
- `instance?` evaluates a local or var operand holding a class value instead of
  quoting it as a literal class name.
- Regex parity with Java: combined inline flag clusters (`(?sx)`, `(?si:…)`),
  scoped dot-all, escaped `]` inside character classes, and
  `Matcher.appendReplacement` escape semantics in replacement strings.
- `intern` and `alter-meta!` carry `:macro` through, and macro vars report
  `:macro` metadata.
- `require` of a namespace defined earlier in the same file is satisfied.
- `File.setLastModified` actually sets the file's mtime.
- `String.codePointAt` and `Character/toChars`; bigint edge-case coercions.

## [0.1.7] - 2026-07-06

### Added

- `jolt build --library` ahead-of-time compiles a project into a managed-runtime
  shared library (C ABI) for embedding Jolt in host applications, with
  Windows-friendly naming, build-time toolchain validation, and robust
  initialization.

### Changed

- The boot script now probes multiple names for the `chez` executable, improving
  discovery across installs.

## [0.1.6] - 2026-07-04

### Changed

- `JOLT_TRACE` tail-frame history now resolves each frame to its `ns/name`
  (`file:line`) source position instead of an opaque call site.

## [0.1.5] - 2026-07-04

### Fixed

- `JOLT_TRACE` is honored at runtime in a built `joltc` binary — it was
  previously baked in at build time and ignored the environment on the target
  machine.

## [0.1.4] - 2026-07-04

### Added

- Tail-call-optimized (elided) frames are recovered and shown in uncaught-error
  stack traces.

### Changed

- Tracing is on by default during REPL-driven development; `JOLT_TRACE` uses a
  single case-insensitive off-check covering both enable paths.

### Fixed

- Ahead-of-time builds run `-main` with `*ns* = user`, matching `clojure.main`.

## [0.1.3] - 2026-07-04

### Added

- Clojure 1.13 parity: `req!`, checked-keys destructuring, and keyword array maps.

### Fixed

- `build` invoked with a no-main entry namespace now runs the namespace as a
  script instead of crashing.

## [0.1.2] - 2026-07-04

### Added

- A `joltc` version string.

### Fixed

- nREPL server runs on Windows.
- `deps.edn` files that omit `org.clojure/clojure` no longer warn.
- Missing vendor submodules now fail with an actionable error.

## [0.1.1] - 2026-07-02

### Added

- Windows release binaries (x86_64) built via MSYS2/MinGW and statically linked
  into a single-file executable.
- The `clojure-test-suite` is vendored as a standing conformance gate
  (`make cts`).
- Every conformance corpus row is tagged with `:portability` (`:common` vs.
  `:jvm`).
- A single `IRef` seam shares watches, validators, and metadata across `atom`,
  `var`, and `agent`.

### Changed

- Binary numeric operators dispatch through a Numbers-style category model.
- Hierarchy functions follow the reference contracts, and `deftype` classes join
  the class graph.
- `clojure.string` performs `toString` coercion; `some-fn`/`ifn?` follow
  reference semantics.
- The reader enforces strict tokens, and EDN mode matches the reference's error
  contracts.
- `rand-nth` follows the reference shape.

### Fixed

- General divergences surfaced by the `clojure-test-suite`.
- `clojure.test/are` substitutes through `clojure.template`.
- Checked narrow casts, and runtime `require` in self-contained-built binaries.

### Removed

- Delisted `next.jdbc` (JVM/JDBC-driver dependent).
- Dropped `x86_64-macos` from releases (GitHub retired the Intel runner).

## [0.1.0] - 2026-07-01

Initial public release. Jolt is a self-hosting Clojure implementation on
[Chez Scheme](https://cisco.github.io/ChezScheme/) — it reads Clojure source,
analyzes it to a host-neutral IR, emits Scheme, and runs it on Chez, shipping a
Clojure-compatible standard library.

### Added

- **Language & runtime**: a self-hosted compiler (reader → analyzer → IR →
  Scheme backend) written in Clojure and driven by a checked-in bootstrap seed;
  `bin/joltc` evaluates expressions, runs a line REPL, and serves an nREPL
  server.
- **Persistent collections**: 32-way-trie vectors, HAMT hash maps and sets, with
  transient variants and linear-time builds.
- **Numeric tower**: exact integers, bignums, ratios, and doubles; category-aware
  `=` (`(= 3 3.0)` ⇒ `false`) and value-equality `==`.
- **Sequences & transducers**: lazy and infinite sequences, plus
  transducer-returning `map`/`filter`/`take`/… and `transduce`, `into`,
  `sequence`, `eduction`, and `reduced`.
- **Types & abstractions**: multimethods with hierarchies;
  `defprotocol`/`deftype`/`defrecord`/`reify`/`extend-protocol`/`extend-type`;
  metadata; and full `ns` forms.
- **Reference & concurrency types**: atoms (per-atom mutex, JVM-style CAS),
  volatiles, delays, `future`/`promise`/`agent`/`pmap`, and `clojure.core.async`
  over native channels.
- **Reader**: `#()` fn literals, `#_`, `#?` reader conditionals, tagged literals
  (`#inst`, `#uuid`), `#"…"` regex via vendored irregex, and a proper char type.
- **Runtime macroexpansion**: `eval`, `load-string`, and `defmacro` at runtime.
- **Standard library**: `clojure.string`, `clojure.set`, `clojure.walk`,
  `clojure.edn`, `clojure.pprint`, and the `jolt.ffi` foreign-function interface
  (foreign-callable callbacks, binary-faithful buffer I/O, `:blocking` calls,
  and `:jolt/native` library declarations).
- **Host interop shim**: a subset of the `java.*` standard library (including
  `java.time` Duration/Period/enums) so portable Clojure loads; class tokens are
  names rather than loaded classes, with no reflection or `gen-class`/`proxy`.
- **Ahead-of-time builds**: `joltc build -m ns -o out` compiles a project into a
  single self-contained executable (runtime + `clojure.core` + stdlib + app +
  `deps.edn` dependencies) with `--opt` inference/inlining passes and opt-in
  `--direct-link` and `--tree-shake` whole-program dead-code elimination.
- **Standalone toolchain binary**: `make joltc-release`/`make joltc-debug` link a
  single `joltc` that runs and `build`s apps without a local Chez or C toolchain.
- **Conformance gates**: a JVM-sourced conformance corpus (`make corpus`/
  `make certify`), a bootstrap self-hosting fixpoint (`make selfhost`), and an
  SCI compatibility stress gate (`make sci`).
- **Distribution**: a self-contained `joltc` binary, a Homebrew tap, and an
  install script.

[Unreleased]: https://github.com/jolt-lang/jolt/compare/v0.7.3...HEAD
[0.7.3]: https://github.com/jolt-lang/jolt/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/jolt-lang/jolt/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/jolt-lang/jolt/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/jolt-lang/jolt/compare/v0.6.9...v0.7.0
[0.6.9]: https://github.com/jolt-lang/jolt/compare/v0.6.8...v0.6.9
[0.6.8]: https://github.com/jolt-lang/jolt/compare/v0.6.7...v0.6.8
[0.6.7]: https://github.com/jolt-lang/jolt/compare/v0.6.6...v0.6.7
[0.6.6]: https://github.com/jolt-lang/jolt/compare/v0.6.5...v0.6.6
[0.6.5]: https://github.com/jolt-lang/jolt/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/jolt-lang/jolt/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/jolt-lang/jolt/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/jolt-lang/jolt/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/jolt-lang/jolt/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/jolt-lang/jolt/compare/v0.5.20...v0.6.0
[0.5.20]: https://github.com/jolt-lang/jolt/compare/v0.5.19...v0.5.20
[0.5.19]: https://github.com/jolt-lang/jolt/compare/v0.5.18...v0.5.19
[0.5.18]: https://github.com/jolt-lang/jolt/compare/v0.5.17...v0.5.18
[0.5.17]: https://github.com/jolt-lang/jolt/compare/v0.5.16...v0.5.17
[0.5.16]: https://github.com/jolt-lang/jolt/compare/v0.5.15...v0.5.16
[0.5.15]: https://github.com/jolt-lang/jolt/compare/v0.5.14...v0.5.15
[0.5.14]: https://github.com/jolt-lang/jolt/compare/v0.5.13...v0.5.14
[0.5.13]: https://github.com/jolt-lang/jolt/compare/v0.5.12...v0.5.13
[0.5.12]: https://github.com/jolt-lang/jolt/compare/v0.5.11...v0.5.12
[0.5.11]: https://github.com/jolt-lang/jolt/compare/v0.5.10...v0.5.11
[0.5.10]: https://github.com/jolt-lang/jolt/compare/v0.5.9...v0.5.10
[0.5.9]: https://github.com/jolt-lang/jolt/compare/v0.5.8...v0.5.9
[0.5.8]: https://github.com/jolt-lang/jolt/compare/v0.5.7...v0.5.8
[0.5.7]: https://github.com/jolt-lang/jolt/compare/v0.5.6...v0.5.7
[0.5.6]: https://github.com/jolt-lang/jolt/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/jolt-lang/jolt/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/jolt-lang/jolt/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/jolt-lang/jolt/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/jolt-lang/jolt/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/jolt-lang/jolt/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/jolt-lang/jolt/compare/v0.4.15...v0.5.0
[0.4.15]: https://github.com/jolt-lang/jolt/compare/v0.4.14...v0.4.15
[0.4.14]: https://github.com/jolt-lang/jolt/compare/v0.4.13...v0.4.14
[0.4.13]: https://github.com/jolt-lang/jolt/compare/v0.4.12...v0.4.13
[0.4.12]: https://github.com/jolt-lang/jolt/compare/v0.4.11...v0.4.12
[0.4.11]: https://github.com/jolt-lang/jolt/compare/v0.4.10...v0.4.11
[0.4.10]: https://github.com/jolt-lang/jolt/compare/v0.4.9...v0.4.10
[0.4.9]: https://github.com/jolt-lang/jolt/compare/v0.4.8...v0.4.9
[0.4.8]: https://github.com/jolt-lang/jolt/compare/v0.4.7...v0.4.8
[0.4.7]: https://github.com/jolt-lang/jolt/compare/v0.4.6...v0.4.7
[0.4.6]: https://github.com/jolt-lang/jolt/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/jolt-lang/jolt/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/jolt-lang/jolt/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/jolt-lang/jolt/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/jolt-lang/jolt/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/jolt-lang/jolt/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/jolt-lang/jolt/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/jolt-lang/jolt/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/jolt-lang/jolt/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/jolt-lang/jolt/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/jolt-lang/jolt/compare/v0.2.8...v0.3.0
[0.2.8]: https://github.com/jolt-lang/jolt/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/jolt-lang/jolt/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/jolt-lang/jolt/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/jolt-lang/jolt/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/jolt-lang/jolt/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/jolt-lang/jolt/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/jolt-lang/jolt/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/jolt-lang/jolt/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/jolt-lang/jolt/compare/v0.1.7...v0.2.0
[0.1.7]: https://github.com/jolt-lang/jolt/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/jolt-lang/jolt/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/jolt-lang/jolt/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/jolt-lang/jolt/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/jolt-lang/jolt/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/jolt-lang/jolt/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/jolt-lang/jolt/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jolt-lang/jolt/releases/tag/v0.1.0
