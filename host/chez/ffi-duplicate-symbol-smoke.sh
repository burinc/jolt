#!/bin/sh
# ffi-duplicate-symbol smoke (issue #731): a declared :jolt/native that carries
# its OWN static copy of another declared native's code is the raygui/raylib
# footgun — raygui linked against libraylib.a gets a private copy of raylib's
# input globals, so every control reads a mouse that never moves and the UI goes
# inert WITHOUT A SINGLE ERROR.
#
# jolt cannot merge the two copies: by the time the .so exists the duplicate is
# baked into it, and the fix is to rebuild the dependent against the SHARED base
# library. What jolt can do is refuse to be silent about it.
#
# The discriminator is the ADDRESS, not the count of handles that answer.
# dlsym(handle, sym) searches that handle's dependency chain too, so a dependent
# linked CORRECTLY against the shared base also resolves the base's symbols
# through its own handle — counting handles would flag the build that got it
# right. Two copies means two addresses; one address reached through several
# handles is one copy, which is the point of linking dynamically.
#
# This gate pins both halves, and the second is the one that matters: the
# footgun build is reported, and the correct build is NOT. A false positive here
# would train people to ignore the warning.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
jolt="${JOLT_BIN:-bin/jolt}"

if ! command -v cc >/dev/null 2>&1; then
  echo "ffi-duplicate-symbol smoke: skipped (no C compiler)"
  exit 0
fi

case "$(uname -s)" in
  Darwin) soext="dylib"; shared="-dynamiclib" ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "ffi-duplicate-symbol smoke: skipped (windows resolves globally, no scoped handles)"
    exit 0 ;;
  *)      soext="so";    shared="-shared -fPIC" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The base library: a global nothing else can see, plus a setter and a getter.
# raylib's input state, in miniature.
cat > "$work/state.c" <<'EOF'
static int g_mouse = 0;
void state_set_mouse(int v) { g_mouse = v; }
int  state_get_mouse(void)  { return g_mouse; }
EOF

# The dependent: reads the base library's global through its API. raygui.
cat > "$work/widget.c" <<'EOF'
extern int state_get_mouse(void);
int widget_read_mouse(void) { return state_get_mouse(); }
EOF

cc -c "$work/state.c" -o "$work/state.o"
ar rcs "$work/libstate.a" "$work/state.o"
# shellcheck disable=SC2086
cc $shared "$work/state.c" -o "$work/libstate.$soext"
# THE FOOTGUN: linked against the static archive, so it carries its own g_mouse.
# shellcheck disable=SC2086
cc $shared "$work/widget.c" "$work/libstate.a" -o "$work/libwidget-static.$soext"
# The correct build: linked against the shared base, so there is one g_mouse.
# shellcheck disable=SC2086
cc $shared "$work/widget.c" -L"$work" -lstate -o "$work/libwidget-shared.$soext" \
   -Wl,-rpath,"$work"

fails=0
report() { echo "FAIL: $1"; fails=$((fails + 1)); }

# --- the footgun build is reported --------------------------------------------
cat > "$work/footgun.clj" <<EOF
(ns footgun (:require [jolt.ffi :as ffi]))
(ffi/load-library "$work/libstate.$soext")
(ffi/load-library "$work/libwidget-static.$soext")
(println "DEFINERS" (count (ffi/defining-libraries "state_get_mouse")))
(ffi/defcfn set-mouse "state_set_mouse" [:int] :void)
(ffi/defcfn get-mouse "state_get_mouse" [] :int)
(ffi/defcfn widget-read "widget_read_mouse" [] :int)
(set-mouse 42)
(println "OWN" (get-mouse))
(println "WIDGET" (widget-read))
EOF
out="$("$jolt" run "$work/footgun.clj" 2>&1)" || { echo "$out"; report "footgun fixture did not run"; }

echo "$out" | grep -q "DEFINERS 2" \
  || report "defining-libraries did not report both natives (got: $(echo "$out" | grep DEFINERS || echo none))"
echo "$out" | grep -q "jolt.ffi: duplicate native symbol" \
  || report "no duplicate-symbol warning for the static-copy build"
echo "$out" | grep -q "state_get_mouse" \
  || report "the warning does not name the duplicated symbol"
