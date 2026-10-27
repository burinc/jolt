# Exhaustive Embedded-Resource Java Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete every public operation on embedded URL/JAR/NIO values and every `Files` operation accepting embedded paths, with JVM-compatible reads and deliberate read-only/capability failures.

**Architecture:** Keep one public-resource archive and route every embedded representation to it. Add focused URL-connection and manifest modules, complete archive and NIO provider methods, and audit the public surface with a method matrix and JDK-oracle examples instead of relying on Migratus coverage.

**Tech Stack:** Chez Scheme, Clojure/Jolt standalone fixtures, shell, JDK `javap`/JVM oracle, Make.

**Spec:** `docs/superpowers/specs/2026-10-26-embedded-resource-java-compatibility-design.md`

## Global Constraints

- Exhaustive means every public instance operation on embedded values and every `Files` static accepting embedded paths works or returns a deliberate JVM-family result; accidental method misses and host fallbacks are defects.
- The sentinel and embedded paths are never opened as host paths. Exact-file bare-name URLs remain backward compatible.
- Embedded mutations reject with `ReadOnlyFileSystemException`; embedded-to-host copy and cross-provider mismatch are supported, while embedded moves reject.
- Multi-release selection follows JDK 21 rules against entries actually present.
- Do not run `git commit`; leave all work in the existing worktree.

## Review Focus

- Binary and Unicode content, including NUL/invalid UTF-8 and manifest continuation lines: assert bytes and decoded values independently in Tasks 1, 2, and 4.
- Version boundaries and absent variants: test base, below-9, 9, 17, above-17, and non-multi-release archives in Task 2.
- Closed/consumed values: test connection/archive/filesystem/channel/stream lifecycle and second-use failures in Tasks 1–4.
- Cross-provider and relative operations: test embedded/host copy and mismatch plus relative list/walk/find shapes in Task 4; embedded destinations/moves reject.
- Absent metadata: test nil versus empty collections/arrays, zero timestamps, absent manifest/attributes/signers/certificates, and unknown headers in Tasks 1–3.

---

### Task 1: URL and JarURLConnection completion

**Files:**
- Create: `host/chez/java/embedded-url.ss`
- Modify: `host/chez/java/io.ss`
- Modify: `host/chez/java/class-hierarchy.ss`
- Modify: `host/chez/rt.ss`
- Modify: `test/chez/embedded-resource-app/src/app/core.clj`
- Modify: `host/chez/embedded-resource-smoke.sh`
- Create: `docs/embedded-resource-compatibility.md`

**Interfaces:**
- Produces: `(embedded-url-open-connection resource)` returning a connection; `(embedded-jar-url-entry-name resource)`, `(embedded-jar-file-url)`, and `(embedded-jar-manifest archive)` shared with Task 2.
- Task 1's manifest helper answers nil when `META-INF/MANIFEST.MF` is absent; Task 2 replaces it with full parsing.
- `embedded-res-method` delegates `openConnection` without changing exact-file URL spelling.

- [ ] **Step 1: Write the failing URL matrix tests**

Add `--url` mode covering every public URL/URLConnection/JarURLConnection instance method from the spec: accessors, equality/hash/sameFile, `toURI`, both `openConnection` forms, content/streams, metadata/headers, timeouts, flags, cache/request state, permission, archive/entry/manifest access, attributes, and certificates. Include absent headers, zero metadata, binary content, directory entries, missing entries, output rejection, and closed archive behavior. Start the matrix with URL rows and expected outcomes.

- [ ] **Step 2: Run the URL mode and confirm missing behavior**

Run: `sh host/chez/embedded-resource-smoke.sh --url`
Expected: FAIL at `openConnection` or a missing connection method, not at test syntax.

- [ ] **Step 3: Implement embedded connection values**

Add the focused module and class registrations. Reuse existing byte streams, filename mapping, and archive helpers. Implement all URL/connection rows, with zero timestamps, empty headers, input defaults, output rejection, and no host access.

- [ ] **Step 4: Verify URL and prior modes**

