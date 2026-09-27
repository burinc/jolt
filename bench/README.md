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

Measured 2026-09-26 on an Apple Silicon MacBook Pro (M1 Max, macOS 26.3): jolt 0.8.13 (the tree of commit ad4618f1) built as `target/release/jolt`, OpenJDK 20.0.1, Chez 10.4.1. Sorted by ratio; the AOT rows first, then `startup`, then the run-mode rows.

| Benchmark | vs JVM | jolt (ms) | JVM (ms) | What it measures |
|---|---:|---:|---:|---|
| `arrays-unhinted` | **0.00×** | 53.9 | 11536.4 | the same array code without type hints |
| `char-scan-unhinted` | **0.01×** | 88 | 8011 | the same scan without type hints |
| `gc-arrays` | **0.02×** | 33.0 | 2098.0 | major-collection pause with a large typed array live (read jolt ms only, see below) |
| `typed-records` | **0.03×** | 9.5 | 309.9 | records with `^double`/`^long`/`^String` field types at construction and every read |
| `typed-records-unhinted` | **0.05×** | 14.6 | 314.2 | the same records without field types |
| `string-ops-unhinted` | **0.07×** | 213 | 3090 | the same string interop without type hints |
| `vecops` | **0.18×** | 3.1 | 17.0 | vector concat (`into`), `subvec` windows, split/rejoin (the RRB axis) |
| `tak` | **0.40×** | 8.0 | 20.2 | deep three-way self-recursion + integer arith |
| `collections` | **0.70×** | 8.3 | 11.8 | persistent map/vector churn + map/filter/take/reduce over the result |
| `dispatch` | **0.76×** | 44.0 | 57.7 | megamorphic protocol dispatch |
| `metadata` | **0.92×** | 87 | 95 | `with-meta`/`meta`/`vary-meta`, ops that carry meta (`assoc`/`conj`/`into` on a meta-bearing coll), a positioned form tree rebuilt with meta kept |
| `stm` | **0.92×** | 110.6 | 120.5 | ref creation, `dosync` `ref-set`/`alter`, `deref` in a loop |
| `mandelbrot` | **0.93×** | 14.0 | 15.0 | pure float compute, no allocation or dispatch |
| `sorted-access` | **1.1×** | 15.3 | 14.5 | shape-answered reads: `count`/`drop` on a vector seq, `rseq`, `first` of a sorted map/set |
| `seqs` | **1.1×** | 168.7 | 150.7 | lazy-seq + HOF pipelines: `map`/`filter`/`reduce`, `every?`, `iterate`/`take`, `mapcat` |
| `literals` | **1.1×** | 28 | 25 | constant map/vector/set literals and quoted forms in a fn body, boolean predicates (per-form constant pool) |
| `binary-trees` | **1.2×** | 49.7 | 40.8 | escaping short-lived records: allocation / GC pressure |
| `nth-access` | **1.3×** | 39.2 | 30.9 | `nth` on a vector, small and large, with and without a default |
| `fib` | **1.3×** | 9.3 | 7.2 | recursion: call overhead + integer arith |
| `loop-recur` | **1.4×** | 26.0 | 19.2 | tight `loop`/`recur` with `mod`/`quot`/`bit-xor` per iteration |
| `hash-eq` | **1.4×** | 262 | 187 | hashing vectors/maps/sets/records/seqs, collection-keyed lookups, `=` on equal and unequal collections |
| `transients` | **1.5×** | 118 | 77 | bulk map/set building through `into`, `assoc!`/`conj!`, `zipmap`/`frequencies`/`group-by` |
| `lazy-threads` | **1.6×** | 111.2 | 67.4 | lazy pipelines after a `Thread` has existed (cells claimed by CAS, no mutex per cell) |
| `cst-format` | **1.7×** | 86.1 | 51.9 | the source-formatter shape: a CST of one 10-key map per token, then an atom-per-node mutating walk building the output with `str` |
| `mathfns-unhinted` | **1.7×** | 43.9 | 25.8 | the same math without type hints |
| `string-scan` | **1.8×** | 3070 | 1751 | `clojure.string` over a large payload: split/replace/trim, and whether a literal pattern reaches the regex engine |
| `coll-dispatch` | **1.9×** | 126 | 67 | kind dispatch on small collections: `get`/`assoc` on a 4-key map, a first/next walk, `count`/`conj`/`nth`/`=` on short lists and vectors |
| `string-ops` | **2.1×** | 213 | 102 | `.indexOf`/`.startsWith`/`.substring`/`.toLowerCase` on hinted strings, `clojure.string`, keyword `.getName` |
| `mono-dispatch` | **2.2×** | 32.4 | 14.5 | monomorphic protocol dispatch (devirt / inline cache can fire) |
| `host-io` | **2.2×** | 1081 | 483 | reading THROUGH the `java.io` shim: a form off a reader, a chunked `char[]` drain, `String`↔`char[]` |
| `string-build` | **2.3×** | 113 | 50 | `StringBuilder` in a loop and transducer-over-`join` |
| `mathfns` | **2.3×** | 43.0 | 18.9 | `java.lang.Math` sqrt/sin/cos/log/pow/atan2 over doubles |
| `printing` | **2.4×** | 602.9 | 250.9 | `pr-str` over scalars and namespaced maps, `print` into a rebound `*out*`, `format` with numeric directives and flags |
| `keyed-lookup` | **2.5×** | 68 | 27 | hashing keywords/symbols/strings and looking them up in small maps |
| `apply-rest` | **2.6×** | 156.0 | 60.5 | `apply` of `+ max min < <=` and a user variadic over a million-element rest (streamed, not materialized) |
| `parallel-colls` | **2.9×** | 282 | 98 | eight threads, each on its own values: `assoc`/`conj`/`swap!`/`str`/`hash`/`re-find`/`with-meta` (what the runtime shares behind their backs) |
| `executors` | **3.0×** | 1470.4 | 483.5 | `java.util.concurrent`: fire-and-forget enqueue, submit/get, growth to 64 blocking tasks, four producers on one pool |
| `arrays` | **3.3×** | 550.4 | 168.1 | primitive `double-array` throughput (hinted `aget`/`aset`) |
| `byte-arrays` | **3.3×** | 135.7 | 40.6 | raw bytes in bulk: block copies, a drained stream, `String`↔`byte[]`, hinted `^bytes` access |
| `transducers` | **3.5×** | 115.7 | 32.7 | transducer pipelines (`comp` of `map`/`filter`/`take`) |
| `char-scan` | **5.3×** | 85 | 16 | `.charAt` per code point with the `int`/`long`/`unchecked-*` casts, a `case` state machine |
| `sorted-build` | **6.4×** | 357.9 | 56.2 | `into` a sorted-map/sorted-set in and out of key order, `sorted-map-by`, replace-every-key (one tree walk per insert) |
| `compile-forms` | **6.9×** | 710.3 | 102.5 | **compiling**, not running: `load-string` of 200 top-level defns and of one `deftest` holding 200 `is` forms |
| `startup` | **0.15×** | 77 | 509 | a built hello-world, whole process from exec to exit, best of 7 (JVM: `java -cp … clojure.main -m hello`) |
| `mix-64` ×100000 (run mode) | **7.6×** | 31.1 | 4.1 | SplitMix `mix-64`: 64-bit integer arithmetic (heap bignums past the 61-bit fixnum) |
| `deftype+protocol` ×100000 (run mode) | **0.95×** | 7.0 | 7.4 | open-world deftype allocation + protocol dispatch |
| `split + rand-long` ×20000 (run mode) | **8.7×** | 33.2 | 3.8 | the PRNG: bignum 64-bit arithmetic + dispatch |
| `gen/large-integer` ×2000 (run mode) | **2.2×** | 20.0 | 9.0 | `gen/large-integer`: arithmetic + rose-tree generator machinery |
| `(gen/vector gen/large-integer)` ×500 (run mode) | **5.9×** | 224.8 | 37.8 | element generation + generator machinery |

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
- **`parallel-colls`** is eight threads doing the same per-call work on their
  own values, so `mean:` is a wall clock that a lock anywhere on those paths
  multiplies. It prints its one-thread time and the per-thread slowdown above
  `mean:`; read the slowdown against the JVM's, which sits near 2× on the same
  machine because eight threads share one allocator and one memory bus there
  too. Noisier than a single-threaded row (±10%).
