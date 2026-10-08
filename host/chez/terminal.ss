;; terminal.ss — the console under the interactive REPL's line editor, as
;; jolt.host vars over the adapter's terminal tier (sa-term-*, CONTRACT.txt
;; capability-terminal). jolt.line-editor is the only caller; everything about
;; editing lives there, this file only translates values: eof reads as nil, a
;; resize as :resize, the screen size as a (rows cols) list, and the motion and
;; clear regions as keywords.

(define term-kw-resize (keyword #f "resize"))

(define (term-kw->symbol who kw)
  (if (keyword-t? kw)
      (string->symbol (keyword-t-name kw))
      (error who "expected a keyword" kw)))

(def-var! "jolt.host" "term-open?" (lambda () (sa-term-open)))
(def-var! "jolt.host" "term-raw!" (lambda () (sa-term-raw!) jolt-nil))
(def-var! "jolt.host" "term-cooked!" (lambda () (sa-term-cooked!) jolt-nil))

(def-var! "jolt.host" "term-read-char"
  (lambda ()
    (let ((c (sa-term-read-char)))
      (cond ((eof-object? c) jolt-nil)
            ((eq? c 'resize) term-kw-resize)
            (else c)))))

(def-var! "jolt.host" "term-size"
  (lambda ()
    (let ((rc (sa-term-size)))
      (list->cseq (list (car rc) (cdr rc))))))

(def-var! "jolt.host" "term-write!"
  (lambda (s)
    (string-for-each sa-term-write-char s)
    jolt-nil))

(def-var! "jolt.host" "term-char-width" (lambda (c) (sa-term-char-width c)))
(def-var! "jolt.host" "term-flush!" (lambda () (sa-term-flush) jolt-nil))

(def-var! "jolt.host" "term-move!"
  (lambda (dir n)
    (sa-term-move! (term-kw->symbol 'term-move! dir) n)
    jolt-nil))

(def-var! "jolt.host" "term-clear!"
  (lambda (what)
    (sa-term-clear! (term-kw->symbol 'term-clear! what))
    jolt-nil))

(def-var! "jolt.host" "term-cr!" (lambda () (sa-term-cr!) jolt-nil))
(def-var! "jolt.host" "term-lf!" (lambda () (sa-term-lf!) jolt-nil))
(def-var! "jolt.host" "term-bell!" (lambda () (sa-term-bell!) jolt-nil))
(def-var! "jolt.host" "term-pause!" (lambda () (sa-term-pause!) jolt-nil))

(def-var! "jolt.host" "term-color!"
  (lambda (id background?)
    (sa-term-color! id (and background? (not (jolt-nil? background?))))
    jolt-nil))
