# jolt benchmark suite

What jolt costs against JVM Clojure on the same portable source, one axis per
row. `make test` and `make libconformance` check that answers are right and
neither notices when they get slower — `arrays` once went 5.4× on a codegen
change with every gate green, because every answer was still correct — so this
suite is the throughput gate: a release compares it against the previous
release and blocks `publish` on the result (`ci/bench-gate.sh`, wired into
`.github/workflows/release.yml`), and the scaling gates in `make test` pin the
complexity class of the paths the rows measure. See [Gating](#gating).

The benchmarks draw on [Are We Fast Yet?](https://github.com/smarr/are-we-fast-yet)
and the [Computer Language Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/),
plus shapes lifted from real libraries (honeysql's formatting loop, instaparse's
message cache, malli's test suite). Each file's header says what it isolates
and which compiler pass or runtime seam it exists to watch.

## Scorecard

Measured 2026-09-09 on an Apple Silicon MacBook Pro (M1 Pro, macOS 26.3): jolt 0.8.6 (the tree of
commit 871ef34c) built as `target/release/jolt`, OpenJDK 20.0.1, Chez 10.4.1. Sorted by
ratio; the AOT rows first, then `startup`, then the run-mode rows.

| Benchmark | vs JVM | jolt (ms) | JVM (ms) | What it measures |
|---|---:|---:|---:|---|
| `arrays-unhinted` | **0.01×** | 59.9 | 10831.2 | the same array code without type hints |
| `char-scan-unhinted` | **0.01×** | 113 | 7764 | the same scan without type hints |
| `gc-arrays` | **0.02×** | 29.7 | 1725.7 | major-collection pause with a large typed array live (read jolt ms only, see below) |
| `typed-records` | **0.03×** | 10.7 | 310.3 | records with `^double`/`^long`/`^String` field types at construction and every read |
| `typed-records-unhinted` | **0.07×** | 19.9 | 292.6 | the same records without field types |
| `string-ops-unhinted` | **0.10×** | 302 | 2958 | the same string interop without type hints |
| `vecops` | **0.26×** | 4.1 | 15.9 | vector concat (`into`), `subvec` windows, split/rejoin (the RRB axis) |
| `tak` | **0.36×** | 6.7 | 18.7 | deep three-way self-recursion + integer arith |
| `stm` | **0.81×** | 122.0 | 151.5 | ref creation, `dosync` `ref-set`/`alter`, `deref` in a loop |
| `dispatch` | **1.2×** | 65.6 | 56.6 | megamorphic protocol dispatch |
| `fib` | **1.4×** | 9.3 | 6.8 | recursion: call overhead + integer arith |
| `loop-recur` | **1.5×** | 28.5 | 18.8 | tight `loop`/`recur` with `mod`/`quot`/`bit-xor` per iteration |
| `collections` | **1.5×** | 16.6 | 10.9 | persistent map/vector churn + map/filter/take/reduce over the result |
| `mandelbrot` | **1.5×** | 21.9 | 14.2 | pure float compute, no allocation or dispatch |
| `mathfns-unhinted` | **1.9×** | 41.9 | 22.2 | the same math without type hints |
| `binary-trees` | **1.9×** | 75.3 | 39.4 | escaping short-lived records: allocation / GC pressure |
| `literals` | **2.2×** | 55 | 25 | constant map/vector/set literals and quoted forms in a fn body, boolean predicates (per-form constant pool) |
| `mathfns` | **2.3×** | 41.3 | 17.8 | `java.lang.Math` sqrt/sin/cos/log/pow/atan2 over doubles |
| `sorted-access` | **2.4×** | 31.0 | 13.1 | shape-answered reads: `count`/`drop` on a vector seq, `rseq`, `first` of a sorted map/set |
| `seqs` | **2.4×** | 346.7 | 144.9 | lazy-seq + HOF pipelines: `map`/`filter`/`reduce`, `every?`, `iterate`/`take`, `mapcat` |
| `transients` | **2.5×** | 154 | 61 | bulk map/set building through `into`, `assoc!`/`conj!`, `zipmap`/`frequencies`/`group-by` |
| `hash-eq` | **2.6×** | 480 | 186 | hashing vectors/maps/sets/records/seqs, collection-keyed lookups, `=` on equal and unequal collections |
| `printing` | **2.7×** | 752.4 | 282.2 | `pr-str` over scalars and namespaced maps, `print` into a rebound `*out*`, `format` with numeric directives and flags |
| `mono-dispatch` | **2.7×** | 37.0 | 13.8 | monomorphic protocol dispatch (devirt / inline cache can fire) |
| `nth-access` | **2.7×** | 62.3 | 23.2 | `nth` on a vector, small and large, with and without a default |
| `string-ops` | **3.0×** | 298 | 98 | `.indexOf`/`.startsWith`/`.substring`/`.toLowerCase` on hinted strings, `clojure.string`, keyword `.getName` |
| `executors` | **3.2×** | 1328.8 | 421.7 | `java.util.concurrent`: fire-and-forget enqueue, submit/get, growth to 64 blocking tasks, four producers on one pool |
| `keyed-lookup` | **3.6×** | 91 | 25 | hashing keywords/symbols/strings and looking them up in small maps |
| `lazy-threads` | **3.7×** | 237.4 | 64.8 | lazy pipelines after a `Thread` has existed (cells claimed by CAS, no mutex per cell) |
| `arrays` | **3.7×** | 592.8 | 160.0 | primitive `double-array` throughput (hinted `aget`/`aset`) |
| `apply-rest` | **3.8×** | 222.1 | 58.3 | `apply` of `+ max min < <=` and a user variadic over a million-element rest (streamed, not materialized) |
| `transducers` | **4.0×** | 124.6 | 30.8 | transducer pipelines (`comp` of `map`/`filter`/`take`) |
| `byte-arrays` | **4.5×** | 167.0 | 37.5 | raw bytes in bulk: block copies, a drained stream, `String`↔`byte[]`, hinted `^bytes` access |
| `string-build` | **4.5×** | 183 | 41 | `StringBuilder` in a loop and transducer-over-`join` |
| `char-scan` | **6.0×** | 108 | 18 | `.charAt` per code point with the `int`/`long`/`unchecked-*` casts, a `case` state machine |
| `compile-forms` | **8.3×** | 817.1 | 98.5 | **compiling**, not running: `load-string` of 200 top-level defns and of one `deftest` holding 200 `is` forms |
| `sorted-build` | **13.3×** | 701.3 | 52.6 | `into` a sorted-map/sorted-set in and out of key order, `sorted-map-by`, replace-every-key (one tree walk per insert) |
| `startup` | **0.19×** | 84 | 443 | a built hello-world, whole process from exec to exit, best of 7 (JVM: `java -cp … clojure.main -m hello`) |
| `mix-64` ×100000 (run mode) | **5.8×** | 30.5 | 5.3 | SplitMix `mix-64`: 64-bit integer arithmetic (heap bignums past the 61-bit fixnum) |
| `deftype+protocol` ×100000 (run mode) | **3.5×** | 23.0 | 6.5 | open-world deftype allocation + protocol dispatch |
| `split + rand-long` ×20000 (run mode) | **12.1×** | 43.7 | 3.6 | the PRNG: bignum 64-bit arithmetic + dispatch |
| `gen/large-integer` ×2000 (run mode) | **4.9×** | 41.5 | 8.5 | `gen/large-integer`: arithmetic + rose-tree generator machinery |
| `(gen/vector gen/large-integer)` ×500 (run mode) | **12.2×** | 461.9 | 38.0 | element generation + generator machinery |

**vs JVM** is jolt ÷ JVM Clojure on the same source: lower is better, and
under 1.0× jolt is faster. Every row is from one `bench/run.sh` followed by one
`bench/testcheck.sh` on one machine in one sitting, which is the only way the
ratios mean anything; absolute milliseconds are that machine's and are not
comparable to a table measured elsewhere. AOT rows are optimized standalone
binaries (`jolt build --direct-link --opt`) timing the compute inside, the
mean of 3 runs after warmup. A plain `jolt build` (`MODE_A=1`) tracks the
optimized column to within 0.2 of a ratio point across the suite.

Reading it:

- **One run is not evidence.** Per-row noise is about 1.07× on a quiet
  machine, more on the first row of a run and on `executors` (four producers
  fighting over one mutex). Re-measure a row that moved, alone, on both sides
  (`bench/run.sh <name>`) before believing it.
- **`gc-arrays`** times full collections with one array rooted across them.
  Read its jolt milliseconds against jolt only: the vs-JVM column mostly
  reports that a JVM full GC's floor is ~750× a Chez major collection's, and
  `System/gc` is a hint there and a full collection here.
- **`*-unhinted`** rows are the same source with the type hints removed — what
  a hint buys, and what unhinted library code pays.
- **`compile-forms`** measures jolt compiling, not running. The reference
  builds bytecode and generates no native code at load; jolt asks Chez for
  optimized native code for every form, which is roughly half its time.
- **`startup`** is the one whole-process row: the boot image's decode plus the
  runtime's init, which every other row excludes by timing inside a running
  binary. `bench/startup.sh` and `bench/startup-phases.sh` break it down
  further (boot, dispatch, compile, run) and compare against babashka.
- The **run mode** rows (`bench/testcheck.sh`) reach library code through a
  `require`, the way a test suite does, rather than as an AOT binary. They are
  bound by 64-bit integer arithmetic (a genuine 64-bit value is a heap bignum
  past Chez's 61-bit fixnum) and by open-world generator dispatch.

Diagnostics kept out of the table because the JVM has no reference for them:
`ffi_arenas.clj` (jolt.ffi), `image_refs.clj` (jolt.image) and `fibers/`.
Run them from this directory with `../bin/jolt -Sdeps '{:paths ["."]}' -m <ns>`
and compare exact base and candidate runs on one host.

## Running

```sh
bench/run.sh                 # full suite + the startup row, vs JVM Clojure
bench/run.sh fib             # one benchmark, default size
bench/run.sh fib 32          # one benchmark, custom size
bench/run.sh startup         # the startup row alone
NO_JVM=1 bench/run.sh        # jolt only (skip the JVM reference)
MODE_A=1 bench/run.sh        # also time each bench as a plain `jolt build`
JOLT_BIN=target/release/jolt bench/run.sh   # a built jolt instead of bin/jolt

bench/testcheck.sh           # the run-mode rows (test.check, 64-bit arithmetic)
bench/startup.sh             # startup vs babashka; COLD=1 adds cold-page-cache runs
bench/startup-phases.sh      # boot / dispatch / compile / run attribution
```

`run.sh` builds each benchmark to a binary because jolt's optimizing passes
(direct linking, inlining, scalar replacement, whole-program inference) fire
only in an AOT build — `jolt run -m` is unoptimized. The build needs Chez's
kernel dev files (`libkernel.a` + `scheme.h`) and `cc`, like `jolt build`; set
`JOLT_CHEZ_CSV` to override the detected csv dir. `testcheck.sh` needs the
test.check jar in `~/.m2` (or network on first run) for both hosts. Use a
BUILT jolt (`JOLT_BIN`) for anything startup-related — the dev `bin/jolt`
launcher boots from source and is not what users run.

Do not run two jolt or `clojure` invocations in this directory at once: both
write `.cpcache` here, and the loser reads a half-written classpath.

## Gating

**Against the previous release.** `ci/bench-gate.sh <baseline-jolt>
<candidate-jolt> [max-ratio] [bench…]` builds every benchmark in
`bench/run.sh --list`, plus `hello` for the `startup` row, with both compilers,
times them alternately on one machine (min of 3 after a discarded warm-up) and
fails above 1.40× candidate/baseline on any row. The release workflow runs it
against the newest published release and `publish` needs it green. There is no
millisecond threshold anywhere: a ratio between two binaries on one runner is
the only shape of timing assertion this repository allows in a gate, because an
absolute ceiling false-fails on a slow runner and passes on a fast one while
hiding a real regression. A benchmark newer than the baseline release is
skipped with a note, not failed. The threshold is deliberately loose — it is a
gate, not a scorecard — and a flagged row is re-measured alone before anything
is concluded about its size.

**Inside one process.** `make test` carries the shape gates, each a ratio
measured in one run so machine speed cancels: `readscaling`, `compilescaling`
(1× vs 4× input, and quoted-vs-constructed forms), `applyscaling` (`apply`
streams an unbounded rest — `(apply > (range))` must answer), `lazyscaling`
(the same lazy workload before and after a thread has existed), `vecscaling`,
`pipescaling`, `chunkscaling`, `printscaling`, `ioscaling`, `hotscaling` and
`rrbscaling`. A row here says how fast; a gate there says the complexity class
did not change.

What 0.8.6's performance changes are covered by: `byte-arrays` (hinted
`^bytes` stores), `sorted-build` (one tree walk per insert), `lazy-threads`
(cells claimed by compare-and-swap, no mutex per cell), `apply-rest` (streamed
rest, var roots that stream), `compile-forms` and `literals` (the constant
pool keyed by form identity), `printing` (`format`), and `startup` (the boot
image codecs and the LZ4 ceiling fallback).

## A/B against a change

Run the suite on `main`, then on the branch, back to back on a quiet machine,
and compare the `mean:` lines; a pass is worth landing when it moves the row
whose axis it targets. `bench/aba.sh` automates an A1/B/A2 over a fixed set of
benches: it checks out the parent's compiler files, builds and times each bench
against `HEAD`, then restores the working tree — A1≈A2 rules out drift, B vs A
is the change.

`aba.sh` compiles with `jolt build`, whose binaries are baked with tracing off,
so it is structurally blind to anything that only exists on the `jolt run` /
`-M:alias` path — where tail-frame tracing is on by default, and where a
per-call ring save/restore once cost up to 19× on numeric code while every AOT
number stayed flat. `bench/aba-trace.sh /tmp/jolt-A /tmp/jolt-B` is the
dev-mode A/B/A over two already-built binaries; its bench set spans both
call-heavy (`fib`, `tak`, `binary-trees`) and numeric-loop (`arrays`,
`mathfns`, `loop-recur`, `mandelbrot`) shapes because the regression above was
invisible to a call-heavy set alone. Tracing is not free and is uneven (`fib`
~10×, numeric loops within noise); time a dev-mode run with `JOLT_TRACE=0` and
give it its own `JOLT_CACHE_DIR`, since the flag changes the emitted code.
