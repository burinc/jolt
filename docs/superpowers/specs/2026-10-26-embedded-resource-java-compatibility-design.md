# Exhaustive embedded-resource Java compatibility

## Intent

Issue #1438 is a general embedded-resource discovery feature, not a Migratus adapter. The initial virtual archive and read-only NIO filesystem established the model. This project completes the public Java compatibility surface so independent JVM Clojure libraries can use their normal URL, JAR, and NIO discovery patterns without method-missing failures or accidental host-file access.

## Scope and meaning of exhaustive

Exhaustive covers:

- Every public instance operation on embedded `URL`, `URLConnection`/`JarURLConnection`, `ZipEntry`/`JarEntry`, `ZipFile`/`JarFile`, `Path`, and `FileSystem` values.
- Every `java.nio.file.Files` static operation when at least one argument is an embedded path, including overloads introduced through the JDK 21 surface.
- Supporting value types needed by those operations: `JarURLConnection`, `Manifest`, `Attributes`/`Attributes.Name`, `FileStore`, basic attribute views, streams, readers, and byte channels.
- JVM-appropriate results for absent metadata, signatures, certificates, timestamps, and optional filesystem capabilities.

It does not require unrelated network protocols, remote URL handlers, writable archives, a general ZIP writer, or changing the existing behavior of real host files and real archives. Static global factories/configuration that do not operate on an embedded value remain outside the feature. Existing Jolt implementations are reused where correct.

Every operation must either work with JVM-compatible behavior or have a deliberate, documented JVM-family result. An accidental `No matching method`, raw host fault, or fallback to a same-named host path is a defect.

## Goals

- Preserve the existing public resource registry, virtual archive, and read-only provider model.
- Complete embedded URL and connection behavior, including URL/URI conversion, same-file comparisons, content reads, metadata, state flags, and `JarURLConnection` archive/entry access.
- Complete ZIP/JAR entry and archive behavior, including stream views, JAR-specific entry lookup, manifests and attributes, multi-release answers, unsigned-entry metadata, and every constructor shape.
- Complete NIO `Path` and `FileSystem` behavior, including path watches/capability answers, file stores, attribute views, and provider metadata.
- Complete `Files` behavior for embedded paths: buffered readers, byte channels, content type, mismatch, list/walk/find/line streams, attribute views, and all existing operations.
- Mutations always reject with `ReadOnlyFileSystemException` before any host-path access. Operations intrinsically unavailable for an immutable virtual image, such as watches or asynchronous mutation channels, use the documented JVM exception family rather than an accidental method miss.
- Publish a method-by-method compatibility matrix and test each row independently of Migratus.

## Non-goals

- Remote HTTP/FTP/JNDI resources, custom protocol handlers, or network policy emulation.
- Writable embedded resources, synthetic archives on disk, or ZIP creation.
- Multi-release variant selection that invents alternate resource versions not present in the embedded image.
- Security signature verification. Embedded resources are unsigned; certificate/code-signer APIs answer accordingly.
- User-principal mutation, POSIX mutation, asynchronous writes, or filesystem change notifications with fabricated events.

## Constraints

- The public resource set remains application/dependency resources only; runtime internals stay hidden.
- The archive sentinel is data and must never be opened as a host file under any constructor or operation.
- Embedded paths use `/` and retain their filesystem identity.
- Real host paths, real JARs, and default-filesystem behavior must not regress.
- The existing full gate and independent review remain required after implementation.

## Approaches

### Common surface only

Implement `openConnection`, `JarURLConnection`, and `getJarEntry`, leaving other APIs to accidental method-missing errors. Rejected by the user because it still makes compatibility depend on which library pattern is used.

### Exhaustive embedded-value compatibility (selected)

Complete every public operation on the embedded values and every `Files` operation accepting embedded paths. Reuse existing generic host shims and add focused implementations only where missing. This is a multi-stage project with a larger test matrix, but it gives a coherent contract rather than a sequence of library-specific patches.

### Exhaustive Java emulation

Reimplement unrelated network protocols, writable ZIPs, and all global Java configuration. Rejected as unrelated to embedded-resource discovery.

## API map

### URL and URLConnection

Embedded `URL` supports the full instance surface: constructors and accessors, equality/hash/sameFile, `toString`/`toExternalForm`/`toURI`, `openConnection` (including proxy argument validation), `openStream`, and `getContent` overloads. `jar:` URLs produce `JarURLConnection`; ordinary embedded file URLs retain their existing behavior.

Embedded connections implement connection state and metadata: connect, timeouts, URL, lengths, type/encoding, expiration/date/modification, headers, content, permission, streams, input/output flags, interaction/use-cache flags, if-modified-since, and request properties. Output is refused. Metadata comes from the embedded bytes and the virtual zero timestamp. Content types use the standard filename map and stream guessing where requested.

`JarURLConnection` additionally supports `getJarFileURL`, `getEntryName`, `getJarFile`, `getManifest`, `getJarEntry`, entry/main attributes, and certificates. Directory entry access answers the synthetic directory entry; absent entry access answers nil as on the JVM.

