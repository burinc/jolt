;; jutil-colls.ss — what makes a mutable java.util collection shim a
;; java.util.Map / Set / List to the rest of the runtime: = against the
;; persistent collections, hash, pr and str, reduce-kv, seqable?. Shared by
;; every target. Each shim registers its tag here with its KIND and a procedure
;; listing its live elements in iteration order; nothing below knows how a shim
;; stores them. host-static-classes.ss registers HashMap / HashSet / the
;; ArrayList family, tree-map.ss the TreeMap and TreeSet views.
;;
;; The JVM answers these questions from the interfaces, not the classes, which
;; is why one registry serves them all:
;;   - APersistentMap/Set/Vector.equiv accept any java.util.Map/Set/List, and a
;;     java.util collection's own equals accepts a persistent one, so (= hm {..})
;;     holds from both sides. Only a List is sequential: an ArrayDeque is a
;;     Collection and compares by identity.
;;   - hash of a non-IHashEq object is its hashCode, the java.util contract
;;     (Map: sum of key^value, Set: sum, List: 31*h+e), NOT the hasheq of the
;;     equal persistent collection.
;;   - pr prints a Map as a map literal, a Set as #{}, a RandomAccess List as
;;     [], any other List as (); print (readably false) and anything else is
;;     #object[class toString]; str is toString — {k=v, …} or [a, b].
;;
;; Needs the jhost record and register-host-methods! (host-static.ss on Chez,
;; host/gambit/host-statics.ss), the arm registries (values.ss, printing.ss,
;; converters.ss) and jolt-java-hashcode (natives-misc.ss). Loads before
;; host-static-classes.ss, which registers into it.

;; ---- the registry -------------------------------------------------------------
;; tag -> #(kind elems). kind is one of
;;   map     java.util.Map; elems answers map entries
;;   set     java.util.Set
;;   entries a Map's entrySet: a Set whose members are map entries, which
;;           hash and print the way Map.Entry does (k^v, k=v)
;;   ralist  a RandomAccess java.util.List (ArrayList, Arrays$ArrayList)
;;   list    any other java.util.List (LinkedList)
;;   coll    a Collection that is none of those (ArrayDeque): str only
(define jutil-colls-tbl (make-hashtable string-hash string=?))
(define (register-jutil-coll! tag kind elems)
  (hashtable-set! jutil-colls-tbl tag (vector kind elems))
  (register-host-methods! tag (jutil-object-methods kind)))
