# Embedded Resource Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let compiled Jolt applications enumerate embedded resources and discover them through Migratus-compatible JAR and read-only NIO filesystem APIs.

**Architecture:** The app build marks project/dependency resources as public while runtime-owned embeds stay internal. One virtual archive model backs directory URLs, `JarFile`, and an embedded NIO filesystem; NIO paths retain their filesystem so reads never fall through to same-named host paths.

**Tech Stack:** Chez Scheme host runtime, Clojure/Jolt test fixture, POSIX shell test runner, Make.

**Spec:** `docs/superpowers/specs/2026-10-26-embedded-resource-discovery-design.md`

## Global Constraints

- Public names are sorted vectors containing only application/dependency resources; runtime sources, boots, stubs, FASLs, and build-subsystem entries are excluded.
- Embedded paths use `/`, are rooted at `/`, and are read-only. Never materialize an archive or access a same-named host file.
- Ordinary source roots, real JARs, and default NIO filesystem behavior must remain unchanged.
- Do not add a permanent Migratus dependency; reproduce its host-call sequence in the fixture and optionally run the real library as an additional check.
- Do not run `git commit`; leave all changes in the worktree for user review.

## Review Focus

- Prefix collisions: `migrations/` must match descendants, not `migrations-old/`; test in Task 1's tree model and Task 2's directory URL checks.
- Duplicate/overridden resource names: public enumeration must contain each visible name once; test in Task 1.
- Closed filesystem/archive use: operations must fail rather than resurrect an instance or read the host; test in Tasks 3 and 4.
- Path operations that allocate a new path must preserve embedded identity, including `getParent`, `getFileName`, `resolve`, `normalize`, `subpath`, directory streams, and tree walks; test in Tasks 3 and 4.
- Missing resources and unsupported/mutating operations must use their JVM exception family and must not touch host paths; test in Task 4.

---

### Task 1: Public resource-name registry and fixture

**Files:**
- Modify: `host/chez/java/io.ss:143-150`
- Modify: `host/chez/build.ss:1768-1771`
- Modify: `host/chez/loader.ss:3259-3265`
- Create: `test/chez/embedded-resource-app/deps.edn`
- Create: `test/chez/embedded-resource-app/src/app/core.clj`
- Create: `test/chez/embedded-resource-app/resources/greeting.txt`
- Create: `test/chez/embedded-resource-app/resources-copy/greeting.txt`
- Create: `test/chez/embedded-resource-app/resources/migrations/001-create-users.up.sql`
- Create: `test/chez/embedded-resource-app/resources/migrations/001-create-users.down.sql`
- Create: `test/chez/embedded-resource-app/resources/migrations/nested/002-add-email.up.sql`
- Create: `test/chez/embedded-resource-app/resources/migrations/init.sql`
- Create: `test/chez/embedded-resource-app/resources/migrations-old/ignore.sql`
- Create: `host/chez/embedded-resource-smoke.sh`
- Modify: `Makefile:118-130,183-193`

**Interfaces:**
- Produces: `(register-public-embedded-resource! name content)` registers content and one public name; `(embedded-resource-names)` returns a Scheme list of unique names; Jolt `(jolt.host/embedded-resource-names)` returns a sorted vector.
- The build emitter calls the public registration only for app/dependency resources; existing `register-embedded-resource!` remains internal-only.

- [ ] **Step 1: Write the failing standalone names test**

Configure `:jolt/build {:embed ["resources" "resources-copy"]}`; both directories contain `greeting.txt`, pinning deduplication of a repeated visible name. In `--names` mode print `(jolt.host/embedded-resource-names)`. The shell runner builds the app with `JOLT_BIN="${JOLT_BIN:-target/release/jolt}"`, runs from `/`, and expects exactly:

```clojure
["greeting.txt" "migrations-old/ignore.sql" "migrations/001-create-users.down.sql" "migrations/001-create-users.up.sql" "migrations/init.sql" "migrations/nested/002-add-email.up.sql"]
```

Add `embeddedresources` to the dependency-requiring targets and CI gates.

- [ ] **Step 2: Run the test and confirm the API is absent**

Run: `sh host/chez/embedded-resource-smoke.sh`
Expected: FAIL because `jolt.host/embedded-resource-names` is unbound.

- [ ] **Step 3: Implement public registration and enumeration**

Keep a separate string-keyed public table in `io.ss`, deduplicating repeated registrations. Expose sorted names through `loader.ss`; do not enumerate `embedded-resources` or `embedded-source-index` directly. Change only `bld-emit-embedded-resource` to use public registration.

- [ ] **Step 4: Verify names and internal filtering**

Run: `sh host/chez/embedded-resource-smoke.sh`
Expected: PASS with the exact vector above and no runtime-owned entries.

Run: `make manifestcheck`
Expected: PASS.

### Task 2: Embedded directory URLs and JarFile

**Files:**
- Modify: `host/chez/java/io.ss:151-181,2913-3050`
- Modify: `host/chez/java/zip-file.ss:563-698`
- Modify: `host/chez/java/class-hierarchy.ss:873-890,1460-1480`
- Modify: `test/chez/embedded-resource-app/src/app/core.clj`
- Modify: `host/chez/embedded-resource-smoke.sh`

