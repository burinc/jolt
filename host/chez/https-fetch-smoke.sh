#!/bin/sh
# Network smoke for jolt.mvn-http: fetch a small real artifact over
# cert-verifying HTTPS from both Maven Central and Clojars, and assert the body
# landed as a non-empty file with the expected content. NOT in `make test` on
# Linux and macOS — it needs network + a working system OpenSSL; run with:
# make httpsfetch. The Windows CI job runs it twice (a forward-slash and a
# backslash TMPDIR), because a live fetch is the only proof that the Windows
# transport — ws2_32 sockets and the OpenSSL discovered under Git for Windows —
# works; JOLT_HTTPS_EXPECT_LIBDIR there names the directory both libraries
# must have come from, since a fetch that succeeded says nothing about which
# candidate answered (the runner image has an OpenSSL on PATH of its own).
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
JOLTC="${JOLTC:-bin/jolt}"

fails=0

# The download path takes TMPDIR's own separator, so a backslash TMPDIR yields
# the all-backslash spelling a Windows %TEMP% produces, not a mixed one.
case "${TMPDIR:-}" in *\\*) sep='\' ;; *) sep=/ ;; esac

# The URL and the path reach the program through the environment, never
# interpolated into Clojure source: a backslash path is not a string literal.
fetch_expr='(require (quote [jolt.mvn-http]))
            (let [ok (jolt.mvn-http/fetch (System/getenv "JOLT_HTTPS_FETCH_URL")
                                          (System/getenv "JOLT_HTTPS_FETCH_TMP"))
                  libs (jolt.mvn-http/loaded-native-libraries)]
              (println (str (if ok :ok :fail) (char 9) (:crypto libs) (char 9) (:ssl libs))))'

# fetch URL -> tmp; assert the file is non-empty and its first line looks like a
# Maven pom (<?xml ...> or <project ...>). $1 = label, $2 = url.
check_pom () {
  label="$1"; url="$2"; tmp="${TMPDIR:-/tmp}${sep}jolt-http-$$"
  rm -f "$tmp"
  line="$(JOLT_HTTPS_FETCH_URL="$url" JOLT_HTTPS_FETCH_TMP="$tmp" $JOLTC -e "$fetch_expr" 2>&1 | tail -1)"
  got="$(printf '%s\n' "$line" | cut -f1)"
  crypto="$(printf '%s\n' "$line" | cut -f2)"
  ssl="$(printf '%s\n' "$line" | cut -f3)"
  if [ "$got" != ":ok" ]; then
    printf '%s\n' "https-fetch: FAIL $label — fetch returned $line"
    fails=$((fails + 1)); rm -f "$tmp"; return
  fi
  if [ ! -s "$tmp" ]; then
    echo "https-fetch: FAIL $label — empty body"
    fails=$((fails + 1)); rm -f "$tmp"; return
  fi
  if ! head -c 200 "$tmp" | grep -Eq '<\?xml|<project'; then
    echo "https-fetch: FAIL $label — body is not a pom (first bytes:)"
    head -c 60 "$tmp"; echo
    fails=$((fails + 1)); rm -f "$tmp"; return
  fi
  if [ -n "${JOLT_HTTPS_EXPECT_LIBDIR:-}" ]; then
    want="$(printf '%s\n' "$JOLT_HTTPS_EXPECT_LIBDIR" | tr '\\' '/')"
    for lib in "$crypto" "$ssl"; do
      case "$(printf '%s\n' "$lib" | tr '\\' '/')" in
        *"$want"*) ;;
        *) # printf: a backslash path must not be read as escapes by echo
           printf '%s\n' "https-fetch: FAIL $label — $lib did not come from $JOLT_HTTPS_EXPECT_LIBDIR"
           fails=$((fails + 1)); rm -f "$tmp"; return ;;
      esac
    done
  fi
  printf '%s\n' "https-fetch: PASS $label ($(wc -c < "$tmp" | tr -d ' ') bytes; $crypto, $ssl)"
  rm -f "$tmp"
}

# Central: a pom is small and plaintext, ideal for a content check.
check_pom "central" "https://repo1.maven.org/maven2/org/clojure/math.combinatorics/0.2.0/math.combinatorics-0.2.0.pom"
# Clojars-hosted artifact (math.combinatorics is Central-only; clj-http is on Clojars).
check_pom "clojars" "https://repo.clojars.org/clj-http/clj-http/3.12.3/clj-http-3.12.3.pom"

if [ "$fails" -ne 0 ]; then
  echo "https-fetch: FAILED — $fails check(s) failed"
  exit 1
fi
echo "https-fetch: passed"
