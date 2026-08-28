(ns clojure.core.strint
  "String interpolation: `<<` concatenates a string literal with the expressions
  written inside it.

  The `~{}` / `~()` grammar and the `<<` name are `clojure.core.strint` from
  core.incubator, which has sat outside Clojure proper since 2010. jolt ships it
  here under the same namespace so code written against it runs unchanged, and
  reads the same grammar at the reader level as `#$\"…\"` — see `jolt.reader`.

      (let [v 30.5]
        (<< \"This trial required ~{v}ml of solution.\"))
      ;=> \"This trial required 30.5ml of solution.\"

      (let [m {:a [1 2 3]}]
        (<< \"The total for your order is ~(->> m :a (apply +)).\"))
      ;=> \"The total for your order is 6.\""
  (:require [jolt.host :as host]))

(defmacro <<
  "Concatenate STRINGS, evaluating the expressions embedded in them.

  `~{form}` and `~(form ...)` both splice the value of the form; the braces are
  there so a bare name needs no parens. A `~` not followed by `{` or `(` is
  literal, so a literal `~{` is written `~{\"~{\"}`. Quotes inside an embedded
  form must be escaped, since the whole thing is one string literal.

  The arguments are read at macroexpansion, so they must be string literals."
  [& strings]
  (doseq [s strings]
    (when-not (string? s)
      (throw (IllegalArgumentException.
              (str "<< takes string literals, got " (pr-str s))))))
  `(str ~@(mapcat host/interpolate-parts strings)))
