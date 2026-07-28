# AOT cache content hash — implementation report

## 1. Failing-test output (Round 1, before the fix)

```
PASS: (a) cold load output=42, cache files=1
PASS: (b) warm load output=42
PASS: (c) after edit output=99
FAIL: (c2) after edit output='42' (expected 99 — equal-hash sampled stale)
PASS: (d) cold='macro-42' warm='macro-42'
PASS: (e) cold='7' warm='7'
PASS: (f) cold='got-hi' warm='got-hi'
PASS: (g) cold=':subval' warm=':subval'
PASS: (h) warm=42, :reload-after-edit=99
PASS: (i) install-owned clojure.set produced 0 cache files
PASS: (j) corrupt cache recovered, output=42, rebuilt .so
SKIP: (k) needs chez + target/release/jolt (make testbin)
PASS: (l) macro-ns edit invalidated its consumer (v1 -> v2)
PASS: (m) transitive dep edit invalidated the chain (v1 -> v2)
PASS: (n) pruned 6 generations to 3, current one live

aot-cache smoke: 13 passed, 1 failed
```

The (c2) case reproduces the bug: a same-length edit (`42` → `99`) on a ~4KB+ source
with the value in the middle of the file produces a cache-key collision. `equal-hash`
does not see the edit because its 26-byte sampling window missed the changed bytes.
The cache serves stale output (`42`) instead of the edited value (`99`).

The existing (c) case continued to pass because its 36-byte source is nearly fully
sampled and the edit falls within the sampled window — a fixture weakness, not a
passing behaviour.

## 2. Negative test (Round 3)

Reverted only the `aot-cache-key` change (`aot-content-hash` → `equal-hash` in that
one function) while leaving `aot-content-hash` defined and in use by the other three
sites. Result:

```
FAIL: (c2) after edit output='42' (expected 99 — equal-hash sampled stale)
aot-cache smoke: 13 passed, 1 failed
```

The (c2) case failed exactly as in Round 1, confirming the fixture is correctly gated
on the `aot-cache-key` fix. Restored the `aot-content-hash` call, and (c2) returned
to passing — 14 passed, 0 failed.

## 3. Gate results

### make aotcachesmoke

```
PASS: (a) cold load output=42, cache files=1
...
PASS: (c2) large-fixture edit invalidated, output=99
...
PASS: (k) source and binary runtimes keyed separately under one version
...
aot-cache smoke: 15 passed, 0 failed
```

Note: (k) also passed here (it runs the release binary built by the `testbin` target),
whereas the dev-binary `bin/jolt` smoke skips it.

### make devbootsmoke

```
=== (a) cache succeeds for a normal run ===
  PASS: cache marker found in stderr
=== (b) touching rt.ss invalidates cache ===
  PASS: cache not used after rt.ss touch
=== (c) touching seed/prelude.ss invalidates cache ===
  PASS: cache not used after seed touch
=== (d) behavior: source vs cached ===
  PASS: cached and source output match
=== (e) cached project build ===
  PASS: cached build produced a working binary

devboot smoke: 5 passed, 0 failed
```

### make buildsmoke

```
build smoke: passed (release + optimized + direct-link + tree-shake + compiler+core
shake + data-reader + no-main + optional-native + deps-opt + cljc-cond + jolt-ext +
vendored-fs + petite-only-fs + vendored-process + petite-only-process +
declare-only-var + source-mode-driver)
```

### make shakelocal

```
  - progreader-app: ok (output identical; 15473K -> 11274K)
  - multipath-app: ok (output identical; 15470K -> 11271K)
  - dupfqn-app: ok (output identical; 15459K -> 11262K)
shake smoke: passed
```

### make test (full gate)

```
Certifying 4031 corpus rows against JVM Clojure 1.12.5

  certified         3653  (jolt expected == JVM)
  certified-throws   166  (:throws, JVM also throws)
  jvm-error          170  (actual not certifiable on vanilla Clojure)
  read-error           7  (won't read on JVM reader)
  timeout              1  (exceeded 5000ms — infinite/blocking)
  throws-mismatch      1  <-- jolt/JVM disagree on throwing
  DIVERGENT           33  <-- corpus :expected disagrees with JVM

  certifiable rows: 3853  (certified 3819 / divergent 33 / throws-mismatch 1)

  allowlist: 34 entries (0 flaky); 34 of 34 divergences known, 0 NEW, 0 stale
OK: CI gates passed
OK: all gates passed
```

