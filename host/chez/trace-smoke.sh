#!/bin/sh
# Runtime error reporting: a throw that escapes names the Clojure fn it came from,
# with file and line, and java.lang.Throwable's surface is inherited by every
# exception class rather than restated per shim.
#
# Both regressions this gates were reported from the same three-line program:
#
#   (defn -main [& args] (println "Hello") (try (/ 1 0) (catch Exception e (.printStackTrace e))))
#
# 1. THE TRACE WAS EMPTY FOR A TAIL CALL. The reporter walks Chez's live
#    continuation, but TCO erases a tail-called frame from it — and (-main tail-calls
#    a fn that throws) is the ordinary shape, so the whole trace came back empty and
#    the error printed with NO location at all. The tail-frame history that survives
#    TCO existed but was opt-in behind JOLT_TRACE, so nobody saw it. It is on by
#    default on the source-run path now. A NON-tail call kept working throughout,
#    which is why this looked fixed each time it was checked with a nested call.
#    A frame also reported the line its function was DEFINED on rather than the
#    line reached inside it, so even a working trace pointed at a defn dozens of
#    lines above the fault.
#
# 2. .printStackTrace DID NOT EXIST on the value a catch binds. The Throwable
#    methods were duplicated between the raw-condition arm (records.ss) and
#    dot-object-method (dot-forms.ss); printStackTrace was in the first only, so
#    every ex-info and typed host throwable — which is what a catch actually binds —
#    answered "No matching method printStackTrace found for java.lang.ArithmeticException".
#
# Kept out of smoke.sh deliberately: these cases assert on STDERR and on a project
# run (-m), not on `-e` stdout, which is the shape every check there is built around.
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

jolt="${JOLT_BIN:-bin/jolt}"
case "$jolt" in /*) joltabs="$jolt" ;; *) joltabs="$root/$jolt" ;; esac

fails=0
pass=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/src/app"
printf '{}\n' > "$work/deps.edn"

# -main tail-calls boom, and boom's body is itself a tail call into `/`. Both
# frames are gone from the live continuation; only the history has them.
cat > "$work/src/app/tail.clj" <<'EOF'
(ns app.tail)

(defn boom [x]
  (/ x 0))

(defn -main [& _]
  (println "before")
  (boom 1))
EOF

run_app() {   # run_app <ns> [env-assignment]; prints combined output
  ( cd "$work" && env $2 "$joltabs" run -m "$1" 2>&1 )
}

expect_match() {   # expect_match <label> <output> <grep-pattern>
  if printf '%s' "$2" | grep -q "$3"; then
    pass=$((pass + 1))
  else
    echo "  FAIL: $1"
    echo "    no line matching: $3"
    echo "--- got ---"; printf '%s\n' "$2"
    fails=$((fails + 1))
  fi
}

expect_no_match() {
  if printf '%s' "$2" | grep -q "$3"; then
    echo "  FAIL: $1"
    echo "    unexpected line matching: $3"
    echo "--- got ---"; printf '%s\n' "$2"
    fails=$((fails + 1))
  else
    pass=$((pass + 1))
  fi
}

echo "trace smoke: an uncaught tail-call throw names fn, file and exact line"
out="$(run_app app.tail)"
expect_match "uncaught throw reports the message" "$out" 'Unhandled exception: Divide by zero'
# The erroring fn is a tail call from a tail call: the whole point of the case.
# EXACT lines, not the line each fn was DEFINED on: boom opens on line 3 and
# divides on line 4; -main opens on line 6 and calls boom on line 8. A frame that
# reported its defn line would match 3 and 6 here, so these two assertions are
# what tell the difference.
expect_match "innermost frame is boom, at the dividing line" "$out" 'app\.tail/boom (.*src/app/tail\.clj:4)'
expect_match "caller frame -main, at the call site" "$out" 'app\.tail/-main (.*src/app/tail\.clj:8)'
expect_no_match "no frame reports a defn line" "$out" 'tail\.clj:[36])'

echo "trace smoke: JOLT_TRACE=0 opts out"
out_off="$(run_app app.tail JOLT_TRACE=0)"
expect_match "still reports the message" "$out_off" 'Unhandled exception: Divide by zero'
expect_no_match "no history frames when opted out" "$out_off" 'app\.tail/boom'

# .printStackTrace over each shape a catch can bind: a host-raised arithmetic
# error, an ex-info, and a constructed exception. Each must print "class: message"
# and then the frames — the same rendering the uncaught reporter uses.
cat > "$work/src/app/pst.clj" <<'EOF'
(ns app.pst)

(defn inner [x]
  (/ x 0))

(defn outer [x]
  (inner x))

(defn -main [& _]
  (try (outer 5) (catch Exception e (.printStackTrace e)))
  (try (throw (ex-info "boom" {:a 1})) (catch Exception e (.printStackTrace e)))
  (try (throw (Exception. "plain")) (catch Exception e (.printStackTrace e)))
  ;; the 1-arg overload writes to a PrintWriter/StringWriter instead of stderr
  (let [w (java.io.StringWriter.)]
    (try (outer 5) (catch Exception e (.printStackTrace e w)))
    (when (re-find #"app\.pst/inner" (str w)) (println "WRITER-OK")))
  ;; the rest of the Throwable surface, inherited rather than per-class
  (try (/ 1 0)
       (catch Exception e
         (println "SURFACE"
                  (.getLocalizedMessage e)
                  (count (.getSuppressed e))
                  (identical? e (.fillInStackTrace e)))))
  (println "DONE"))
EOF

echo "trace smoke: .printStackTrace works on every throwable a catch binds"
pst="$(run_app app.pst)"
expect_match "arithmetic error prints class and message" "$pst" 'java\.lang\.ArithmeticException: Divide by zero'
# inner divides on 4 (defn on 3), outer calls inner on 7 (defn on 6), -main calls
# outer on 10 — and a catch clause must report the THROWING line, not the line the
# handler itself is on, which is what the snapshot at catch entry is for.
expect_match "printStackTrace: innermost frame at the dividing line" "$pst" 'app\.pst/inner (.*src/app/pst\.clj:4)'
expect_match "printStackTrace: caller frame at its call site" "$pst" 'app\.pst/outer (.*src/app/pst\.clj:7)'
expect_match "printStackTrace: outermost frame at its call site" "$pst" 'app\.pst/-main (.*src/app/pst\.clj:10)'
expect_match "ex-info prints class and message" "$pst" 'clojure\.lang\.ExceptionInfo: boom'
expect_match "constructed exception prints class and message" "$pst" 'java\.lang\.Exception: plain'
expect_match "1-arg overload writes to the given writer" "$pst" 'WRITER-OK'
expect_match "getLocalizedMessage/getSuppressed/fillInStackTrace" "$pst" 'SURFACE Divide by zero 0 true'
expect_match "execution continued past every catch" "$pst" 'DONE'

if [ "$fails" -gt 0 ]; then
  echo "trace smoke: $fails failed, $pass passed"
  exit 1
fi
echo "trace smoke: $pass passed (exact per-frame lines, JOLT_TRACE=0 opt-out, Throwable surface)"