echo "$out" | grep -q "libwidget-static" \
  || report "the warning does not name the library carrying the private copy"
# The private copy really is a second copy — the widget cannot see the write.
echo "$out" | grep -q "WIDGET 0" \
  || report "fixture did not reproduce the two-copies behaviour (got: $(echo "$out" | grep WIDGET || echo none))"

# --- the correct build is NOT reported ----------------------------------------
cat > "$work/correct.clj" <<EOF
(ns correct (:require [jolt.ffi :as ffi]))
(ffi/load-library "$work/libstate.$soext")
(ffi/load-library "$work/libwidget-shared.$soext")
(println "DEFINERS" (count (ffi/defining-libraries "state_get_mouse")))
(ffi/defcfn set-mouse "state_set_mouse" [:int] :void)
(ffi/defcfn get-mouse "state_get_mouse" [] :int)
(ffi/defcfn widget-read "widget_read_mouse" [] :int)
(set-mouse 42)
(println "OWN" (get-mouse))
(println "WIDGET" (widget-read))
EOF
out2="$("$jolt" run "$work/correct.clj" 2>&1)" || { echo "$out2"; report "correct fixture did not run"; }

echo "$out2" | grep -q "DEFINERS 1" \
  || report "defining-libraries over-reported for the correctly linked build (got: $(echo "$out2" | grep DEFINERS || echo none))"
echo "$out2" | grep -q "jolt.ffi: duplicate native symbol" \
  && report "false positive: the correctly linked build was reported as duplicated"
# One copy: the widget sees the write.
echo "$out2" | grep -q "WIDGET 42" \
  || report "correctly linked build did not share the global (got: $(echo "$out2" | grep WIDGET || echo none))"

# --- a declared native shadowing the GLOBAL namespace is not a duplicate -------
# The scoped loader exists so a declared native's symbols beat the process
# global namespace for its own defcfns — that is how jolt-lang/crypto's OpenSSL
# EVP_* reach OpenSSL and not Apple's BoringSSL. That shadowing is the FEATURE,
# and it must not read as a duplicate: the check only compares declared natives
# against each other, never against the global namespace, or the case the loader
# was built for would warn on every call.
cat > "$work/shadow.c" <<'EOF'
int abs(int x) { return (x < 0 ? -x : x) + 1000; }
EOF
# shellcheck disable=SC2086
cc $shared "$work/shadow.c" -o "$work/libshadow.$soext"
cat > "$work/shadow.clj" <<EOF
(ns shadow (:require [jolt.ffi :as ffi]))
(ffi/load-library "$work/libshadow.$soext")
(ffi/defcfn c-abs "abs" [:int] :int)
(println "SHADOW" (c-abs -4))
(println "DEFINERS" (count (ffi/defining-libraries "abs")))
EOF
out3="$("$jolt" run "$work/shadow.clj" 2>&1)" || { echo "$out3"; report "shadow fixture did not run"; }

echo "$out3" | grep -q "SHADOW 1004" \
  || report "the declared native no longer shadows the global namespace (got: $(echo "$out3" | grep SHADOW || echo none))"
echo "$out3" | grep -q "DEFINERS 1" \
  || report "global-namespace shadowing counted as a duplicate definition (got: $(echo "$out3" | grep DEFINERS || echo none))"
echo "$out3" | grep -q "jolt.ffi: duplicate native symbol" \
  && report "false positive: shadowing the global namespace was reported as duplicated"

# --- the warning is emitted once per symbol, not once per call ------------------
cat > "$work/once.clj" <<EOF
(ns once (:require [jolt.ffi :as ffi]))
(ffi/load-library "$work/libstate.$soext")
(ffi/load-library "$work/libwidget-static.$soext")
(ffi/defcfn get-mouse "state_get_mouse" [] :int)
(dotimes [_ 5] (get-mouse))
EOF
n="$("$jolt" run "$work/once.clj" 2>&1 | grep -c "duplicate native symbol" || true)"
[ "$n" = "1" ] || report "warning fired $n times for one symbol, expected once"

if [ "$fails" -eq 0 ]; then
  echo "ffi-duplicate-symbol smoke: passed"
  exit 0
fi
echo "ffi-duplicate-symbol smoke: $fails failure(s)" >&2
exit 1
