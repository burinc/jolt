# Jolt

[![tests](https://github.com/jolt-lang/jolt/actions/workflows/tests.yml/badge.svg)](https://github.com/jolt-lang/jolt/actions/workflows/tests.yml)

A Clojure implementation on Scheme. Jolt reads Clojure source, analyzes it to a
host-neutral IR, emits Scheme, and runs it — on [Chez](https://cisco.github.io/ChezScheme/)
by default, or on [Gambit](https://gambitscheme.org/) compiled to JavaScript for
the browser. The compiler is self-hosted: it is written in Clojure (`jolt-core/`)
and compiles itself. It ships a Clojure-compatible standard library.

## Requirements

The prebuilt binaries are self-contained (runtime, compiler, and stdlib in one
executable) and need only the base system libraries:

- **Linux x86_64**: glibc 2.35 or newer (Ubuntu 22.04+, Debian 12+, RHEL 9+).
  The installer verifies the binary runs and reports the exact glibc mismatch
  if not.
- **macOS arm64**: macOS 14+.
- Anything else (Intel Mac, musl/Alpine, older glibc): build from source.

`make build` provisions [Chez Scheme](https://cisco.github.io/ChezScheme/) and a
C compiler locally through [Makes](https://github.com/makeplus/makes), then
builds the standalone binary. An explicit `CHEZ=/path/to/chez` (or
`CHEZSCHEME=/path/to/scheme`) is authoritative and bypasses local provisioning;
release builders use this to retain their threaded Chez and platform toolchain.
The conformance gate additionally uses Clojure on the JVM as an optional oracle,
but running jolt does not.

### Dependency resolution

Resolving a project's `deps.edn` uses a few standard tools, each needed only for
the coordinate types you use — a dependency that can't be fetched is skipped, never
fatal:

- **Git deps** (`:git/url` + `:git/sha`) need `git` on `PATH`. `:git/url` may be
  omitted when the lib name encodes a host, as in tools.deps — e.g.
  `io.github.OWNER/REPO` clones from GitHub.
- **Maven deps** (`:mvn/version`) are downloaded over HTTPS by jolt itself (no
  `curl`), using the system **OpenSSL** (`libssl`/`libcrypto`) via FFI, and
  extracted with `unzip`. Jolt embeds [Grenadine](https://github.com/clojurestar/grenadine)
  to build effective POMs and resolve transitive dependencies without Java. A
  jar already in `~/.m2/repository` is reused with no download. Set
  `GRENADINE_LOCAL_REPOSITORY` to use another repository; an explicit
  `:mvn/local-repo` takes precedence, and `JOLT_LOCAL_REPO` remains supported as
  a legacy fallback.
  - **macOS**: `brew install openssl@3` — jolt loads the Homebrew copy; the
    protected system `/usr/lib` OpenSSL can't be loaded into a non-Apple binary.
    `git`/`unzip` come with the Xcode command-line tools.
  - **Linux**: the distro `libssl3`/`libcrypto3` (or `libssl`/`libcrypto`) packages,
    plus `git` and `unzip`.
  - **Windows**: [Git for Windows](https://git-scm.com/download/win) supplies `git`,
    the OpenSSL DLLs (`libssl-3-x64.dll`/`libcrypto-3-x64.dll`), and `unzip`; run
    `jolt` from a shell with those on `PATH`.

## Install

**If you are using an Intel Mac, musl/Alpine, or an older glibc, the prebuilt
binaries below are not supported. Build from source instead — see
[Build](#build).**

Grab the self-contained `jolt` binary (Linux/macOS/Windows) — it bundles the
runtime, compiler, and standard library, so there is nothing else to install.
Download the binary archive for your platform from the
[releases page](https://github.com/jolt-lang/jolt/releases) (`jolt-<ver>-<platform>.tar.gz`,
or the `.zip` on Windows). The "Source code" archives GitHub attaches to every
release are not binaries — see [Build](#build) before using one.

With Homebrew:

```bash
brew install jolt-lang/jolt/jolt
```

Or with the install script (installs to `/usr/local/bin` by default; `--dir <dir>`
and `--version <v>` override that):

```bash
curl -sL https://raw.githubusercontent.com/jolt-lang/jolt/main/install | bash
```

Then `jolt -e '(+ 1 2)'`. To run from source instead (needs Chez), see
[Build](#build).

## Build

Running from source has no build step. The bootstrap seed
(`host/chez/seed/{prelude,image}.ss`) is checked in, so a fresh clone runs
immediately:

```bash
git clone --recurse-submodules https://github.com/jolt-lang/jolt.git
cd jolt
bin/jolt -e '(+ 1 2)'        # => 3
```

The `--recurse-submodules` matters: jolt vendors its regex engine, its Maven
resolver, and its test suites as git submodules. In a checkout that's missing
them (a plain `git clone`, or after pulling a commit that adds one), fetch them
with:

```bash
git submodule update --init --recursive
```

`bin/jolt` needs a **threaded Chez Scheme 10.x** on `PATH` as `chez` or
`chezscheme`; set `JOLT_CHEZ` to point at a specific one. `make` provisions its
own 10.4.1 when `PATH` has a different version, and exports `JOLT_CHEZ` so both
halves of a build agree — running `bin/jolt` by hand against a 9.x picks up
whatever primitive that release predates (`variable flvector? is not bound`).

Note that GitHub's auto-generated "Source code (zip/tar.gz)" archives on the
releases page do **not** contain submodules, so they can't run or build —
clone the repo instead (or grab a prebuilt binary from the same page).

After changing a compiler source — the reader (`host/chez/reader.ss`), the
analyzer/IR/backend (`jolt-core/jolt/*.clj`), or the `clojure.core` overlay
(`jolt-core/clojure/core/*.clj`) — re-mint the seed:

```bash
make remint                   # iterates host/chez/bootstrap.ss to a byte-fixpoint
```

## Run

```bash
bin/jolt -e EXPR             # evaluate a Clojure expression and print the result
```

```bash
$ bin/jolt -e '(->> (range 10) (filter even?) (map (fn [x] (* x x))) (reduce +))'
120
$ bin/jolt -e '(/ 1 2)'
1/2
```

When the current directory has a `deps.edn`, `-e` resolves it first, so the
expression can require the project's own namespaces and its dependencies.
`-Sdeps` and `-A` compose with it for a one-off evaluation, and `-M` takes the
same main options on the command line when the selected aliases declare none:

```bash
bin/jolt -Sdeps '{:paths ["src" "test"]}' -e "(require 'my.app-test 'clojure.test)
                                              (clojure.test/run-tests 'my.app-test)"
bin/jolt -A:test -M -e "(println :hi)"
```

## Diagnostics

- **"Did you mean?"** — when a bare symbol doesn't resolve, the compile error lists
  the closest in-scope names by edit distance (current-namespace vars,
  `clojure.core` publics, and lexical locals):
  ```
  $ bin/jolt -e '(prinltn 1)'
  Unable to resolve symbol: prinltn in this context (did you mean print, printf, println?)
  ```
- **`JOLT_DIAG=edn`** — emit an uncaught error as a single line of valid EDN to
  stderr (with `:message` and source `:line`/`:column`/`:file`; an unresolved
  symbol also carries `:type`/`:symbol`/`:suggestions`/`:ns`) so an editor or tool
  can read it back. Default output is unchanged.
  ```
  $ JOLT_DIAG=edn bin/jolt -e '(prinltn 1)'
  {:type :unresolved-symbol, :symbol "prinltn", :suggestions ["print" "printf" "println"], :ns "user", :message "...", :line 1, :column 2, :file "-e"}
  ```
- **`JOLT_CHECK`** — opt-in success-type lint (RFC 0006): each runtime-compiled form
  is run through the checker and findings print as located warnings, e.g.
  `1:10: warning: `+` requires a number, but argument 2 is a keyword`. Off by
  default (zero cost); a checker error never breaks a compile.
- **`JOLT_DEBUG`** — verbose dependency resolution (the fetching / using-cache /
  skipping lines that are otherwise quiet) and the host static-shim drift warning.

## REPL and editor integration

```bash
bin/jolt repl                  # a line REPL with the project's deps loaded
bin/jolt nrepl-server [port]   # an nREPL server (default 7888) for editors
```

Both resolve the `deps.edn` in the current directory first, so the project's
source roots and native libraries are loaded — `(require '[my.ns])` works live.
`nrepl-server` writes a `.nrepl-port` file in the project dir, so CIDER / Calva / Cursive
auto-detect the port; override it with the argument or `JOLT_NREPL_PORT`.

The server runs in dev mode — calls deref their var, so redefining a function
takes effect on the next call without restarting the process. The built-in
handler speaks `clone`/`describe`/`eval`/`load-file`/`close`; everything past
that is nREPL middleware, listed in `deps.edn` under `:nrepl/middleware`.
[jolt-lang/nrepl](https://github.com/jolt-lang/nrepl) supplies both layers —
sessions and interruptible eval, plus the cider-nrepl ops an editor expects
(`info`, `complete`, the namespace browser, tests, error analysis):

```clojure
{:deps {jolt-lang/nrepl {:git/url "https://github.com/jolt-lang/nrepl"
                         :git/sha "<full-sha>"}}
 :nrepl/middleware [nrepl.middleware/default-middleware
                    cider.nrepl/cider-middleware]}
```

```clojure
;; from your editor, against the running process:
(require '[myapp.core :as app])
(app/start!)                  ; bring the app up
;; edit a handler, re-evaluate the defn — the running app sees it, no restart
(app/stop!)
```

Editors also ask for the classpath before connecting; `-Spath` answers it, on
either side of the alias options, and an alias the project doesn't declare is
skipped with a warning rather than failing the query:

```bash
bin/jolt -A:test:dev -Spath    # the source roots :test and :dev resolve to
bin/jolt -Spath -M:test        # same, for the aliases a -M/-X/-T run would use
```

The rest of the `clj` option surface works the same way — each takes the aliases
around it and runs no program:

```bash
bin/jolt -Stree                # the dependency tree, tools.deps format
bin/jolt -Strace               # write the expansion decisions to trace.edn
bin/jolt -Sdescribe            # version, deps.edn chain, and caches, as edn
bin/jolt -P                    # fetch every dependency, then stop (CI, images)
bin/jolt -Srepro …             # ignore ~/.clojure/deps.edn for this run
bin/jolt -Sverbose …           # say where deps are read from and fetched into
```

`-Scp` runs against source roots you supply instead of the ones the
dependencies resolve to, expanding nothing — so a classpath recorded once
drives later runs with no fetching:

```bash
bin/jolt -Spath > cp.txt
bin/jolt -Scp "$(cat cp.txt)" -M:test     # offline; nothing is expanded
```

The deps.edn is still read under `-Scp`, so aliases, `:main-opts` and tasks
work; what's skipped is the dependency expansion, and with it any shared
library a *dependency* declares (the project's own `:jolt/native` still loads).

`-Sforce`, `-Sthreads`, and `-Jopt` are accepted and ignored: jolt resolves its
roots on every run, so there is no classpath cache to force, it fetches
serially, and there is no JVM to pass options to.

## Compile a binary

`bin/jolt build` ahead-of-time compiles a project into a single self-contained
executable — the runtime, `clojure.core`, the standard library, the app, and its
`deps.edn` dependencies are linked in, so the result needs no Chez install, no
JVM, and no source on disk to run.

```bash
bin/jolt build -m myapp.core -o myapp   # compile myapp.core's -main into ./myapp
./myapp arg1 arg2                        # runs anywhere; args reach -main
```

Modes trade dynamism for speed: the default (release) build uses the proven code
generator; `--opt` also runs the inference + inlining + scalar-replacement passes
over the closed-world program; `--dev` is unoptimized.

Numeric code unboxes to raw flonum/fixnum machine ops when types are proven —
by whole-program inference (float literals, record fields, protocol returns:
no annotations needed), by JVM-style `^double`/`^long` hints, or by
`(double x)`/`(long x)` casts where inference can't see. See
[Building & Running](https://jolt-lang.github.io/docs/building-and-deps.html#typed-arithmetic-and-inference).

Two opt-in closed-world flags cut dispatch cost and binary size:

```bash
bin/jolt build -m myapp.core --direct-link   # app->app calls bind directly (no var lookup)
bin/jolt build -m myapp.core --tree-shake    # ship only code reachable from -main
```

`--tree-shake` walks the call graph across your app, its libraries, and
`clojure.core`, drops everything unreachable from `-main` (and the compiler itself
when the app never `eval`s), and typically removes 1–2 MB. It stays sound by bailing
out — keeping everything, and reporting which library is responsible — when reachable
code resolves vars by name at runtime (`eval`/`resolve`/`ns-resolve`/…). See
[deps.edn internals](https://jolt-lang.github.io/docs/tools-deps.html) and [RFC 0007](https://jolt-lang.github.io/docs/rfc/0007-compilation-modes-and-binary-output.html).

Built executables contain an optional startup profiler. Set
`JOLT_STARTUP_PROFILE=1` when launching one to write per-stage wall time,
process CPU time, collection counts, reclaimed bytes, and current heap size to
standard error. Markers cover the native boot loader, Jolt runtime files, each
application namespace, and `-main`; normal launches leave the profiler disabled
and silent.

```bash
JOLT_STARTUP_PROFILE=1 ./myapp arg1 arg2
```

This needs Chez's kernel development files (`libkernel.a`, `scheme.h`) and a C
compiler. They come with a from-source Chez install; a distro `chezscheme`
package ships only the runtime, so `build` won't link a binary there.
[RFC 0007](https://jolt-lang.github.io/docs/rfc/0007-compilation-modes-and-binary-output.html) covers the design and the three-mode model.

## Compile a library

`bin/jolt build --library` compiles a project into a shared object
(`.so`/`.dylib`/`.dll`) that a C/C++/Rust host links or `dlopen`s and calls
through a small C ABI. Like `build`, the whole runtime is embedded — the result
is a *managed-runtime* library: it carries its own GC and must be entered
through `jolt_library_init` before any call.

The Jolt side publishes entry points with `jolt.ffi/export!`:

```clojure
(ns libadd.core
  (:require [jolt.ffi :as ffi]))

(defn add [x y] (+ x y))
(ffi/export! "add" add [:int :int] :int)
```

```bash
bin/jolt build --library -m libadd.core -o libadd   # => libadd.so / libadd.dylib
```

The C side calls `jolt_library_init` once, then resolves each entry by name with
`jolt_lookup` and casts to its type:

```c
#include <dlfcn.h>
typedef int (*init_fn)(int, char**);
typedef void* (*lookup_fn)(const char*);
typedef int (*add_fn)(int, int);

void* h = dlopen("./libadd.so", RTLD_NOW | RTLD_LOCAL);
((init_fn)dlsym(h, "jolt_library_init"))(0, NULL);        /* runs top-level, registers exports */
add_fn add = (add_fn)((lookup_fn)dlsym(h, "jolt_lookup"))("add");
add(2, 3);                                                 /* => 5 */
```

The type keywords (`:int`, `:string`, …) are the same ones `foreign-fn` uses;
see [Host Interop](https://jolt-lang.github.io/docs/host-interop.html) for the full list and limits.
The same `--opt`/`--dev`/`--direct-link`/`--tree-shake` flags apply, and the
same Chez kernel development files + C compiler are required to link.

## Standalone jolt binary

`make` (or `make build`) installs the build dependencies locally through Makes
and builds jolt itself into a single self-contained native binary. The runtime,
compiler, `jolt-core`/`stdlib` source, and the Chez boots are baked in, so the
result runs and `build`s jolt apps on a machine with neither Chez nor a C
compiler.

```bash
make build                    # => target/release/jolt (optimize-level 3, compressed)
make install                  # => ~/.local/bin/jolt, or /usr/local/bin/jolt as root
make install PREFIX=/opt/jolt # explicitly override the installation prefix
make jolt-release             # force-rebuild the release binary
make jolt-debug               # => target/debug/jolt   (optimize-level 0, inspector + debug info)
make jolt                     # re-mint the seed first, then both
```

`make jolt` re-mints the seed so the embedded compiler image is current before
linking; `jolt-release`/`jolt-debug` force their respective builds without
re-minting. `make clean` removes build products; `make distclean` also removes
the locally provisioned Makes toolchain.

## Architecture

A small Chez runtime (`host/chez/*.ss`: value model, persistent collections, seqs,
vars/namespaces, host interop) hosts a portable Clojure overlay split across two
source roots by *when* they load:

- **`jolt-core/`** is baked into the seed — the compiler (`jolt-core/jolt/`:
  reader/analyzer/IR/backend, plus `jolt.main`/`jolt.deps`) and `clojure.core` in
  dependency-ordered tiers (`jolt-core/clojure/core/NN-*.clj`). Changing anything
  here means re-minting the seed.
- **`stdlib/`** loads lazily at runtime off the source roots — the rest of the
  standard library (`clojure.string`/`set`/`walk`/`edn`/`pprint`/…) plus the
  `jolt.ffi` host library. Editing these needs no re-mint.

`bin/jolt` loads the checked-in seed and the spine, then compiles and evaluates on
Chez (read → analyze → IR → emit → eval). `host/chez/bootstrap.ss` rebuilds that
seed from source on pure Chez; the build is a self-hosting fixpoint (a rebuild
reproduces the checked-in seed byte-for-byte).

`host/gambit/` is the same overlay on a second Scheme — its own adapter, kernel,
and cross-minted seed. See [Scheme backends](#scheme-backends).

## Scheme backends

Chez is the default target: every gate, library, and release runs there, and it
is the only target with FFI, native compilation, program images, and standalone
binaries. Gambit is a second, demo-grade target that also compiles to a single
JavaScript file — the live REPL on the [website](https://jolt-lang.github.io) is
jolt evaluating in the browser.

Host-specific runtime code sits behind an adapter contract
(`host/scheme-adapter/CONTRACT.txt` lists the names and capability tiers;
`TARGET-CONTRACT.md` next to it is the porting document). A target implements a
capability or degrades it honestly — an absent one raises rather than faking a
result.

The Gambit targets need `gambit-scheme` (brew) and skip cleanly without it:

```bash
make gambitcheck              # adapter + shims on native gsi
make gambitkernel             # the booted kernel and natives (113 checks)
make gambiteval               # jolt source through the compiler, renders pinned to Chez
make gambitseed               # re-mint host/gambit/seed/ (runs on Chez, after a seed change)
make gambitweb                # => target/gambit/jolt-web.js, the browser bundle
make gambitweb PROFILE=repl   # a smaller bundle (see Build profiles below)
make gambitprofile            # gate: reduced profile runs, excluded features report
```

`make gambitweb` compiles the whole stack — kernel, seed, compiler, and a
queue-polling REPL loop (`host/gambit/repl-main.ss`) — into one self-contained
JavaScript file in about 30 seconds. The build is reproducible: the same sources
produce a byte-identical bundle. Point it at a site checkout to refresh the live
demo:

```bash
make gambitweb GAMBIT_WEB_OUT=../jolt-lang.github.io/resources/static/js/jolt-web.js
```

### Build profiles

`PROFILE` selects how much of the language a build carries.
`host/gambit/profiles.ss` lists the profiles and the optional feature groups
they are built from; `boot.ss` remains the source of load order, and a group only
names which of its files are optional.

```bash
make gambitweb PROFILE=repl    # clojure.core + compiler, no regex
make gambitweb PROFILE=full    # everything (the default)
```

Excluding a group does two things. Its files are left out, and **every name it
owned is bound to a raise that names the group** — derived by scanning the
excluded files for their definitions, so the error surface tracks the code
instead of a hand-kept list. A dropped feature reports itself:

```
user=> (re-seq #"[a-z]+" "ab cd")
java.lang.UnsupportedOperationException: jolt-re-pattern is not in this build:
the regex feature group was excluded
```

A predicate over a type the build cannot hold answers `false` rather than
raising — a value simply is not a regex — while anything that would produce or
consume that type raises. `make gambitprofile` gates both halves: the reduced
profile still runs the language, and an excluded feature names its group,
including through indirection like `clojure.string/split`.

Measured cost of each group in the bundle (raw / gzipped, and gzipped is what a
web server ships):

| group | cost | without it |
|---|---|---|
| regex | 2.4 MB / 0.4 MB | no `re-*`, no `#"..."` |
| compiler | 2.9 MB / 0.5 MB | no `eval`, no REPL, no runtime macros |
| clojure.core | 8.7 MB / 0.7 MB | the kernel alone — an embedding, not a Clojure |
| **kernel (floor)** | **19.4 MB / 2.1 MB** | the Gambit runtime plus jolt's kernel |
| full | 31.0 MB / 3.3 MB | |

The floor dominates, so a profile trades features for the last third of the
bundle: `repl` ships 27.7 MB / 3.1 MB against `full`'s 32.6 MB / 3.5 MB. Adding
a group is worth it when it is separable *and* measurable — a group worth
kilobytes is churn.

The page defines `joltQueue` and `joltOut` before loading the bundle; a Scheme
thread inside it polls the queue and hands results back, so page JavaScript never
calls into Scheme.

## Differences from Clojure

Jolt targets Clojure semantics but runs on Chez, not the JVM. Most portable
Clojure runs unchanged — persistent collections (32-way-trie vectors, HAMT
maps/sets), the numeric tower (exact integers, bignums, ratios, doubles,
`BigDecimal` with `M` literals and `with-precision`), lazy
and infinite sequences, transducers, destructuring, multimethods with
hierarchies, protocols/records (`deftype`/`defrecord`/`reify`/`extend-protocol`),
metadata, namespaces, atoms, refs/STM (`ref`/`dosync`/`alter`/`commute`),
`future`/`promise`/`agent`/`pmap`,
`clojure.core.async`, runtime `eval`/`load-string`/`defmacro`, and the full
reader (`#()`, `#_`, `#?`, tagged literals, `#"…"`) all behave as on the JVM.
`=` is category-aware (`(= 3 3.0)` ⇒ `false`) and `==` is value-equality, as in
Clojure. The genuine divergences:

- **No JVM, no Java interop.** No reflection, no `gen-class`/`proxy`. Interop
  syntax (`Class.`, `Class/static`, `.method`) resolves only against a shimmed
  subset of the `java.*` standard library; a class token is a name, not a loaded
  class. See [Host Interop](https://jolt-lang.github.io/docs/host-interop.html). To call C libraries
  directly, use the `jolt.ffi` foreign-function interface (how the db and
  http-client libraries bind SQLite/libpq and sockets/OpenSSL/zlib).
- **Codepoint strings.** Strings are Chez strings — codepoint-indexed, no
  UTF-16 surrogate pairs. `(count "😀")` is 1 (JVM: 2) and `subs` never splits
  a character; only code doing UTF-16 unit arithmetic notices.
- **Regex engine.** Patterns compile through
  [irregex](https://github.com/ashinn/irregex) (vendored), not
  `java.util.regex`; common patterns work, Java-specific features can differ.
- **Coverage.** `clojure.core` is implemented function by function against the
  JVM-sourced conformance corpus — broad but not total; a namespace can load with
  most functions working and a few not yet implemented.
- **A `.jolt` extension.** A namespace's source can be `foo.jolt` as well as
  `foo.clj` or `foo.cljc`, and the three are the same language: the reader,
  analyzer, and emitter never look at the extension. `.jolt` is a marker for
  readers and tooling, saying the file uses jolt-specific interop and is not
  portable Clojure. It resolves first, so a library can ship a portable
  `foo.cljc` next to a `foo.jolt` that wins on jolt, the way `.clj` wins over
  `.cljc` on the JVM. `data_readers.jolt` works like `data_readers.clj` too.

## Test

```bash
make test                     # the full gate
make corpus                   # conformance corpus vs the JVM-sourced spec
make unit                     # host-specific unit cases
make selfhost                 # bootstrap fixpoint (rebuild == checked-in seed)
make smoke                    # bin/jolt CLI smoke
make sci                      # load borkdude/sci's source through jolt (compat stress)
make ffi                      # HTTP-server GC-safety + http-client temp paths
make transient                # transient mutation + linear-time builds
make certify                  # JVM oracle (skips if clojure is absent)
```

The conformance corpus (`test/chez/corpus.edn`) is a host-neutral language spec
whose expected values are sourced from reference JVM Clojure. See
[test/conformance/SPEC.md](test/conformance/SPEC.md).

## License

[Eclipse Public License 2.0](https://www.eclipse.org/legal/epl-2.0/)