Run: `sh host/chez/embedded-resource-smoke.sh --url && sh host/chez/embedded-resource-smoke.sh --jar`
Expected: PASS, including all URL matrix rows and existing archive behavior.

### Task 2: ZIP/JAR, manifests, and multi-release selection

**Files:**
- Create: `host/chez/java/embedded-manifest.ss`
- Modify: `host/chez/java/zip-file.ss`
- Modify: `host/chez/java/zip-entries.ss`
- Modify: `host/chez/java/class-hierarchy.ss`
- Modify: `host/chez/rt.ss`
- Create: `test/chez/embedded-resource-app/resources/META-INF/MANIFEST.MF`
- Create: `test/chez/embedded-resource-app/resources/META-INF/versions/9/greeting.txt`
- Create: `test/chez/embedded-resource-app/resources/META-INF/versions/17/greeting.txt`
- Modify: `test/chez/embedded-resource-app/src/app/core.clj`
- Modify: `host/chez/embedded-resource-smoke.sh`
- Modify: `docs/embedded-resource-compatibility.md`

**Interfaces:**
- Consumes: Task 1 archive URL helpers and absent-manifest helper, which this task completes.
- Produces: `(embedded-jar-entry archive name)`, `(embedded-jar-manifest archive)`, `(embedded-jar-version archive)`, and `(embedded-jar-versioned-entries archive)` used by URL/JAR and version tests.

- [ ] **Step 1: Write the failing archive and manifest matrix**

Add `--jar-full` mode covering every ZipEntry/JarEntry and ZipFile/JarFile instance method, every constructor shape, clone/equality behavior, stream/versionedStream, attributes/certificates/signers, manifest parsing/writing/copying, `Attributes`/`Attributes.Name` map semantics, Unicode continuations, and absent metadata. Pin base, below-9, 9, 17, above-17, and non-multi-release selection with JDK 21 expected values. Update earlier name/count assertions for the new manifest/version fixtures.

- [ ] **Step 2: Run archive tests and confirm missing behavior**

Run: `sh host/chez/embedded-resource-smoke.sh --jar-full`
Expected: FAIL at missing JAR/manifest methods or incorrect multi-release selection.

- [ ] **Step 3: Implement archive and manifest completion**

Add manifest/attributes values and parser/writer, full entry/archive methods, stream views, version-aware lookup/enumeration, and constructor validation. Reuse existing real-ZIP behavior unchanged.

- [ ] **Step 4: Verify archive and ZIP regression suites**

Run: `sh host/chez/embedded-resource-smoke.sh --jar-full && make unit`
Expected: PASS, including all matrix rows and existing `8/8 zip`.

### Task 3: Path, FileSystem, FileStore, and provider completion

**Files:**
- Modify: `host/chez/java/embedded-archive.ss`
- Modify: `host/chez/java/nio-file.ss`
- Modify: `host/chez/java/class-hierarchy.ss`
- Modify: `test/chez/embedded-resource-app/src/app/core.clj`
- Modify: `host/chez/embedded-resource-smoke.sh`
- Modify: `docs/embedded-resource-compatibility.md`

**Interfaces:**
- Produces: `(embedded-file-system-provider fs)`, `(embedded-file-store path)`, `(embedded-basic-attribute-view path)`, and `(embedded-watch-service fs)` with deliberate quiet-watch behavior.

- [ ] **Step 1: Write the failing filesystem matrix**

Add `--fs-full` mode covering every Path and FileSystem method and overload plus the FileSystemProvider read/write surface: string overloads, watch registration/service lifecycle, provider scheme, file stores/capacity metadata, supported views, principal lookup, basic attribute views, provider input/output/channel/copy/access operations, and closed values or absent metadata.

- [ ] **Step 2: Run filesystem tests and confirm missing behavior**

Run: `sh host/chez/embedded-resource-smoke.sh --fs-full`
Expected: FAIL at a missing provider/path method or host fallback.

- [ ] **Step 3: Implement the complete embedded provider surface**

Add provider/file-store/watch/attribute-view values and remaining path overloads. Keep default host filesystem behavior unchanged and never fabricate filesystem events.

