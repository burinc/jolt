#!/bin/sh
# System/in, System/out, System/err — the process's own streams.
#
# System.in is an InputStream the JVM hands every program; jolt had System/out
# and System/err but no System/in at all, so any ported code that read stdin
# through it ("No matching field or method: System/in") failed to load. The
# streams also have to report the classes the JVM's do — System.out is a
# PrintStream, not the PrintWriter *out* is — because libraries branch on that.

set -e

pass=0
fails=0
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

jolt="bin/jolt"

# run <expr> [stdin-text]: evaluate and print the LAST line of stdout.
run() {
  if [ "$#" -ge 2 ]; then
    printf '%s' "$2" | JOLT_QUIET=1 "$jolt" -e "$1" 2>/dev/null | tail -1
  else
    JOLT_QUIET=1 "$jolt" -e "$1" </dev/null 2>/dev/null | tail -1
  fi
}

check() {
  clabel="$1"; cgot="$2"; cwant="$3"
  if [ "$cgot" = "$cwant" ]; then
    echo "PASS: ($clabel) $cgot"; pass=$((pass+1))
  else
    echo "FAIL: ($clabel) got '$cgot', want '$cwant'"; fails=$((fails+1))
  fi
}

# --- (a) System/in exists and is an InputStream ------------------------------
check a "$(run '(println (instance? java.io.InputStream System/in))')" "true"
check a2 "$(run '(println (class System/in))')" "java.io.InputStream"

# --- (b) slurp / read / line-seq over piped stdin -----------------------------
check b "$(run '(println (slurp System/in))' 'hello stdin')" "hello stdin"
check c "$(run '(println (pr-str (vec (line-seq (clojure.java.io/reader System/in)))))' 'a
b
c
')" "[\"a\" \"b\" \"c\"]"
# InputStream.read() is the next byte as an unsigned int, -1 at EOF.
check d "$(run '(println [(.read System/in) (.read System/in)])' 'AB')" "[65 66]"
check d2 "$(run '(println (.read System/in))')" "-1"

# --- (e) io/copy System/in -> System/out (the babashka.process wd.clj echo) ---
check e "$(run '(clojure.java.io/copy System/in System/out) (flush)' 'echoed')" "echoed"

# --- (f) the classes the JVM reports -----------------------------------------
# System.out / System.err are PrintStreams (java.io.OutputStream), NOT the
# PrintWriter *out* is. Ported code does (instance? java.io.PrintStream x) and
# (.write System/out bytes).
check f  "$(run '(println (class System/out))')" "java.io.PrintStream"
check f2 "$(run '(println (class System/err))')" "java.io.PrintStream"
check f3 "$(run '(println [(instance? java.io.PrintStream System/out) (instance? java.io.OutputStream System/out) (instance? java.io.Closeable System/out)])')" "[true true true]"
# *out* stays a PrintWriter, as on the JVM — the two are different objects there
# and jolt must not collapse their classes.
check g  "$(run '(println (class *out*))')" "java.io.PrintWriter"
check g2 "$(run '(println [(instance? java.io.Writer *out*) (instance? java.io.PrintStream *out*)])')" "[true false]"

# --- (h) System/out is the PROCESS stream: a with-out-str does not capture it --
# "direct" goes to the terminal, so the captured string is "captured" alone —
# resolving System/out through (current-output-port) like *out* used to swallow
# it into the capture instead, giving "direct\ncaptured".
check h "$(run '(let [s (with-out-str (.println System/out "direct") (print "captured"))] (println (pr-str s)))')" "\"captured\""
# and a (binding [*out* …]) does not move it either
check h2 "$(run '(let [w (java.io.StringWriter.)] (binding [*out* w] (.println System/out "direct")) (println (pr-str (str w))))')" "\"\""

# --- (k) .write on a stream: bytes, chars, an int, and a region ---------------
# (.write System/out (.getBytes s)) is the ordinary way ported code writes raw
# output to a PrintStream; the array used to render as "#object[[B …]" into the
# stream. write(int) is the CHARACTER with that code on both PrintStream and
# PrintWriter, and the 3-arg form is (buf off len), not (buf start end).
check k  "$(run '(.write System/out (.getBytes "bytes-out")) (flush)')" "bytes-out"
check k2 "$(run '(.write System/out (.getBytes "0123456789") 2 3) (flush)')" "234"
check k3 "$(run '(do (.write System/out 65) (.write System/out 66) (flush))')" "AB"
# the same three through a StringWriter, so the writer family agrees with the
# stream family instead of each rendering its own way
check k4 "$(run '(let [w (java.io.StringWriter.)] (.write w (.getBytes "abc")) (.write w 68) (.write w "0123456789" 2 3) (println (str w)))')" "abcD234"
# a char[] is its characters for write AND print (the JVM has an overload for
# both); a byte[] only for write, since print(Object) is all it can reach.
check k5 "$(run '(let [w (java.io.StringWriter.)] (.write w (char-array [\x \y])) (.write w (char-array [\z]) 0 1) (println (str w)))')" "xyz"

# --- (i) setIn replaces the stream -------------------------------------------
# read-line reads System/in, so setIn has to redirect it (clojure.test fixtures
# and REPL harnesses drive input this way).
check i "$(run '(System/setIn (java.io.ByteArrayInputStream. (.getBytes "line1\nline2\n"))) (println (pr-str [(read-line) (read-line) (read-line)]))')" "[\"line1\" \"line2\" nil]"
check i2 "$(run '(System/setIn (java.io.ByteArrayInputStream. (.getBytes "xy"))) (println (slurp System/in))')" "xy"

# --- (j) the default System/in is restored-able and reads real stdin ---------
check j "$(run '(let [orig System/in] (System/setIn (java.io.ByteArrayInputStream. (.getBytes ""))) (System/setIn orig) (println (slurp System/in)))' 'back')" "back"

echo ""
echo "system-streams smoke: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
