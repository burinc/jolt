# Embedded resource discovery and virtual filesystem

## Intent

Jolt binaries can already embed project and dependency resources and read a resource whose name is known. They cannot discover names at runtime. The motivating case is a binary that ships SQL migrations and must enumerate them on startup, including through unmodified JVM Clojure libraries such as Migratus.

## Goals

- Add `(jolt.host/embedded-resource-names)`, returning a sorted vector of application and dependency resource names embedded in the running image. Every returned name must work with `clojure.java.io/resource`.
- Keep Jolt-internal compiler sources, runtime sources, boot files, launcher stubs, FASLs, and build-subsystem entries out of that result.
- Let existing JVM-style discovery resolve an embedded directory through `ClassLoader.getResource` / `getResources`, with a `jar:` URL whose entry name is the requested directory.
- Support Migratus's complete discovery path: URL to `JarFile`, entry enumeration, entry streams, and its `FileSystems` / `PathMatcher` based script exclusions.
- Provide a read-only embedded ZIP-style NIO filesystem rather than a Migratus-only special case. Embedded paths must retain their filesystem identity through path operations.
- Support the established read-side NIO operations against embedded paths: existence and type predicates, size, byte/line/stream reads, basic attributes, directory streams, tree walking, same-file checks, and copying from an embedded path to an output stream.
- Reject mutation of the embedded filesystem with `ReadOnlyFileSystemException`; never silently write to a same-named host file.

## Non-goals

- A writable resource filesystem or mutation of the compiled image.
- Materializing resources or synthetic JARs on disk.
- A general NIO provider for arbitrary on-disk ZIP/JAR files.
- Implementing every `java.nio.file.Files` operation. Unsupported operations must fail honestly rather than access the host filesystem.
- Changing source-root, real JAR, or ordinary host-filesystem behavior.

## Constraints

- Application resources currently share the eager embedded-resource table with runtime-owned entries. Application visibility must be recorded explicitly by the app build emitter rather than inferred from table contents or filename patterns.
- The source blob has a separate index; it remains internal and does not contribute public names.
- Directory entries are synthesized from resource-name prefixes because the build embeds files, not explicit directory records.
- Embedded paths use `/` on every host, as ZIP paths do, and are absolute at the filesystem root `/`.
- A compiled app must work from a neutral working directory with no resource files present on disk.
- Runtime changes require the normal seed regeneration and both Chez and Gambit seeds must remain consistent.

## Approaches

### Dedicated virtual embedded archive

A focused embedded `JarFile` plus a narrow `FileSystems` bridge would cover Migratus with the least code. It was not selected because other NIO-based scanners would still fall through to host-file behavior and the compatibility layer would encode one library's exact path rather than a coherent abstraction.

### Read-only embedded ZIP filesystem (selected)

Treat the application resource set as one virtual archive. `ClassLoader` directory URLs, `JarFile`, and NIO all sit over that same archive model. This directly supports Migratus and gives other JVM Clojure scanners a consistent read-only filesystem. The cost is extending path values to retain their filesystem and dispatching established NIO read operations through that filesystem.

### Temporary JAR materialization

Writing a synthetic archive would reuse the existing ZIP implementation, but introduces temporary-file lifetime, cleanup, permissions, and cross-process concerns. It was rejected.

## Design

### Public names and archive model

The app build registers each project/dependency resource in a dedicated public-name set while continuing to populate the existing embedded-resource table. Runtime-owned registrations do not join that set. The host exposes the names as a freshly allocated, lexically sorted Jolt vector.

A single stable embedded-archive URI identifies this virtual archive. Directory URLs use `jar:` and carry both that archive identity and the requested entry path. Exact resource lookups keep their current behavior; directory lookup succeeds when the normalized directory prefix has at least one public resource descendant.

### JarFile compatibility

Add the `java.util.jar.JarFile` surface over the virtual archive, with `JarEntry` values for synthesized directories and embedded files. `entries`, `getEntry`, `getInputStream`, `size`, `getName`, and `close` follow the existing `ZipFile` surface where applicable. Entry streams read bytes directly from the embedded-resource table. Closing is idempotent and subsequent operations reject use of the closed archive.

The ordinary on-disk `ZipFile` implementation remains unchanged.

### NIO filesystem and paths

`FileSystems/newFileSystem` recognizes the embedded-archive `jar:` URI and returns a read-only filesystem; `getFileSystem` returns the currently open instance for that URI. Opening an already-open URI raises `FileSystemAlreadyExistsException`, and a closed instance can be replaced by a later `newFileSystem` call. Filesystem close/isOpen/read-only/root-directory operations are supported.

Path values retain their filesystem. The default host filesystem continues to construct ordinary paths. Embedded filesystem `getPath` constructs embedded paths; parent, root, file-name, normalize, resolve, resolveSibling, relativize, subpath, iterator, and related path-producing operations preserve that identity. Embedded path equality and hashing include filesystem identity. Embedded `toUri` identifies the embedded archive and entry; `toFile` is unsupported, as it is for a non-default JVM filesystem provider.

The filesystem serves a tree synthesized from public resource names: `/`, every ancestor directory, and every file. It provides immediate children in sorted order and file bytes lazily. No host-path resolution is applied to embedded paths.

The existing NIO operations listed in Goals dispatch on the path's filesystem. Basic attributes describe directories/files, zero timestamps, and nil file keys where the virtual archive has no corresponding metadata. Directory streams and tree walking retain embedded paths and existing filter/visitor behavior. Symbolic links never exist, read access is true, write/execute access is false, and hidden status follows the ZIP provider's `/`-separated path semantics.

All create, delete, write, attribute-setting, link, move, and embedded-destination copy operations reject mutation with `ReadOnlyFileSystemException`. Copying embedded bytes to an output stream remains supported. Operations not implemented for the embedded provider must raise `UnsupportedOperationException` before any host filesystem access.

### ClassLoader integration

`getResource` and `getResources` use the same directory lookup as the NIO/JAR model. A file hit still produces the existing embedded resource URL. A directory hit produces an embedded `jar:` directory URL. Filesystem fallback behavior and real source-root candidates remain unchanged.

### Documentation and verification

Document name enumeration and a SQL-migration discovery example, including the fact that only application/dependency resources are public and that the NIO filesystem is read-only.

Add focused runtime tests for public-name filtering/order, synthesized directories, path identity and equality, URI/filesystem lifecycle, reads and attributes, directory streams/tree walks, read-only failures, and JarFile behavior. Extend the standalone build fixture with nested SQL migrations and `init.sql`, run from outside the source tree, and exercise Migratus's exact discovery call sequence. Where dependency availability permits, also run the real Migratus discovery function against the built image.

Run the focused NIO/ZIP suites, CLI smoke, standalone build smoke, seed consistency checks, and the full standard test gate. Compare any pre-existing failures against the clean baseline rather than attributing them to this change.

## Builder decisions

Helper names, internal record/layout choices, and the exact stable sentinel spelling are left to the builder. The sentinel must not collide with a real user archive path and must be parsed as data, not opened as a file. Tests may use small purpose-built fixtures rather than adding a permanent Migratus dependency.