- [ ] **Step 4: Verify provider and Windows paths**

Run: `sh host/chez/embedded-resource-smoke.sh --fs-full && make winpath winplatform`
Expected: PASS, including the existing 105 and 359 checks.

### Task 4: Complete Files operations and read types

**Files:**
- Create: `host/chez/java/embedded-channels.ss`
- Modify: `host/chez/java/embedded-archive.ss`
- Modify: `host/chez/java/nio-file.ss`
- Modify: `host/chez/java/class-hierarchy.ss`
- Modify: `host/chez/rt.ss`
- Create: `test/chez/embedded-resource-app/resources/data.bin`
- Modify: `test/chez/embedded-resource-app/src/app/core.clj`
- Modify: `host/chez/embedded-resource-smoke.sh`
- Modify: `docs/embedded-resource-compatibility.md`

**Interfaces:**
- Consumes: Task 3 provider metadata and attribute values.
- Produces: `(embedded-byte-channel path options)`, `(embedded-path-stream operation path args)`, and `(embedded-mismatch first second)` used by all `Files` overloads.

- [ ] **Step 1: Write the failing Files matrix**

Add `--files-full` mode with a row for every `Files` static from the spec plus `FileChannel/open`: all channel/reader/copy forms, traversal streams and close/second-use behavior, readString/readAllLines/lines/mismatch/content type, metadata, and every mutation. Include binary NUL/invalid UTF-8, charsets, missing files, embedded/host copy and mismatch, relative list/walk/find paths, and embedded destinations/moves.

- [ ] **Step 2: Run Files tests and confirm missing behavior**

Run: `sh host/chez/embedded-resource-smoke.sh --files-full`
Expected: FAIL at a missing static or read type.

- [ ] **Step 3: Implement remaining read operations and dispatch**

Add seekable read channels, buffered readers, content type, byte mismatch, genuine list/walk/find/line streams, and cross-provider copy/mismatch. Preserve relative traversal shapes and reject every mutation before host access.

- [ ] **Step 4: Verify all standalone modes**

Run: `sh host/chez/embedded-resource-smoke.sh`
Expected: all original and full-matrix modes PASS from neutral working directories.

### Task 5: Matrix audit, JDK oracle, and full verification

**Files:**
- Create: `test/chez/embedded_resource_oracle.clj`
- Create: `test/chez/embedded-resource-oracle.sh`
- Modify: `README.md`
- Modify: `docs/embedded-resource-compatibility.md`

**Interfaces:**
- The oracle prints stable EDN values for representative URL/JAR/NIO behaviors; the Jolt fixture compares against them without depending on the oracle at runtime.

- [ ] **Step 1: Add the oracle and mechanical matrix audit**

Use `javap` to compare public method names against matrix rows and test-mode coverage. Add JVM examples for URL connections, manifests, multi-release selection, byte channels, mismatch, and traversal streams. Document implemented/absent-metadata/read-only/unsupported results row by row and link the matrix from README.

- [ ] **Step 2: Run oracle and audit**

Run: `sh test/chez/embedded-resource-oracle.sh`
Expected: JVM-oracle examples match Jolt results and every public method in scope has a matrix row and test.

- [ ] **Step 3: Rebuild, regenerate, and run focused gates**

Run: `make remint && make jolt-release && sh host/chez/embedded-resource-smoke.sh && make smoke unit buildsmoke manifestcheck readmecheck gambitseedcheck`
Expected: all commands PASS. Rerun real upstream Migratus with the scratch-only logging/SQL-extension shims and confirm the same migration map.

- [ ] **Step 4: Run full verification and independent review**

Run: `make test && git diff --check`
Expected: final gate verdict PASS and no whitespace errors. Request a fresh whole-working-tree review, fix Critical/Important findings with RED–GREEN tests, and rerun the full gate.

- [ ] **Step 5: Final scope check**

Compare every operation against the spec's exhaustive definition and matrix. Report deferred minors and any unavailable external suites explicitly; do not call the work exhaustive while a matrix row is unimplemented or untested.
