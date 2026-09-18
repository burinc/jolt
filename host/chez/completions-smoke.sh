#!/bin/sh
# completions-smoke.sh — `jolt completions`: the name/doc lines a completing
# shell asks for, and the three snippets it can install.
#
# The snippets are checked two ways, because they fail differently. `zsh -n` /
# `bash -n` catch a snippet that will not parse, which is what a generator
# emitting shell text gets wrong most often. Then the bash function is actually
# RUN against a project and its COMPREPLY asserted, because a snippet can parse
# perfectly and still offer nothing: the first zsh draft of this feature defined
# its function and never called it under autoload, which no syntax check sees.
#
# JOLT_BIN overrides the binary under test. Offline, throwaway project in a
# temp dir.
set -u
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
JOLT="${JOLT_BIN:-bin/jolt}"
case "$JOLT" in /*) JOLT_ABS="$JOLT" ;; *) JOLT_ABS="$root/$JOLT" ;; esac
export JOLT_EXE="$JOLT_ABS"
export JOLT_NO_USER_DEPS=1
# Never read or write the developer's real completion cache from a gate.
export JOLT_COMPLETION_NO_CACHE=1
pass=0; fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check() { # label expected actual
  if [ "$2" = "$3" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "  FAIL: $1" >&2
    echo "    expected: $2" >&2
    echo "    got:      $3" >&2
  fi
}

proj="$tmp/proj"
mkdir -p "$proj"
cat > "$proj/bb.edn" <<'EOF'
{:tasks
 {alpha   {:doc "one line" :task (println 1)}
  beta    {:doc "first line\nsecond line" :task (println 2)}
  build:x {:doc "a colon in the name" :task (println 3)}
  quiet   {:doc "hidden" :private true :task (println 4)}
  -dash   {:doc "also hidden" :task (println 5)}
  gamma   (println 6)
  ;; Two tasks named after built-in commands. `build` does not ask to override,
  ;; so `jolt build` is the compiler and the completion must describe THAT.
  ;; `path` does ask, so the task is what runs and the task is what to describe.
  build   {:doc "loses to the build command" :task (println 7)}
  path    {:doc "wins the path name" :override-builtin true :task (println 8)}}}
EOF

run() { d="$1"; shift; JOLT_PWD="$d" JOLT_QUIET=1 "$JOLT_ABS" "$@" 2>&1; }

# --- the name/doc lines ------------------------------------------------------

out="$(run "$proj" completions tasks)"
check "a task with a :doc is name<TAB>doc" "alpha	one line" \
  "$(printf '%s\n' "$out" | grep '^alpha')"
check "only the first line of a :doc" "beta	first line" \
  "$(printf '%s\n' "$out" | grep '^beta')"
check "a doc-less task is a bare name" "gamma" \
  "$(printf '%s\n' "$out" | grep '^gamma')"
check "a colon in a task name survives" "build:x	a colon in the name" \
  "$(printf '%s\n' "$out" | grep '^build:x')"
check ":private stays out" "" "$(printf '%s\n' "$out" | grep '^quiet')"
check "a -dash name stays out" "" "$(printf '%s\n' "$out" | grep '^-dash')"
# A description is a promise about what the word will do, so a task that LOSES
# its name to a built-in must not carry one: `jolt build` is the compiler here.
check "a task that loses to a builtin stays out" "" \
  "$(printf '%s\n' "$out" | grep '^build	')"
check "...and one that overrides a builtin is in" "path	wins the path name" \
  "$(printf '%s\n' "$out" | grep '^path')"
check "one line per offered task" "5" "$(printf '%s\n' "$out" | grep -c .)"

check "a project with no tasks says nothing" "" "$(run "$tmp" completions tasks)"
check "...and exits 0" "0" \
  "$(JOLT_PWD="$tmp" "$JOLT_ABS" completions tasks >/dev/null 2>&1; echo $?)"

# --- the snippets ------------------------------------------------------------

for sh_name in zsh bash fish; do
  snip="$tmp/snip.$sh_name"
  run "$proj" completions "$sh_name" > "$snip"
  check "completions $sh_name emits something" "yes" \
    "$([ -s "$snip" ] && echo yes || echo no)"
done

# A generated snippet that does not parse is the failure mode of emitting shell
# from a string, so parse each with its own shell where that shell exists.
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$tmp/snip.zsh" 2>/dev/null
  check "the zsh snippet parses" "0" "$?"
  grep -q 'loadautofunc' "$tmp/snip.zsh"
  check "the zsh snippet handles autoload as well as source" "0" "$?"
fi
if command -v bash >/dev/null 2>&1; then
  bash -n "$tmp/snip.bash" 2>/dev/null
  check "the bash snippet parses" "0" "$?"
fi

check "an unknown shell is an error" "1" \
  "$(JOLT_PWD="$proj" "$JOLT_ABS" completions klingon >/dev/null 2>&1; echo $?)"
check "completions with no argument is an error" "1" \
  "$(JOLT_PWD="$proj" "$JOLT_ABS" completions >/dev/null 2>&1; echo $?)"

# --- the bash function, actually run -----------------------------------------
#
# Parsing is not offering. This sources the snippet and asks it what `jolt b`
# completes to, which is the only check here that would have caught a function
# that loads and returns nothing.
if command -v bash >/dev/null 2>&1; then
  got="$(cd "$proj" && PATH="$(dirname "$JOLT_ABS"):$PATH" \
    bash --noprofile --norc -c '
      set -u
      . "$1"
      COMP_WORDS=(jolt b); COMP_CWORD=1
      _jolt_completions
      printf "%s\n" "${COMPREPLY[@]}" | sort | tr "\n" " "
    ' _ "$tmp/snip.bash" 2>/dev/null)"
  check "the bash function offers the build command and both b-tasks" \
    "beta build build:x " "$got"
fi

# --- the zsh function's candidates, with descriptions ------------------------
#
# The bash check above cannot see this class of bug at all: bash has no
# description column, so a candidate carrying the WRONG description looks
# identical to a right one. Stubbing _describe and calling the real function is
# enough to read the pairs back without a pty or the completion system, and it
# is what caught `build` being described as the compiler in a project whose
# `build` task overrides it.
if command -v zsh >/dev/null 2>&1; then
  desc="$(cd "$proj" && PATH="$(dirname "$JOLT_ABS"):$PATH" \
    zsh -f -c '
      _describe() { local n=${@[-1]}; print -l -- ${(P)n}; }
      _files()   { : }
      _message() { : }
      _alternative() { : }
      _arguments()   { : }
      compdef()  { : }
      source "$1"
      words=(jolt ""); CURRENT=2
      _jolt
    ' _ "$tmp/snip.zsh" 2>/dev/null)"
  check "a task that wins a builtin's name carries the TASK's description" \
    "path:wins the path name" \
    "$(printf '%s\n' "$desc" | grep '^path:')"
  check "...and the builtin it displaced is not offered twice" "1" \
    "$(printf '%s\n' "$desc" | grep -c '^path:')"
  check "a builtin no task took keeps its own description" \
    "tasks:list the project's bb.edn/deps.edn :tasks" \
    "$(printf '%s\n' "$desc" | grep '^tasks:')"
  # -Fx, because `^build:` also matches the unrelated `build:x` task, which is
  # exactly the kind of near-miss a loose pattern turns into a false pass.
  check "a task that lost its name is described as the builtin" "yes" \
    "$(printf '%s\n' "$desc" \
       | grep -Fxq 'build:compile a standalone binary or shared library' \
       && echo yes || echo no)"
fi

# --- the cache actually caching ----------------------------------------------
#
# The whole design is "do not spawn jolt on a TAB press", so the thing to assert
# is the spawn count, not the snippet's text. A shim on PATH counts the calls.
#
# This is what catches the mtime spelling: `stat -c %Y` is GNU's mtime, and `-f`
# there is a filesystem query that prints a block table and exits 1, so trying
# BSD's `-f %m` first puts free-block counts in the stamp. Free blocks move on a
# live disk, so the stamp differs from the one on disk and the cache never hits
# -- on every Linux, invisibly, since the completion still returns right answers.
if command -v bash >/dev/null 2>&1; then
  shim="$tmp/shim"; mkdir -p "$shim"
  cat > "$shim/jolt" <<EOF
#!/bin/sh
echo call >> "$tmp/calls"
exec "$JOLT_ABS" "\$@"
EOF
  chmod +x "$shim/jolt"
  : > "$tmp/calls"
  cachedir="$tmp/xdg"
  # JOLT_COMPLETION_NO_CACHE is exported empty here on purpose: the gate sets it
  # to 1 so no check touches the developer's real cache, and this is the one
  # group that has to let the cache work.
  presses() { # count
    n=0
    while [ "$n" -lt "$1" ]; do
      ( cd "$proj" && PATH="$shim:$PATH" XDG_CACHE_HOME="$cachedir" \
        JOLT_COMPLETION_NO_CACHE= bash --noprofile --norc -c '
          set -u
          . "$1"
          _jolt_cached_tasks
        ' _ "$tmp/snip.bash" 2>/dev/null )
      n=$((n+1))
    done
  }
  out2="$(presses 2)"
  check "two presses spawn jolt once" "1" "$(grep -c . "$tmp/calls")"
  check "...and the cached press answers with the tasks" "yes" \
    "$(printf '%s\n' "$out2" | grep -q '^beta	first line$' && echo yes || echo no)"
  key="$(find "$cachedir/jolt/completion" -type f 2>/dev/null | head -n 1)"
  check "the stamp is the two mtimes and nothing else" "yes" \
    "$(head -n 1 "$key" 2>/dev/null | grep -Eq '^[0-9]*/[0-9]*$' && echo yes || echo no)"
  # A whole second, because the stamp is mtime in seconds.
  sleep 1
  touch "$proj/bb.edn"
  presses 1 >/dev/null
  check "editing bb.edn invalidates the cache" "2" "$(grep -c . "$tmp/calls")"