### ZIP and JAR

`ZipEntry`/`JarEntry` complete name, time fields, sizes, CRC/method, extra/comment, directory, string/hash/clone, attributes, certificates, code signers, and real names. Embedded entries are stored, have zero timestamps, no extra/comment/attributes/certificates/signers, and stable clone semantics.

`ZipFile`/`JarFile` complete comment, entry lookup, streams and stream views, name, size, close, manifest, JAR entries, version, and multi-release behavior. Every String/File/mode/charset/version constructor shape recognizes the sentinel and validates arguments without disk access. `versionedStream` and `stream` enumerate the same embedded entries when no versioned alternatives exist. `getVersion` answers the requested/base version as appropriate; `isMultiRelease` reflects the manifest's `Multi-Release` attribute.

`Manifest` and `Attributes` support their public map/value/copy/read/write/clear/clone/equality behavior. Manifest parsing handles main and per-entry sections, continuation lines, and UTF-8 names/values. `Attributes.Name` validates and compares names case-insensitively as on the JVM.

### NIO Path and FileSystem

`Path` completes every method, including string overloads, watch registration, and all path-producing operations. Watch registration returns a real but permanently quiet watch key or throws the documented provider exception; it must not reach the default host watch service.

`FileSystem` completes provider metadata, close/open/read-only, separator, roots, file stores, supported attribute views, path construction/matching, principal lookup, and watch-service creation. The provider has a stable scheme and exposes the same embedded operations as `Files`. `FileStore` exposes virtual name/type/capacity/read-only metadata and basic attributes.

### Files and related read types

Every `Files` static with an embedded path is dispatched deliberately:

- Streams and channels: `newInputStream`, `newOutputStream`, `newByteChannel` overloads, `newBufferedReader`/`Writer`, and all copy/write forms. Byte channels support read, position, size, and close; writes/truncation reject.
- Directory/tree traversal: all `newDirectoryStream`, `walkFileTree`, `list`, `walk`, and `find` forms, returning genuine Java streams with close semantics.
- File contents: `readAllBytes`, `readString`, `readAllLines`, `lines`, and `mismatch`, with charset handling and missing-file behavior.
- Metadata: `getFileStore`, `probeContentType`, basic attribute views and maps, POSIX/owner answers, timestamps, type/access predicates, and `isSameFile`.
- All create/delete/move/link/set/write operations reject read-only. Unsupported cross-provider operations use `UnsupportedOperationException` without host access.

The existing deferred relative-traversal shape and cross-provider copy exception issues are fixed as part of making these operations exhaustive.

## Implementation stages

1. **URL and connection completion.** Add focused connection values and tests for every method, metadata, state, content, and JAR-specific access.
2. **ZIP/JAR and manifest completion.** Add full entry/archive methods, constructor matrix, manifest/attributes values, stream views, and multi-release behavior.
3. **Path/FileSystem completion.** Add provider/file-store/watch/attribute-view behavior and remaining path overloads.
4. **Files completion.** Add buffered readers, byte channels, mismatch/content type, list/walk/find/line streams, and every missing static dispatch.
5. **Matrix, verification, and review.** Publish the method matrix, compare behavior with a JDK oracle for representative inputs, rerun real Migratus, regenerate/rebuild, run the full gate, and obtain independent review.

Each stage has RED–GREEN standalone tests and runs existing regression suites. No stage is presented as exhaustive until its matrix rows all pass.

## Documentation and verification

The README links to a checked-in compatibility matrix grouped by type, with each public operation marked implemented, absent-metadata result, read-only rejection, or deliberate unsupported capability and its exception. Tests are organized by the same groups so coverage can be audited mechanically rather than inferred from Migratus.

Verification includes direct API calls, constructor/argument/error cases, closed values, empty/missing resources, binary content, Unicode manifest data, relative paths, colliding host paths, JDK-oracle examples, all prior feature modes, real Migratus discovery, and the full standard test gate.

## Builder clarifications

- Exact embedded file lookups retain their existing bare-name URL spelling for backward compatibility. Directory URLs use the canonical archive spelling. Both URL forms create a `JarURLConnection` backed by the same archive and entry; `getJarFileURL` returns the canonical archive URL, and equality remains based on the original URL spelling.
- `Files.mismatch` compares bytes across embedded/default providers. `Files.copy(embedded, hostPath)` may write the host destination, while any copy with an embedded destination rejects read-only. Any `move` involving an embedded path rejects read-only. Other cross-provider operations are evaluated individually for read feasibility rather than rejected categorically.
- Multi-release lookup implements the actual JDK 21 selection rules against entries present in the image and the requested/runtime version. It never invents a missing variant. `getEntry`, `getJarEntry`, and `versionedStream` follow JDK-oracle behavior when `META-INF/versions/N/...` entries and `Multi-Release: true` are present; otherwise they retain base-entry behavior.
