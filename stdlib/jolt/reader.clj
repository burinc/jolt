(ns jolt.reader
  "Reader macros: extend jolt's `#` dispatch table from Clojure.

  Clojure's dispatch table is closed. After a `#` the reader claims a fixed set
  of characters, a letter starts a data-reader tag, and every other character is
  a read error — `#$\"x\"` is \"No dispatch macro for: $\" on the JVM, in every
  version. jolt owns its reader, so the punctuation half of that table is open:
  register a function for one character and `#<char>` reads through it from then
  on.

  jolt ships one reader macro on this seam, `#$` for string interpolation:

      (let [x 3] #$\"a ~{x} b ~(inc x)\")   ;=> \"a 3 b 4\"

  See `clojure.core.strint` for the same interpolation as a macro. `#$` is a
  registration like any other — `dispatch-macros` lists it and
  `remove-dispatch-macro!` takes it off.

  ## Two tiers

  The default tier reads the next form normally and hands it to your function,
  which returns the form to read in its place:

      (set-dispatch-macro! \\% (fn [form] (list 'quote form)))
      #%(a b)                                ;=> (a b), unevaluated

  The `{:raw true}` tier hands your function the source string and the index
  just past the dispatch character, and it returns `[form end-index]` — the
  form to read and where reading resumes. It is what a literal whose body is
  not Clojure data needs (a raw string, a heredoc):

      (set-dispatch-macro! \\|
        (fn [src i]
          (let [end (.indexOf src \"|\" i)]
            [(subs src i end) (inc end)]))
        {:raw true})
      #|C:\\new|                             ;=> \"C:\\\\new\"

  `end-index` must be greater than the dispatch character's own index and no
  greater than the length of the source; a reader that returns anything else
  raises rather than spinning or reading past the end.

  ## When a registration takes effect

  Registration is a runtime call, and jolt reads a file one top-level form at a
  time, so a `#<char>` is read through whatever is registered *at that moment*.
  A file can register a macro and use it below in the same file, but not in the
  same top-level form. Registration is process-wide, not per-namespace: like
  Common Lisp's `set-dispatch-macro-character`, and unlike a `:require`, it
  changes how everything read afterwards reads.

  `jolt build` loads the app from source before it scans it for requires, so a
  built binary reads the same source the same way a `jolt run` does.

  Only punctuation can carry a reader macro. A character the reader already
  claims (`#{ #( #\" #_ #! #' #^ ## #= #? #:`) and a letter or digit (which
  begin a `#tag` — a `#s` reader would swallow every `#some/tag`) both raise at
  registration rather than shadowing what is there.

  `clojure.edn` never consults the table: edn is a closed grammar with no user
  extension point, so `#$` in edn stays the unreadable tag it always was."
  (:require [jolt.host :as host]))

(defn set-dispatch-macro!
  "Register F as the reader macro for `#CH`. Returns nil.

  With no opts, F is `(fn [form] new-form)`: the next form is read normally and
  F returns the form that replaces it. With `{:raw true}`, F is
  `(fn [src i] [form end-index])` and reads the source itself from index I.

  Re-registering CH replaces the previous macro. CH must be a punctuation
  character the reader does not already claim; see the namespace docstring."
  ([ch f] (set-dispatch-macro! ch f nil))
  ([ch f opts] (host/set-dispatch-macro! ch f (boolean (:raw opts)))))

(defn remove-dispatch-macro!
  "Unregister the reader macro for `#CH`, so `#CH` reads as it did before.
  Returns nil; removing a character that has no macro is a no-op."
  [ch]
  (host/remove-dispatch-macro! ch))

(defn dispatch-macros
  "The registered reader macros, as a map of character to function. Includes
  jolt's own `#$`."
  []
  (host/dispatch-macros))