(define (jutil-coll-entry x)
  (and (jhost? x) (hashtable-ref jutil-colls-tbl (jhost-tag x) #f)))
(define (jutil-coll-kind x)
  (let ((e (jutil-coll-entry x))) (and e (vector-ref e 0))))
(define (jutil-coll-elems x) ((vector-ref (jutil-coll-entry x) 1) x))
;; a shim the JVM compares by contents (everything but a bare Collection)
(define (jutil-equiv-coll? x)
  (let ((k (jutil-coll-kind x))) (and k (not (eq? k 'coll)))))
;; Iterable on the JVM: seq, seqable?, reduce walk it. post-prelude's seqable?
;; consults this.
(define (jhost-seqable-shim? x) (and (jutil-coll-kind x) #t))

;; ---- equality -----------------------------------------------------------------
;; A shim compares as the persistent collection with the same contents, which is
;; exactly the java.util contract the persistent side checks on the JVM (a Map's
;; entries, a Set's members, a List's elements in order). The converted value is
;; never a shim, so the re-dispatch cannot come back here.
(define (jutil-coll->persistent x)
  (case (jutil-coll-kind x)
    ((map) (fold-left (lambda (m e) (pmap-assoc m (jolt-nth e 0) (jolt-nth e 1)))
                      empty-pmap (jutil-coll-elems x)))
    ((set entries) (fold-left pset-conj empty-pset (jutil-coll-elems x)))
    ((ralist list) (apply jolt-vector (jutil-coll-elems x)))
    (else x)))
(define (jutil-plain x) (if (jutil-equiv-coll? x) (jutil-coll->persistent x) x))
(define (jutil-equals? a b)
  (if (jolt=2 (jutil-plain a) (jutil-plain b)) #t #f))
(register-eq-arm! (lambda (a b) (or (jutil-equiv-coll? a) (jutil-equiv-coll? b)))
                  jutil-equals?)

;; ---- hashCode -----------------------------------------------------------------
(define (jutil-hash-code x)
  (case (jutil-coll-kind x)
    ((map entries) (fold-left (lambda (h e)
                        (i32 (+ h (bitwise-xor (jolt-java-hashcode (jolt-nth e 0))
                                               (jolt-java-hashcode (jolt-nth e 1))))))
                      0 (jutil-coll-elems x)))
    ((set) (fold-left (lambda (h e) (i32 (+ h (jolt-java-hashcode e)))) 0 (jutil-coll-elems x)))
    (else (fold-left (lambda (h e) (i32 (+ (* 31 h) (jolt-java-hashcode e)))) 1
                     (jutil-coll-elems x)))))
(register-hash-arm! jutil-equiv-coll? jutil-hash-code)

;; ---- toString -----------------------------------------------------------------
;; String.valueOf of each element: null is "null", a collection holding itself
;; renders "(this Map)" / "(this Collection)" instead of recursing forever.
(define (jutil-elem-string self x)
  (cond ((eq? x self) (if (eq? (jutil-coll-kind self) 'map) "(this Map)" "(this Collection)"))
        ((jolt-nil? x) "null")
        (else (jolt-str-one x))))
(define (jutil-entry-string self e)
  (string-append (jutil-elem-string self (jolt-nth e 0)) "=" (jutil-elem-string self (jolt-nth e 1))))
(define (jutil-to-string x)
  (if (eq? (jutil-coll-kind x) 'map)
      (string-append "{"
        (jolt-str-join-comma (map (lambda (e) (jutil-entry-string x e)) (jutil-coll-elems x)))
        "}")
      (string-append "["
        (jolt-str-join-comma
          (map (if (eq? (jutil-coll-kind x) 'entries)
                   (lambda (e) (jutil-entry-string x e))
                   (lambda (e) (jutil-elem-string x e)))
               (jutil-coll-elems x)))
        "]")))
(register-str-render! jutil-coll-kind jutil-to-string)

;; ---- pr -----------------------------------------------------------------------
;; The readable printer's map/set/list shapes, honoring *print-length* and
;; *print-level* like the persistent ones. A java.util.Map does not lift a shared
;; namespace (print-map, not the IPersistentMap method). Printed with
;; *print-readably* off — print / println — the JVM falls back to #object, which
;; is jolt-object-repr over the toString above.
(define (jutil-pr x)
  (if (not (jolt-pr-readable?))
      (jolt-object-repr x #f)
      (let ((kind (jutil-coll-kind x)))
        (if (jolt-print-hash?) "#"
            (with-deeper-print
              (let ((s (list->cseq (jutil-coll-elems x))))
                (case kind
                  ((map) (string-append "{"
                           (jolt-str-join-comma
                             (jolt-limited-seq-strs s
                               (lambda (e) (string-append (jolt-pr-readable (jolt-nth e 0)) " "
                                                          (jolt-pr-readable (jolt-nth e 1))))))
                           "}"))
                  ((set entries) (string-append "#{" (jolt-str-join (jolt-limited-seq-strs s jolt-pr-readable)) "}"))
                  ((ralist) (string-append "[" (jolt-str-join (jolt-limited-seq-strs s jolt-pr-readable)) "]"))
                  (else (string-append "(" (jolt-str-join (jolt-limited-seq-strs s jolt-pr-readable)) ")")))))))))
(register-pr-readable-arm! jutil-equiv-coll? jutil-pr)

;; ---- reduce-kv ----------------------------------------------------------------
;; IKVReduce is extended to java.util.Map: (reduce-kv f init a-HashMap) walks its
;; entries (seq.ss consults this hook before refusing the value).
(set! jolt-reduce-kv-entries
  (lambda (x) (and (eq? (jutil-coll-kind x) 'map) (jutil-coll-elems x))))

;; ---- the Object methods every registered shim answers --------------------------
(define (jutil-object-methods kind)
  (cons (cons "toString" (lambda (self) (jutil-to-string self)))
        (if (eq? kind 'coll)
            '()
            (list (cons "equals" (lambda (self o) (jutil-equals? self o)))
                  (cons "hashCode" (lambda (self) (jutil-hash-code self)))))))

;; ---- java.util.Map$Entry host objects ----------------------------------------------
;; An entry a java.util shim hands out (TreeMap$Entry, SimpleImmutableEntry)
;; registers its tag with a procedure answering its (key . value). That is what
;; makes it a Map.Entry to the rest of the runtime: map-entry?, key / val, nth
;; and destructuring, count, conj onto a map (collections.ss jolt-host-entry),
;; = against another Map.Entry by key and value (and never against a vector:
;; a MapEntry's equiv wants a List), hash as Map.Entry.hashCode (k ^ v), and
;; str as k=v. pr is the #object form over that toString, as on the JVM.
(define jutil-entry-tbl (make-hashtable string-hash string=?))
(define (register-jutil-entry! tag kv)
  (hashtable-set! jutil-entry-tbl tag kv)
  (register-host-methods! tag
    (list (cons "getKey" (lambda (self) (car (kv self))))
          (cons "getValue" (lambda (self) (cdr (kv self))))
          (cons "toString" (lambda (self) (jutil-entry-string-of self)))
          (cons "equals" (lambda (self o) (jutil-entry-equals? self o)))
          (cons "hashCode" (lambda (self) (jutil-entry-hash self))))))
(define (jutil-entry-kv x)
  (and (jhost? x)
       (let ((f (hashtable-ref jutil-entry-tbl (jhost-tag x) #f)))
         (and f (f x)))))
(define (jutil-entry? x)
  (and (jhost? x) (hashtable-ref jutil-entry-tbl (jhost-tag x) #f) #t))
(set! jolt-host-entry jutil-entry-kv)
(define (jutil-entry-string-of x)
  (let ((kv (jutil-entry-kv x)))
    (string-append (jutil-elem-string x (car kv)) "=" (jutil-elem-string x (cdr kv)))))
(define (jutil-entry-equals? a b)
  (let ((ka (jutil-entry-kv a)) (kb (jutil-entry-kv b)))
    (and ka kb (jolt=2 (car ka) (car kb)) (jolt=2 (cdr ka) (cdr kb)) #t)))
(define (jutil-entry-hash x)
  (let ((kv (jutil-entry-kv x)))
    (i32 (bitwise-xor (jolt-java-hashcode (car kv)) (jolt-java-hashcode (cdr kv))))))
(register-eq-arm! (lambda (a b) (and (jutil-entry? a) (jutil-entry? b))) jutil-entry-equals?)
(register-hash-arm! jutil-entry? jutil-entry-hash)
(register-str-render! jutil-entry? jutil-entry-string-of)
(register-count-arm! jutil-entry? (lambda (x) 2))
;; map-entry? is (instance? java.util.Map$Entry x) on the JVM
(def-var! "clojure.core" "map-entry?"
  (lambda (x) (or (jolt-map-entry? x) (jutil-entry? x))))

;; ---- host Comparator objects -------------------------------------------------------
;; The comparator seam (natives-seq.ss jolt-comparator-fn) asks whether a value
;; is a shim object whose tag registers a `compare` method — a Comparator held
;; by the host (String/CASE_INSENSITIVE_ORDER, Comparator/reverseOrder) rather
;; than by a deftype/reify. Both targets carry jhost, so both answer it.
(set! jhost-compare-method?
  (lambda (x)
    (and (jhost? x) (host-method-ref (jhost-tag x) "compare") #t)))