- **`compile-forms`** measures jolt compiling, not running. The reference
  builds bytecode and generates no native code at load; jolt asks Chez for
  optimized native code for every form, which is roughly half its time.
- **`cst-format`** is the one row with a NON-JVM reference. It is the shape of
  standard-clojure-style — a CST of one small fixed-key map per token, then an
  atom-per-node mutating walk — and the upstream implementation of that
  formatter is JavaScript, so the same work can be timed on V8. Measured on one
  x86_64 Linux box, 57 KB of Clojure source: node 14.4 ms, JVM Clojure 167 ms,
  jolt 290 ms. Read it as two facts rather than one — the IDIOM costs ~12x V8
  before jolt is involved (persistent maps, an atom per node, and an output
  string rebuilt per line, against plain objects, in-place fields and V8's
  cons-strings), and jolt costs ~1.7x the JVM on top of that. It prints its own
  parse/format split above `mean:`; `mean:` is the row.
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
bench/scorecard.clj          # render this README from README.tmpl + the two logs
```

**This file is generated.** The scorecard table comes from one sitting's logs:

```sh
JOLT_BIN=target/release/jolt bench/run.sh > run.log
JOLT_BIN=target/release/jolt bench/testcheck.sh > tc.log
jolt run bench/scorecard.clj run.log tc.log --measured "Measured <date> on <machine>: jolt <version>, OpenJDK <v>, Chez <v>. …"
```

renders `bench/README.tmpl` (a Selmer template) into `bench/README.md`, sorted
by ratio, and refuses a partial run — every bench in `run.sh --list` needs a row
in the logs and a one-line description in the script. Edit the template, not
this file. `COLD=1 bench/startup.sh` drops the binary from the page cache
between reps with `bench/pagecache.clj` (`posix_fadvise` on Linux, `msync` on
macOS, where the kernel only partly honours it; the resident bytes it prints
beside each rep say how cold the run really was).

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

What the 2026-09 round after 0.8.8 is covered by: `parallel-colls` (the four
process-wide locks that were on per-call paths, the atom's compare-and-swap,
and metadata as a field — eight threads on their own values, where a shared
lock shows as a per-thread slowdown), `metadata` (meta in a slot of the
collection record: `with-meta` is a copy, a carry is a slot read), and
`coll-dispatch` (the record predicates and accessors in front of every
collection op open-coded, and the collection layouts loaded ahead of the
dispatchers so it applies to them; `make recordinline` gates the mechanism,
the row says what it is worth). `cst-format` is the end-to-end row those
three feed.

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
