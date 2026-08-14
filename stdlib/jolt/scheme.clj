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