No new divergences. No seed re-mint required.

## 4. Cache performance (cold vs warm)

```
cold=1.45s  warm=1.11s  saved=0.34s (23% faster)
OK: warm faster than cold
```

Warm cache is still substantially faster than cold — the fix does not degrade
cache-hit performance. The one-time miss on first run after the hash change is
expected (different key names), and the old generations are pruned by
`aot-prune-generations!`.

## 5. `flat.ss` load ordering verification

`aot-content-hash` is defined in `host/chez/loader.ss`. Verified all consumers
load `loader.ss` first:

- `build-jolt.ss:41` loads loader.ss, then `:44` loads build.ss. The hash usage
  at `:306` (baked runtime fingerprint) runs after both are loaded.
- `cli.ss:42` loads loader.ss; `cli-tail.ss` loads build.ss later. The `jolt build`
  path through `bld-prepend-prologue!` (`build.ss:1091`) is therefore safe.
- `make-devboot.ss:21` loads loader.ss; the devboot runs `jolt build` which also
  loads build.ss through the cli-tail path. Verified.
- `run-unit.ss:18`, `run-dce-refs.ss:15`, `make-gateboot.ss:35` all load
  `loader.ss` before any use.

No path reaches `build.ss` or `build-jolt.ss` without `loader.ss` loaded. The
shared helper is safe.

## 6. Things noticed but deliberately not touched

- `aot-ns-digest` (loader.ss line ~603) calls `equal-hash` on the cache-key
  string produced by `aot-own-key` (which calls `aot-cache-key`). Since
  `aot-cache-key` now incorporates `aot-content-hash` into the key string,
  the `equal-hash` here is hashing a hex-encoded full-content hash, not the
  original source. This is a hash-of-a-hash and not a defect — the full
  content hash is already folded into the key before `equal-hash` reads it.
  The same applies to the inflight-cycle case at line ~609.

- `host/chez/collections.ss:730` uses `equal-hash` in the generic hash
  dispatch — this is a fallback for non-standard types and unrelated to the
  cache fingerprinting.

- The `host/chez/java/host-class.ss` uses of `equal-hash` are for class-name
  uniquification, not cache keying.

- `host/chez/java/io.ss:27` uses `equal-hash` as a hash function for a
  hashtable constructor, not for cache fingerprinting.

---

## Review addendum

Reviewed on top of the three commits above.

**Fixed — CI-breaking.** The (c2) fixture edited with `sed -i ''`, which is BSD-only.
Verified under GNU sed 4.9 (debian:stable-slim): the `''` is taken as the script and
the `s///` as a filename, sed exits 2, the file is left unedited, and `set -e` aborts
the whole smoke run. `.github/workflows/tests.yml` runs `ubuntu-latest`, so this would
have broken the gate on CI while passing locally on macOS. Replaced with a `gen_c2
<value>` regenerator — no sed, and length-preserving for the same reason the edit was.
Syntax-checked under both BSD sh and dash.

**Fixed — comment overclaim.** The rewritten `aot-cache-key` block ended "FNV-1a and
the length prefix together make that impossible." A 32-bit hash collision between
equal-length sources is remote, not impossible. Restated, since this bug existed
precisely because a comment asserted a safety property that did not hold.

**Verified independently** (not taken from the report above):
- Negative test re-run by the reviewer: reverting only `aot-cache-key` puts (c2) red
  with stale `42`, other 14 green. Confirms the fixture is live *after* the sed rewrite.
- `make test` re-run on the amended tree: OK, 4031 corpus rows, 0 NEW divergences.
- `make aotcacheperf`: cold=1.39s warm=1.08s (22% faster) — cache still hits.
- Section 6's `aot-ns-digest` claim holds, though the margin is narrower than stated:
  it hashes the KEY STRING (12–17 chars for source sizes up to 256MB), and equal-hash
  has full byte coverage through at least 24 chars. Fine, but it is a residual
  dependence on a property of equal-hash — if key formats ever widen, revisit it.