fi

# --- the fish snippet --------------------------------------------------------
#
# fish has no per-press file cache: its completion function stays loaded for the
# session, so the cache lives in shell variables and has to be keyed on the
# directory it was filled from, or the next project you cd into is offered the
# first one's tasks.
if command -v fish >/dev/null 2>&1; then
  fish -n "$tmp/snip.fish" 2>/dev/null
  check "the fish snippet parses" "0" "$?"
fi
grep -q '__jolt_tasks_dir' "$tmp/snip.fish"
check "the fish cache is keyed on the directory" "0" "$?"
grep -q 'test -f deps.edn' "$tmp/snip.fish"
check "fish asks jolt only inside a project" "0" "$?"
grep -q "a '\-Sdeps'" "$tmp/snip.fish"
check "the fish snippet offers jolt's options too" "0" "$?"

# --- the one list that is written twice --------------------------------------
#
# Which commands a task may take the name of is spelled out in jolt.main, which
# dispatches on it, and again in jolt.completions, which filters on it. A name
# in main's set but not the completion's hides a task that actually runs; a name
# in the completion's but not main's offers a task that the command wins. Source
# check, because neither list is reachable from outside its namespace.
ov_words() { grep -o '"[a-zA-Z-]*"' | tr -d '"' | sort -u | tr '\n' ' '; }
check "main and the completion agree on which commands a task can override" \
  "$(grep -B1 'builtin-overridden? cmd)' jolt-core/jolt/main.clj \
     | grep -o '#{[^}]*}' | ov_words)" \
  "$(sed -n '/def ^:private overridable/,/}/p' jolt-core/jolt/completions.clj \
     | grep -o '#{[^}]*}' | ov_words)"

echo "completions-smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
