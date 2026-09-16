#!/bin/sh
# zlib-native smoke: in a built app, a zlib the app loads through :jolt/native
# does not change the zlib java.util.zip uses.
#
# The app loads a fake zlib that defines all fourteen names java.util.zip binds.
# Its crc32 answers 0 and its zlibVersion answers "fake". jolt.ffi opens a
# :jolt/native library RTLD_LOCAL and binds its names through that handle
# (host/chez/java/ffi.ss), so the app's own binding of zlibVersion reaches the
# fake. java.util.zip must bind the private jolt_z_* names and never fall
# through to zlib.ss's system-libz step, which takes every name from the first
# declared library that defines all of them and would bind the fake: CRC32 must
# still give the check value of "123456789", 3421780262. The check is decisive
# on Linux, where --exclude-libs hides the binary's own zlib names; a macOS
# binary exports them, so there a runtime that bound plain names would still
# find a real zlib.
#
#   JOLT_BIN=target/release/jolt sh host/chez/zlib-native-smoke.sh
set -u
root="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root" || exit 1
jolt="${JOLT_BIN:-target/release/jolt}"
case "$jolt" in /*) ;; *) jolt="$root/$jolt" ;; esac

# A check this environment cannot run: a skip is a failure where the job was
# expected to run it, as host/chez/zlib-register-smoke.sh does. Linux is where
# this check is decisive, and that job sets JOLT_REQUIRE_BUILDLIB.
skip_or_fail() {
  if [ -n "${JOLT_REQUIRE_BUILDLIB:-}" ]; then
    echo "  FAIL: $1 (JOLT_REQUIRE_BUILDLIB is set, so this environment was expected to run it)"
    exit 1
  fi
  echo "zlib-native smoke: skipped ($1)"
  exit 0
}

case "$(uname -s)" in
  Darwin) key=darwin; ext=dylib; shared="-dynamiclib" ;;
  Linux)  key=linux; ext=so; shared="-shared -fPIC" ;;
  *)      skip_or_fail "Darwin and Linux only" ;;
esac
command -v cc >/dev/null 2>&1 || skip_or_fail "no C compiler for the fake zlib"

# The fake must define every name zlib.ss binds. zlib-common-definer takes all
# fourteen from the first declared library that defines them all, so a fake that
# is short by one is passed over, the runtime finds a real zlib either way, and
# this smoke would pass while proving nothing. That is how the list grew from 2
# to 14 during chunk 2 without the gate noticing, so the two lists are compared
# here.
fake_names='adler32 crc32 deflate deflateEnd deflateInit2_ deflateParams deflateReset deflateSetDictionary inflate inflateEnd inflateInit2_ inflateReset inflateSetDictionary zlibVersion'
runtime_names="$(awk '/\(define zlib-names/,/\)\)/' host/chez/java/zlib.ss \
  | grep -o '"[^"]*"' | tr -d '"' | sort | tr '\n' ' ')"
# shellcheck disable=SC2086 # $fake_names is a list of names, one per word
want_names="$(printf '%s\n' $fake_names | sort | tr '\n' ' ')"
if [ "$runtime_names" != "$want_names" ]; then
  echo "  FAIL: the fake zlib defines a different set of names than zlib.ss binds"
  echo "    zlib.ss: $runtime_names"
  echo "    fake:    $want_names"
  exit 1
fi

work="$(mktemp -d)"
# deps.edn below is written with an unquoted heredoc, so the path goes in as it
# is: refuse one that would need quoting.
case "$work" in
  *[\"\\]*) echo "  FAIL: the temporary directory needs quoting: $work"; exit 1 ;;
esac

trap 'rm -rf "$work"' EXIT

cat > "$work/fakez.c" <<'EOF'
/* A zlib that answers wrong, so a binding to it shows. It defines every name
   java.util.zip binds, so zlib.ss's system-libz step would take all of them. */
unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len) {
  (void)crc; (void)buf; (void)len;
  return 0;
}
unsigned long adler32(unsigned long adler, const unsigned char *buf, unsigned int len) {
  (void)adler; (void)buf; (void)len;
  return 0;
}
const char *zlibVersion(void) { return "fake"; }
#define Z_STREAM_ERROR (-2)
#define Z_VERSION_ERROR (-6)
int inflateInit2_(void *s, int w, const char *v, int n) { (void)s; (void)w; (void)v; (void)n; return Z_VERSION_ERROR; }
int deflateInit2_(void *s, int l, int m, int w, int ml, int st, const char *v, int n) {
  (void)s; (void)l; (void)m; (void)w; (void)ml; (void)st; (void)v; (void)n;
  return Z_VERSION_ERROR;
}
int inflate(void *s, int f) { (void)s; (void)f; return Z_STREAM_ERROR; }
int deflate(void *s, int f) { (void)s; (void)f; return Z_STREAM_ERROR; }
int inflateEnd(void *s) { (void)s; return Z_STREAM_ERROR; }
int deflateEnd(void *s) { (void)s; return Z_STREAM_ERROR; }
int inflateReset(void *s) { (void)s; return Z_STREAM_ERROR; }
int deflateReset(void *s) { (void)s; return Z_STREAM_ERROR; }
int deflateParams(void *s, int l, int st) { (void)s; (void)l; (void)st; return Z_STREAM_ERROR; }
int inflateSetDictionary(void *s, const unsigned char *d, unsigned int n) { (void)s; (void)d; (void)n; return Z_STREAM_ERROR; }
int deflateSetDictionary(void *s, const unsigned char *d, unsigned int n) { (void)s; (void)d; (void)n; return Z_STREAM_ERROR; }
EOF
for n in $fake_names; do
  grep -q "$n" "$work/fakez.c" || { echo "  FAIL: the fake zlib does not define $n"; exit 1; }
done

lib="$work/libfakez.$ext"
# shellcheck disable=SC2086 # $shared is two words on Linux
if ! cc $shared -o "$lib" "$work/fakez.c"; then
  echo "  FAIL: the fake zlib did not build"; exit 1
fi

mkdir -p "$work/app/src/zn"
cat > "$work/app/deps.edn" <<EOF
{:paths ["src"]
 :jolt/native [{:name "fakez" :$key "$lib"}]}
EOF
cat > "$work/app/src/zn/main.clj" <<'EOF'
(ns zn.main (:require [jolt.ffi :as ffi]))
(ffi/defcfn plain-version "zlibVersion" [] :string)
(defn -main [& _]
  (let [c (java.util.zip.CRC32.)]
    (.update c (.getBytes "123456789" "UTF-8"))
    (println "ZLIB-NATIVE" (plain-version) (.getValue c))))
EOF

echo "zlib-native smoke: a built app that loads a fake zlib"
if ! JOLT_NO_USER_DEPS=1 JOLT_PWD="$work/app" "$jolt" build -m zn.main -o "$work/app-bin" >"$work/build.log" 2>&1; then
  cat "$work/build.log"; echo "  FAIL: jolt build exited non-zero"; exit 1
fi
if ! (cd / && "$work/app-bin" >"$work/run.log" 2>&1); then
  echo "  FAIL: the app exited non-zero"; tail -5 "$work/run.log"; exit 1
fi
got="$(tail -1 "$work/run.log")"
gotver="$(printf '%s\n' "$got" | awk '{print $2}')"
gotcrc="$(printf '%s\n' "$got" | awk '{print $3}')"
# Which half failed says what it means: a wrong version means the app never
# loaded the fake, so the run proves nothing; a wrong CRC-32 means java.util.zip
# bound the fake, which is the criterion failing.
if [ "$gotver" != "fake" ]; then
  echo "  FAIL: the app did not load the fake zlib (zlibVersion is '$gotver'), so this run proves nothing"
  echo "    got: $got"; exit 1
fi
if [ "$gotcrc" != "3421780262" ]; then
  echo "  FAIL: CRC32 answered '$gotcrc', not 3421780262: java.util.zip bound the fake zlib"
  echo "    got: $got"; exit 1
fi
echo "zlib-native smoke: passed (zlibVersion by name is the fake; CRC32 is still right)"