**Interfaces:**
- Consumes: Task 1 public-name set and embedded contents.
- Produces: `(embedded-directory? name) -> boolean`; `(embedded-archive-url name) -> java.net.URL`; `(make-embedded-jar-file name) -> java.util.jar.JarFile`.
- Stable archive spelling: `jar:file:jolt-embedded-resources.jar!/<entry>`; `jolt-embedded-resources.jar` is a sentinel and is never opened on disk.

- [ ] **Step 1: Write the failing JAR discovery test**

Add `--jar` mode. Resolve `migrations/` through `clojure.lang.RT/baseLoader`, assert protocol `jar`, and assert `.getResources` returns one equal directory URL. Convert the URL using Migratus's `jar-name` logic, construct `java.util.jar.JarFile`, enumerate names, read `migrations/001-create-users.up.sql`, and assert `migrations/` is a directory entry. Assert `migrations` also resolves, `migrations-old/` resolves independently, and `missing/` does not resolve.

- [ ] **Step 2: Run the JAR mode and confirm failure**

Run: `sh host/chez/embedded-resource-smoke.sh --jar`
Expected: FAIL at directory resolution or the missing `JarFile` constructor.

- [ ] **Step 3: Implement the virtual archive surface**

Synthesize directory entries from public-name prefixes with boundary-aware matching. Extend embedded URL behavior for directories without changing exact-file URLs. Add `JarFile` and `JarEntry` class relationships and host methods for `entries`, `getEntry`, `getInputStream`, `size`, `getName`, and idempotent `close`; streams read embedded bytes directly and closed archives reject further operations.

- [ ] **Step 4: Verify JAR behavior and existing ZIP behavior**

Run: `sh host/chez/embedded-resource-smoke.sh --jar`
Expected: PASS, including nested names, SQL contents, prefix boundaries, and closed-archive failure.

Run: `make unit`
Expected: PASS with no real ZIP regressions.

### Task 3: Embedded NIO filesystem lifecycle and path identity

**Files:**
- Create: `host/chez/java/embedded-archive.ss`
- Modify: `host/chez/java/nio-file.ss:104-111,136-188,249-288,377-421`
- Modify: `host/chez/rt.ss:3120-3130`
- Modify runtime manifests in `host/chez/build.ss`, `host/chez/cli.ss`, and `host/chez/bootstrap.ss` to load the new file after `zip-file.ss`
- Modify: `test/chez/embedded-resource-app/src/app/core.clj`
- Modify: `host/chez/embedded-resource-smoke.sh`

**Interfaces:**
- Produces: `(embedded-file-system-new uri)`, `(embedded-file-system-get uri)`, `(embedded-nio-path? path)`, `(embedded-nio-dispatch operation path args)`.
- NIO path state retains `(filesystem . path-string)`; existing `make-nio-path` still creates default-filesystem paths, while `make-nio-path-on` creates a path on a supplied filesystem.

- [ ] **Step 1: Write failing lifecycle and path tests**

Add `--nio` mode covering `FileSystems/newFileSystem` with `jar:file:jolt-embedded-resources.jar`, `getFileSystem`, duplicate-open failure, close/reopen, `/` separator and root directories, read-only/open predicates, and `getPathMatcher`. Assert embedded identity survives `getParent`, `getFileName`, `normalize`, `resolve`, `resolveSibling`, `relativize`, `subpath`, and iteration; same-text paths on different filesystems are not equal. Assert `toUri` identifies the archive entry and `toFile` throws `UnsupportedOperationException`.

- [ ] **Step 2: Run lifecycle tests and confirm failure**

Run: `sh host/chez/embedded-resource-smoke.sh --nio`
Expected: FAIL because `FileSystems/newFileSystem` and `getFileSystem` are absent.

- [ ] **Step 3: Implement filesystem ownership and lifecycle**

Add the focused embedded archive module and manifest entries. Track open instances by the sentinel URI, implement close/reopen semantics, and keep embedded path constructors/operations on their owning filesystem. Preserve all existing default-path results and register `ReadOnlyFileSystemException`/`ClosedFileSystemException` relationships as needed.

- [ ] **Step 4: Verify lifecycle and manifest consistency**

Run: `sh host/chez/embedded-resource-smoke.sh --nio`
Expected: PASS.

Run: `make manifestcheck winpath winplatform`
Expected: PASS.

### Task 4: NIO reads, traversal, attributes, and read-only enforcement

**Files:**
- Modify: `host/chez/java/embedded-archive.ss`
- Modify: `host/chez/java/nio-file.ss:490-805,918-1095,1381-1398,1570-1748`
- Modify: `test/chez/embedded-resource-app/src/app/core.clj`
- Modify: `host/chez/embedded-resource-smoke.sh`

