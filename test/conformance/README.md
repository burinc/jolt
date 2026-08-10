# Conformance: certifying the corpus against reference Clojure

> **See [SPEC.md](SPEC.md)** for the full host-neutral language-spec contract: the
> corpus schema, conformance levels, the feature profile, and how to host jolt on a
> new runtime. This README covers the certification tooling specifically.


The corpus (`test/chez/corpus.edn`) is jolt's host-neutral behavioral suite — one
row per case: `{:suite :label :expected :actual}`, where `:actual` is a Clojure
source expression and `:expected` its result (or `:throws`). The runtime harness
(`host/chez/run-corpus.ss`, invoked by `make corpus`) replays it on Chez and
compares by value-equality.

Every `:expected` is sourced from reference JVM Clojure, so the corpus is both a
regression suite and a *specification* certified against Clojure rather than
against its authors' beliefs. This directory holds the certification tooling that
closes that gap.

## What's here

- **`certify.clj`** — runs every corpus row's `:actual` and `:expected` through
  **reference JVM Clojure** (each in a fresh `user` namespace, output/stdin sunk, a
  5s per-case watchdog) and compares with Clojure's `=`. It buckets each row:
  - `certified` / `certified-throws` — jolt's `:expected` matches real Clojure
  - `divergent` — both evaluate but jolt's `:expected` disagrees with Clojure
  - `throws-mismatch` — `:throws` but Clojure returned a value
  - `jvm-raises` — Clojure ran the row and raised where jolt answers a value; the
    mirror of `throws-mismatch`, and gated the same way
  - `uncertifiable` — Clojure cannot express the row at all (a jolt-only fn, a lib
    off the classpath) — informational, the one bucket the oracle can't judge
  - `expected-error` — the `:expected` *source* doesn't evaluate, so the row
    asserts nothing on either runner — always a corpus bug, gated at zero
  - `read-error` / `timeout` — won't read on the JVM reader, or ran too long

  Each row's forms are read and evaluated one at a time, as a REPL does, and a row
  that fails on a name jolt resolves out of the box (a bare `StringWriter`,
  `clojure.math`) is retried with just that name supplied — resolution is the only
  thing that changes, and the row gets certified for its value instead of being
  written off. `--self-test` checks the classifier itself against one fixture row
  per bucket; `make certify` runs it first.

- **`known-divergences.edn`** — every current divergence, classified. Most are
  **deliberate** jolt-specific or host-model deltas (see `:legend`): the all-double
  numeric model, snapshot-heap concurrency, the no-JVM host model, jolt reader
  features, the jolt printer, intentional strictness. A few are genuine **`:bug`**
  entries with a tracked bead. These categories become the `:features` flags in
  conformance inc3.

`make certify` is the gate wrapper. It skips cleanly when `clojure` (JVM) is not
installed; otherwise it runs `certify.clj` and fails the build on a **NEW**
(unclassified) divergence or a **stale** allowlist entry. Flaky entries (JVM
result is timing-dependent, e.g. `future-cancel`) are tolerated either way.

## Running

```sh
make certify                                                 # the gate wrapper (skips if clojure absent)
clojure -M test/conformance/certify.clj                      # gate directly (exit≠0 on new/stale)
clojure -M test/conformance/certify.clj test/chez/corpus.edn --edn /tmp/report.edn  # full machine-readable report
```

## Current state

Of ~2740 vanilla-certifiable rows, **>2730 match reference Clojure exactly**; the
handful of divergences are all classified (deliberate deltas plus a few tracked
bugs). The corpus is trustworthy as a spec, with the host-specific deltas made
explicit rather than hidden.

## Adding / changing cases

When you add corpus rows or change behavior, re-run the certifier. A NEW divergence
means either a real bug (file it, tag the allowlist entry `:bug` + `:bead`) or a
deliberate delta (classify it). A stale entry means a divergence was fixed — remove
it from `known-divergences.edn`.
