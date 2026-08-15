;; jolt.scheme — the Scheme escape hatch. The portable interop layers (the
;; Java-shaped shims, jolt.ffi for C, the curated jolt.host seams) cover what
;; libraries need; this namespace is the level under them: call a host Scheme
;; procedure by name, or evaluate Scheme text, from any jolt program.
;;
;; The contract is RAW — no marshaling layer. Numbers, strings, booleans and
;; characters are the same representations on both sides and cross untouched;
;; everything else crosses as whatever it is on the other side. A Scheme
;; vector arriving in jolt is an opaque host value (hand it back to Scheme to
;; use it); a jolt collection handed to Scheme is jolt's representation, not a
;; Scheme list; nil is jolt's nil, not '() and not #f.
;;
;; Two caveats. Code using this namespace is HOST-SPECIFIC by design — tied to
;; the Chez runtime and its primitives, unlike everything else in the stdlib.
;; And names resolve at RUN time, so a tree-shaken binary only finds what the
;; kept runtime still carries: a shaken-out binding is a catchable
;; "no top-level Scheme binding" error, never a silent nil.
(ns jolt.scheme)

(defn proc
  "The top-level Scheme procedure named by scheme-name (a string), as a
  callable value. Resolved now; throws when the name is unbound."
  [scheme-name]
  (jolt.host/scheme-proc scheme-name))

(defn call
  "Resolve the top-level Scheme procedure named by scheme-name and apply it
  to args. Values cross raw — see the namespace docs."
  [scheme-name & args]
  (apply (jolt.host/scheme-proc scheme-name) args))

(defn eval-string
  "Evaluate s as Scheme text — read with the SCHEME reader, not jolt's — and
  return the last form's value. Definitions persist in the interaction
  environment."
  [s]
  (jolt.host/scheme-eval-string s))

(defmacro defsfn
  "Def name to the top-level Scheme procedure named by scheme-name:
  (defsfn fx+ \"fx+\") then (fx+ 1 2). Resolution happens at load time."
  [name scheme-name]
  (list 'def name (list 'jolt.scheme/proc scheme-name)))

;; --- (scheme ...): inline Scheme, do-shaped ----------------------------------
;; The body is READ BY JOLT (the two syntaxes share the s-expression family),
;; so Scheme spellings jolt's reader rejects are written in jolt spellings and
;; rendered across: true/false -> #t/#f, \\A -> #\\A, [1 2 3] -> the datum
;; vector #(1 2 3), nil -> jolt-nil (the runtime's nil value, a bound host
;; global). Strings, numbers, and ratios print compatibly. Keywords, maps, and
;; sets have no Scheme reading and are refused at macroexpansion. Reader sugar
;; that expands to clojure.core calls (@x, syntax-quote) lands as unbound
;; Scheme names — write (unquote ...) longhand or avoid it.

(def ^:private scheme-char-names
  {\newline "#\\newline" \space "#\\space" \tab "#\\tab"
   \return "#\\return" \backspace "#\\backspace" \formfeed "#\\page"})

(defn- form->scheme
  "Render a jolt-read form as Scheme source text. quoted? tracks whether f
  sits inside (quote ...)/(quasiquote ...) — it decides only how a VECTOR
  renders: #(...) is a datum, not an expression, in R6RS, so an expression
  position gets (quote #(...)) and a datum position the bare literal.
  (unquote ...) under quasiquote re-enters expression position."
  ([f] (form->scheme f false))
  ([f quoted?]
   (cond
     (true? f)    "#t"
     (false? f)   "#f"
     (nil? f)     "jolt-nil"
     (symbol? f)  (str f)
     (string? f)  (pr-str f)
     (char? f)    (or (get scheme-char-names f) (str "#\\" f))
     (number? f)  (pr-str f)
     (vector? f)  (let [datum (str "#(" (apply str (interpose " " (map (fn [x] (form->scheme x true)) f))) ")")]
                    (if quoted? datum (str "(quote " datum ")")))
     (seq? f)
     (let [head (first f)]
       (cond
         (and (not quoted?) (= 2 (count f)) (or (= head 'quote) (= head 'quasiquote)))
         (str "(" head " " (form->scheme (second f) true) ")")
         (and quoted? (= 2 (count f)) (or (= head 'unquote) (= head 'unquote-splicing)))
         (str "(" head " " (form->scheme (second f) false) ")")
         :else
         (str "(" (apply str (interpose " " (map (fn [x] (form->scheme x quoted?)) f))) ")")))
     :else (throw (ex-info (str "form has no Scheme rendering: " (pr-str f)
                                (when (keyword? f) " (keywords are not Scheme syntax)"))
                           {:form f})))))

(defmacro scheme
  "Inline Scheme. The body forms are rendered to Scheme source at
  macroexpansion (see the spellings note above) and evaluated with the host's
  eval — multiple forms behave like (begin ...), so a define splices into the
  interaction environment and the LAST form's value is returned, as with do.
  Values cross on this namespace's raw contract."
  [& forms]
  (if (empty? forms)
    nil
    (list 'jolt.scheme/eval-string (form->scheme (cons 'begin forms)))))