**Interfaces:**
- Consumes: Task 3 embedded path/filesystem identity.
- Produces: embedded implementations behind the existing `Files` statics for `exists`, `notExists`, `isDirectory`, `isRegularFile`, `isReadable`, `isWritable`, `isExecutable`, `isHidden`, `size`, `readAllBytes`, `readAllLines`, `newInputStream`, `readAttributes`, `getAttribute`, `newDirectoryStream`, `walkFileTree`, `isSameFile`, and `copy(Path, OutputStream)`.

- [ ] **Step 1: Write failing read/traversal/read-only tests**

Add `--nio-read` mode. Assert root/directory/file existence and types, SQL bytes/lines/stream contents, sorted immediate children, glob and filter directory streams, nested tree walking with visitor results, basic attributes, same-file behavior, and copy to `ByteArrayOutputStream`. Cover missing files, a file used as a directory, closed-filesystem reads, and zero timestamps/nil file keys. For every existing mutating `Files` operation, assert `ReadOnlyFileSystemException`; for unimplemented embedded operations assert `UnsupportedOperationException`, with a colliding host path present to prove no fallback occurs.

- [ ] **Step 2: Run reads and confirm host-path behavior fails**

Run: `sh host/chez/embedded-resource-smoke.sh --nio-read`
Expected: FAIL because embedded paths currently reach host-file operations or unsupported statics.

- [ ] **Step 3: Implement provider dispatch**

Route each listed operation through `embedded-nio-dispatch` when its path belongs to the embedded provider; otherwise retain the current host implementation. Synthesize attributes and sorted children from the public tree, read bytes lazily, preserve paths during traversal, and reject every mutation before host-path conversion.

- [ ] **Step 4: Verify embedded and default NIO suites**

Run: `sh host/chez/embedded-resource-smoke.sh --nio-read`
Expected: PASS.

Run: `make unit libconformance LIBS="fs"`
Expected: PASS; the external library suite may report its documented skip when `../conformance-libraries/fs` is unavailable, which must be reported rather than counted as executed coverage.

### Task 5: Migratus call-sequence acceptance and documentation

**Files:**
- Modify: `test/chez/embedded-resource-app/src/app/core.clj`
- Modify: `host/chez/embedded-resource-smoke.sh`
- Modify: `README.md:590-624`

**Interfaces:**
- Consumes: all prior public surfaces without Jolt-specific calls in the migration scanner itself.

- [ ] **Step 1: Write the failing Migratus acceptance mode**

Add `--migratus` mode mirroring Migratus: system classloader directory lookup, `jar-file`, `find-migration-resources`, and `script-excluded?` using `FileSystems/getFileSystem`, `newFileSystem`, `getPath`, and `getPathMatcher`. Assert both numbered up/down migrations and the nested migration are read, while `init.sql` and `migrations-old/ignore.sql` are excluded.

- [ ] **Step 2: Run acceptance before any missing compatibility fix**

Run: `sh host/chez/embedded-resource-smoke.sh --migratus`
Expected: FAIL if any host call in the real sequence remains unsupported; investigate the failing boundary rather than special-casing the fixture.

- [ ] **Step 3: Complete the compatibility path and document it**

Implement only the missing runtime behavior exposed by the acceptance failure. Document sorted `jolt.host/embedded-resource-names`, a migration filtering example, and the read-only JAR/NIO discovery support.

- [ ] **Step 4: Run the complete feature acceptance**

Run: `sh host/chez/embedded-resource-smoke.sh`
Expected: all modes PASS from a neutral working directory.

If network/dependency resolution permits, run real Migratus `find-migrations` against the built app as an additional check; record any unrelated missing library capability separately rather than claiming that check ran.

### Task 6: Seed regeneration and full verification

**Files:**
- Regenerate: `host/chez/seed/prelude.ss`, `host/chez/seed/image.ss`, `host/gambit/seed/prelude.ss`, `host/gambit/seed/image.ss`
- Modify only if verification reveals stale generated/runtime expectations.

- [ ] **Step 1: Regenerate both seeds**

Run: `make remint`
Expected: command completes and generated seed changes correspond to the runtime source changes.

- [ ] **Step 2: Rebuild the release driver and rerun feature tests**

Run: `make jolt-release && JOLT_BIN=target/release/jolt sh host/chez/embedded-resource-smoke.sh`
Expected: build succeeds and every feature mode passes using the regenerated runtime.

- [ ] **Step 3: Run focused regression gates**

Run: `make smoke unit buildsmoke manifestcheck readmecheck gambitseedcheck`
Expected: all targets PASS. `buildsmoke` must use the standard `JOLT_BIN=target/release/jolt` default.

- [ ] **Step 4: Run the full standard gate**

Run: `make test`
Expected: the final verdict is PASS and a gate receipt is written. If unavailable dependencies cause skips, report them explicitly; compare failures with the clean baseline instead of suppressing them.

- [ ] **Step 5: Review the final diff**

Run: `git status --short && git diff --stat && git diff --check`
Expected: only intended source, fixture, documentation, plan, and generated seed changes; no whitespace errors. Check the final public behavior against issue #1438 and the approved spec before reporting completion.
