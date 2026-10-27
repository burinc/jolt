# Embedded resource Java compatibility matrix

This matrix covers public operations on embedded values and `Files` operations accepting embedded paths. **Implemented** means covered by a standalone behavioral test. **Metadata** means a deliberate result for information absent from the virtual image. **Read-only** means `ReadOnlyFileSystemException`. **Unsupported** means a deliberate `UnsupportedOperationException` for a capability the immutable image cannot provide. No row may fall through to a same-named host path.

All rows are covered by standalone behavioral suites. Representative archive, manifest, and multi-release results are also compared between Jolt and the JDK by `test/chez/embedded-resource-oracle.sh`. The machine-checked [signature ledger](../test/chez/embedded-resource-api-coverage.edn) records each public method or constructor, its normalized parameter signature and arity, and the behavioral assertion that covers it; the audit rejects missing and stale rows. URL constructors and unrelated static global factories are outside the embedded-value scope.

## `java.net.URL`

| Operation | Result | Status |
|---|---|---|
| `getProtocol`, `getPath`, `getFile`, `getHost`, `getAuthority`, `getPort`, `getDefaultPort`, `getQuery`, `getUserInfo`, `getRef` | URL components | Implemented |
| `equals`, `hashCode`, `sameFile` | Original URL spelling and archive entry identity | Implemented |
| `toString`, `toExternalForm`, `toURI` | Original URL spelling / URI conversion | Implemented |
| `openConnection`, `openConnection(Proxy)` | Embedded connection; proxy form validated | Implemented |
| `openStream` | Embedded byte stream | Implemented |
| `getContent`, `getContent(Class<?>[])` | Embedded content | Implemented |

## `java.net.URLConnection`

| Operation | Result | Status |
|---|---|---|
| `connect` | Marks the embedded connection connected | Implemented |
| `setConnectTimeout`, `getConnectTimeout`, `setReadTimeout`, `getReadTimeout` | Mutable connection settings | Implemented |
| `getURL` | Original resource URL | Implemented |
| `getContentLength`, `getContentLengthLong` | Embedded byte length | Implemented |
| `getContentType` | Standard filename-map result | Implemented |
| `getContentEncoding` | Nil | Implemented |
| `getExpiration`, `getDate`, `getLastModified` | Zero | Implemented |
| `getHeaderField*` | Nil/zero/default; no synthetic headers | Implemented |
| `getContent`, `getContent(Class<?>[])` | Embedded content | Implemented |
| `getPermission` | Read-only embedded permission result | Implemented |
| `getInputStream` | Embedded byte stream | Implemented |
| `getOutputStream` | Read-only rejection | Implemented |
| `toString` | Connection description | Implemented |
| `setDoInput`, `getDoInput` | Default true; mutable | Implemented |
| `setDoOutput`, `getDoOutput` | Default false; mutable; output stream rejects | Implemented |
| `setAllowUserInteraction`, `getAllowUserInteraction` | Default false; mutable | Implemented |
| `setUseCaches`, `getUseCaches` | Default false for immutable image; mutable | Implemented |
| `setIfModifiedSince`, `getIfModifiedSince` | Default zero; mutable | Implemented |
| `getDefaultUseCaches`, `setDefaultUseCaches` | Immutable connection defaults | Implemented |
| `setRequestProperty`, `addRequestProperty`, `getRequestProperty`, `getRequestProperties` | Mutable request properties before connect | Implemented |

## `java.net.JarURLConnection`

| Operation | Result | Status |
|---|---|---|
| `getJarFileURL` | Canonical embedded archive URL | Implemented |
| `getEntryName` | Requested entry name | Implemented |
| `getJarFile` | Embedded archive | Implemented |
| `getManifest` | Absent nil, otherwise parsed manifest | Implemented |
| `getJarEntry` | File or synthesized directory entry; nil if absent | Implemented |
| `getAttributes`, `getMainAttributes` | Absent entry/main attributes or parsed values | Implemented |
| `getCertificates` | Empty array for unsigned embedded entries | Implemented |

## `java.util.zip.ZipEntry` / `java.util.jar.JarEntry`

| Operation | Result | Status |
|---|---|---|
| Name, time, size, CRC, method, extra, comment, directory, string/hash/clone | Stored entry values; zero times; clones independent | Implemented |
| `getAttributes` | Per-entry manifest attributes or nil | Implemented |
| `getCertificates`, `getCodeSigners` | Empty unsigned-entry results | Implemented |
| `getRealName` | Selected entry name | Implemented |

## `java.util.zip.ZipFile` / `java.util.jar.JarFile`

| Operation | Result | Status |
|---|---|---|
| All String/File/mode/charset/version constructors | Sentinel recognized without host access; arguments validated | Implemented |
| `getComment` | Nil | Implemented |
| `getEntry`, `getJarEntry`, `getInputStream` | Selected entry and byte stream | Implemented |
| `getName` | Sentinel name | Implemented |
| `entries`, `stream`, `versionedStream` | Enumeration or genuine stream view | Implemented |
| `size` | Synthesized entry count | Implemented |
| `close` | Idempotent; later operations reject | Implemented |
| `getManifest` | Absent nil, otherwise parsed manifest | Implemented |
| `getVersion`, `isMultiRelease` | Requested/base version and manifest flag | Implemented |

## `java.util.jar.Manifest` / `Attributes` / `Attributes.Name`

| Operation | Result | Status |
|---|---|---|
| Manifest main/entry lookup, clear, read, write, copy, clone, equality/hash | UTF-8 manifest behavior with continuations | Implemented |
| Attributes map access/mutation, copy, clear, size/empty, key/value/entry views, clone, equality/hash | Full map semantics | Implemented |
| Attribute-name construction, validation, equality/hash/string | Case-insensitive JVM names | Implemented |

## `java.nio.file.Path` and `FileSystem`

| Operation | Result | Status |
|---|---|---|
| All path construction, navigation, comparison, URI, and overloads | Embedded identity and POSIX ZIP semantics | Implemented |
| Watch registration/service | Quiet immutable watch values; no fabricated events | Implemented |
| Provider scheme and provider read/write operations | Stable embedded provider | Implemented |
| Close/open/read-only, separator, roots | Filesystem lifecycle | Implemented |
| File stores | Virtual name/type/capacity/read-only metadata | Implemented |
| Supported attribute views | `basic` | Implemented |
| Principal lookup | Deliberate immutable/no-owner result | Implemented |

## `java.nio.file.Files` and read types

| Operation group | Result | Status |
|---|---|---|
| `newInputStream`, `newBufferedReader`, `readAllBytes`, `readString`, `readAllLines`, `lines` | Embedded bytes with charset handling | Implemented |
| `newByteChannel`, `FileChannel/open` | Read/position/size/close; write/truncate read-only | Implemented |
| `newDirectoryStream`, `walkFileTree`, `list`, `walk`, `find` | Relative-shape-preserving traversal and genuine streams | Implemented |
| `copy` | Embedded to host/output supported; embedded destination read-only | Implemented |
| `mismatch` | Cross-provider byte comparison | Implemented |
| `getFileStore`, `probeContentType`, basic attributes and access predicates | Virtual metadata | Implemented |
| All create/delete/move/link/set/write operations | Read-only rejection | Implemented |
