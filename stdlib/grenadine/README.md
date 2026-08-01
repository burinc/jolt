# Vendored Grenadine resolver core

These namespaces are the portable resolver subset from
[Grenadine](https://github.com/ingydotnet/grenadine), vendored from commit
`26d2134a76f0ee738e64353211f7d6eae533c086`:

- `grenadine.xml`
- `grenadine.pom`
- `grenadine.version`
- `grenadine.graph`

Jolt embeds every `.clj` and `.cljc` file under `stdlib`, so `jolt.deps` can use
Grenadine while bootstrapping dependencies with no JVM and no prior dependency
resolution.

The effectful side remains Jolt-native: `jolt.mvn-http` downloads POMs and JARs,
the standard Maven repository stores them, and Jolt extracts source roots.

Grenadine is distributed under the MIT license; see `LICENSE` in this directory.
