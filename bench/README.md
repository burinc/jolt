# jolt benchmark suite

Benchmarks that isolate the workload axes jolt's optimizing passes target. The
ray tracer (`examples/ray-tracer`) is **float-compute-bound** — its time is
irreducible algorithmic math (hit-testing + transcendentals), and devirt,
allocation removal, and type-proving all measured **flat** on it. So it can't
tell us whether those passes work. These benchmarks make each pass's target
workload the *dominant* cost.

Reference: the cross-language suites these draw from —
[Are We Fast Yet?](https://github.com/smarr/are-we-fast-yet) (Marr et al., DLS '16)
and the [Computer Language Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/).
The benchmarks are portable Clojure, so they also run on JVM Clojure for an
absolute reference.

## Benchmarks

| Benchmark | Axis | Pass it exercises | Source |
|---|---|---|---|
| `binary-trees` | allocation / GC pressure (escaping short-lived records) | scalar-replace, escape analysis | CLBG |
| `dispatch` | polymorphic (**megamorphic**) protocol dispatch | devirt, inline-cache | AWFY-style |
| `mono-dispatch` | **monomorphic** protocol dispatch (devirt/inline-cache *can* fire) | devirt, inline-cache | AWFY-style |
| `collections` | persistent map/vector churn (HAMT / 32-way tries) + map/filter/take/reduce over the built vector | persistent structures, transients | CLBG k-nucleotide-style |
| `mandelbrot` | pure float compute (tight arith loops, no alloc/dispatch) | native arith, loop codegen | CLBG |
| `arrays` | primitive `double-array` throughput (unboxed `aget`/`aset`, no boxing/collections) | unboxed primitive-array codegen (flvector read/write) | CLBG-style |
| `mathfns` | transcendental math (`java.lang.Math` sqrt/sin/cos/log/pow/atan2 over doubles) | native `Math` op lowering (`flsqrt`/`flsin`/… vs generic host-static dispatch) | CLBG-style |
| `fib` | recursion: function-call + integer-arith overhead | native arith, small-fn inlining | CLBG |
| `tak` | ~0.3× | ~0.4× | 7.0 | 20.1 | deep three-way self-recursion + integer arith (beats the JVM) |
| `fib` | ~1.1× | ~1.0× | 7.7 | 7.1 | recursion: call + integer arith |
| `dispatch` | ~1.2× | ~1.2× | 70.0 | 60.6 | megamorphic protocol dispatch |
| `mathfns` | ~1.5× | ~1.5× | 25.3 | 16.7 | transcendental math (`Math` sqrt/sin/cos/log/pow/atan2 over doubles) |
| `mandelbrot` | ~1.7× | ~1.7× | 23.7 | 14.3 | pure float compute |
| `collections` | ~1.8× | ~1.8× | 23.3 | 12.9 | persistent map/vector churn |
| `loop-recur` | ~1.8× | ~1.8× | 30.7 | 17.5 | tight loop/recur + per-iteration integer arith (`mod`, `quot`, `bit-xor`) |
| `mono-dispatch` | ~2.6× | ~2.6× | 38.7 | 14.7 | monomorphic protocol dispatch |
| `arrays` | ~6.4× | ~6.2× | 235.0 | 37.0 | primitive `double-array` throughput (unboxed `aget`/`aset`) |
| `seqs` | ~6.3× | ~6.1× | 921.3 | 147.2 | lazy-seq + HOF pipelines (allocation + per-element calls) |
| `binary-trees` | ~7.0× | ~7.0× | 277.7 | 39.8 | escaping short-lived records (allocation/GC) |
| `transducers` | ~7.2× | ~7.3× | 236.0 | 32.7 | transducer pipelines (comp of map/filter/take) |

`opt` and `release` track each other closely across the suite — the plain
`jolt build` picks up most of the win.

The arithmetic/loop half of the suite now sits at ~1–2× the JVM. The 2026-07
numeric-pass round did most of that: mixed long×double contagion (a `:long`
operand beside a proven double widens via `fixnum->flonum`, so `Math` calls
over it lower to native flonum ops instead of generic host dispatch — `mathfns`
~22.7×→~1.5×) and JVM literal-init loop semantics (a `(loop [i 0] …)` counter
is a primitive long, so its `inc`/compare/`mod`/`quot` run as fixnum ops —
`loop-recur` ~8.3×→~1.6×, and `mandelbrot`'s grid counters took it ~2.0×→~1.6×).
`tak` beats the JVM outright (direct-linked self-calls + proven fixnum arith);
`fib` sits at ~1.1–1.2×.

The remaining gaps are the allocation-bound axes (~6–7×):

- **`arrays` ~6.4×** (was ~18.6×): two rounds took it there. The fixnum-first
  index path in `jolt-flaget`/`jolt-flaset` removed the per-access index
  coercion (~18.6×→~9.5×), then emit-side inlining removed the procedure
  boundary itself — on a site where the pass has proven a `^doubles` array and
  a `:long` index, the back end now emits `(flvector-ref (jolt-array-vec a) i)`
  directly, so the flonum stays unboxed through the surrounding `fl+` chain
  instead of being boxed at the wrapper's return (~9.5×→~6.4×). The residual is
  the checked `flvector-ref` + record accessor at O2, Chez boxing the
  loop-carried flonum accumulator (~145ms of the 235ms on a 40M-iteration
  loop), and the JVM SIMD-vectorizing the dot loop. Hoisting the loop-invariant
  `jolt-array-vec` accessor out of the loop is the queued next lever.
- **`seqs` ~6×**: the allocation axis idiomatic Clojure hits most —
  range/map/filter/reduce chains, short-circuiting `every?`, `iterate`/`take`,
  and `mapcat` all build lazy-seq cells and call a closure per element. The
  lazy-seq work (lock elision, chunk fusion, transducer arities) brought it
  down from ~10.9×; it stays the dominant cost of script-style workloads.
- **`transducers` ~7.2×, `mono-dispatch` ~2.6×, `binary-trees` ~7.0×**:
  collapsed from two orders of magnitude by the type-proving / inline-field /
  bare-read work (`binary-trees` ~140×→~7×, `mono-dispatch` ~330×→~2.6×). On a
  statically proven monomorphic receiver, devirt resolves the impl and a
  per-site inline cache holds it; `binary-trees` nodes escape into the tree,
  so scalar-replace can't remove them — residual GC pressure over generic
  reads of untyped nilable fields.
- **`dispatch` ~1.1×**: a megamorphic site runs a per-site polymorphic inline
  cache (4-slot descriptor scan, `#3%` reads over the proven cache shape), so
  it no longer pays a registry lookup per call.
- **`collections` ~1.9×**: JVM-exact Murmur3 hashing plus the array-map
  `(k . v)` fold; the residual is Murmur3 on integer keys, which the JVM JITs
  to a handful of instructions.

## 64-bit integer arithmetic & generators (test.check)

The AOT suite above is float-compute / dispatch / allocation bound; none of it
exercises **64-bit integer arithmetic**, which Chez can't hold in a fixnum
(61-bit), so genuine 64-bit values are heap bignums. The SplitMix PRNG behind
`clojure.test.check` is the worst case — every `rand-long` is ~8 bignum ops. These
were measured in **run mode** (`jolt run`, where per-site var-cell caching is on;
the AOT build keeps it off) against JVM Clojure on the same portable source. The
first two rows are isolating microbenchmarks; the rest are real test.check
generators.

| workload | jolt | JVM | ratio | bound by |
|---|---|---|---|---|
| SplitMix `mix-64` (×100k) | 45ms | 14ms | ~3.2× | 64-bit integer arithmetic |
| deftype alloc + protocol dispatch (×100k) | 41ms | 5ms | ~8× | open-world dispatch |
| raw `split` + `rand-long` (×20k) | 74ms | 6ms | ~12× | bignum 64-bit + dispatch |
| `gen/large-integer` (×2k) | 108ms | 23ms | ~4.7× | arithmetic + rose-tree machinery |
| `(gen/vector gen/large-integer)` (×500) | 1289ms | 88ms | ~14.6× | element gen + gen machinery |

Two no-C codegen levers collapsed the **arithmetic** half: emitting `bit-and`/
`bit-or`/`bit-xor`/`bit-not` as inlined Chez `bitwise-*` primitives (they had gone
through a var-deref'd variadic overlay), and caching the resolved var cell per
reference site (a name lookup was ~45ns/access). Together they took `mix-64` from
~18× → ~3.2× JVM and the raw PRNG from ~30× → ~12×, and the generators ~1.6× each.

The residual gap is **machinery, not arithmetic**: the open-world generator
deftype/protocol dispatch + rose-tree allocation (~8–10×) can't be devirtualized
without static types, and the raw 64-bit ops bottom out at the Chez bignum floor
(~20× a native long, substrate-inherent). A native SplitMix C/FFI shim would give
the PRNG ~27× but is the only path that needs C.

## Running

```sh
bench/run.sh                 # full suite + JVM scorecard
bench/run.sh fib             # one benchmark, default size
bench/run.sh fib 32          # one benchmark, custom size
NO_JVM=1 bench/run.sh        # jolt only (skip the JVM reference)
MODE_A=1 bench/run.sh        # also time each bench as a plain release build
```

Two build modes matter: **optimized** (`--direct-link --opt`, the default
scorecard — inlining, scalar replacement, closed-world direct linking) and
**release** (plain `jolt build`, what a default build ships — inference passes
but no direct-link/inlining). `MODE_A=1` adds the release column so a
release-mode win or regression is visible; it roughly doubles build time, so
it's on demand.

Needs Chez's kernel dev files (`libkernel.a` + `scheme.h`) and `cc` for the build,
like `jolt build`; set `JOLT_CHEZ_CSV` to override the detected csv dir.

## Startup / small-program latency

`bench/run.sh` builds each benchmark to a binary and times the compute *inside*
it, so it deliberately excludes `jolt`'s own startup. That fixed floor — boot the
runtime + compiler image, then compile the program — is what dominates ys-style
workloads: many short `jolt prog.clj` runs where the program itself runs for
milliseconds. `bench/startup.sh` measures it, whole-process wall clock (best of N)
for a built jolt against babashka on the same sources:

```sh
bench/startup.sh                          # default 7 reps
REPS=15 bench/startup.sh                   # more reps
JOLT_BIN=/path/to/jolt bench/startup.sh   # pick the binary
```

Three sizes: `version` (pure boot floor, no program), `trivial` (boot + compile +
run a one-liner), `script` (a small lazy-seq pipeline). Use a BUILT jolt
(`target/release/jolt` or an installed one), not the dev `bin/jolt` source
launcher — the dev script boots from source and opts out of the AOT cache, so it
is not representative. Indicative (M-series): ~117ms vs babashka ~18ms (~6.5×).
The floor is runtime + compiler image instantiation that re-runs each boot (Chez
has no heap snapshot); see the CLI-closure AOT work that removed the per-boot
recompile of `jolt.main`.

`startup.sh` tells you the floor is there but not where it goes. `bench/startup-phases.sh`
attributes a `jolt prog.clj` run to four phases so a change shows which one it moved:

```sh
bench/startup-phases.sh                              # 7 reps, 400 defns, 30M-iter loop
REPS=15 bench/startup-phases.sh                      # more reps
DEFNS=800 LOOP=60000000 bench/startup-phases.sh      # heavier compile / run
JOLT_BIN=/path/to/jolt bench/startup-phases.sh      # pick the binary
```

`boot` is `jolt --version` (runtime + image load, `jolt.main` recompile).
`dispatch` is the deps/project resolve + load-file setup a file run adds on top,
measured against a `nil` file. `compile` is the delta of a compile-heavy,
run-trivial program (many defns) over the `nil` file, and `run` is the delta of a
run-heavy, compile-trivial program (one long loop). The phases are external
subtractions, each isolating one cost by construction — honest approximations,
not a strict partition, but directional: speed up the compiler and `compile`
drops, speed up the runtime and `run` drops. Indicative (M-series): boot ~110ms,
dispatch ~1ms, compile ~400ms for 400 defns, run ~120ms for a 30M-iter loop —
compilation is the dominant per-program cost.

## A/B against a change

To measure a pass, run the suite on `main`, then on the branch, back to back
(same machine, quiet). Each benchmark prints `runs: [...]` and `mean: N ms`;
compare the means. A pass is worth landing when it moves a benchmark whose axis it
targets, even if the ray tracer stays flat.

`bench/aba.sh` automates an A1/B/A2 over the six benches: it checks out the
parent's compiler files (`host/chez/seed/image.ss` +
`jolt-core/jolt/passes/types.clj`), builds and times each bench against `HEAD`,
then restores the working tree. A1≈A2 rules out drift; B vs A is the change.
