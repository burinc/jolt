;; The loader conformance suite. These twelve cases ARE the specification of
;; jolt.loader — per-context roots, isolation, delegation policy, and unload —
;; the way test/chez/corpus.edn is the specification of clojure.core. They are
;; written against the public API only, so a rewrite underneath is free as long
;; as the suite stays green.
;;
;; Run: bin/jolt run test/chez/loaderconf-test.clj  (make loaderconf gates it
;; against test/chez/loaderconf-known-failures.txt).
;;
;; Each case prints one CASE line; a case passes only if every check in it
;; passed and it did not throw. The gate compares the PASS/FAIL set against the
;; recorded baseline, so a case going green fails the gate until the baseline
;; says so, and a case going red fails it always.
(ns loaderconf-test
  (:require [jolt.loader :as l]
            [jolt.fs :as fs]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.core.async :as async]))

(def cases (atom []))
(def failures (atom []))

(defn chk [label ok] (when-not ok (swap! failures conj label)))

(defmacro defcase [n title & body]
  `(swap! cases conj [~n ~title (fn [] ~@body)]))

;; --- scratch roots ----------------------------------------------------------
;; Each case builds its own directories; a "library at two versions" is two
;; directories holding the same namespace name with different contents, which is
;; what a version-qualified extraction dir already gives us on disk.
(def tmp (str (fs/create-temp-dir {:prefix "loaderconf-"})))

(defn root-dir [name]
  (let [d (str tmp "/" name)]
    (.mkdirs (java.io.File. d))
    d))

(defn write! [dir file src]
  (spit (str dir "/" file) src)
  dir)

(defn val-of
  "The value a :var resolution answers with — the cell's current root."
  [cell]
  (when cell (deref cell)))

;; --- 1. two contexts, one library at two versions ---------------------------
(defcase 1 "v1/v2 isolation: two contexts hold one library at two versions"
  (let [d1 (write! (root-dir "v1") "libx.clj" "(ns libx) (defn version [] :v1)")
        d2 (write! (root-dir "v2") "libx.clj" "(ns libx) (defn version [] :v2)")
        c1 (l/classpath [d1] {:parent (l/root)})
        c2 (l/classpath [d2] {:parent (l/root)})]
    (l/load c1 {:kind :ns :name "libx"})
    (l/load c2 {:kind :ns :name "libx"})
    (let [v1 (l/resolve c1 {:kind :var :name "libx/version"})
          v2 (l/resolve c2 {:kind :var :name "libx/version"})]
      (chk "each context links libx/version" (and (some? v1) (some? v2)))
      (chk "the two links are different cells" (not (identical? v1 v2)))
      (chk "context 1 sees v1" (= :v1 ((val-of v1))))
      (chk "context 2 sees v2" (= :v2 ((val-of v2)))))))

;; --- 2. hermetic ------------------------------------------------------------
(defcase 2 "hermetic: an isolated context cannot see what the root has"
  (let [d (write! (root-dir "herm") "libh.clj" "(ns libh) (def marker :own)")
        ctx (l/classpath [d] {:parent (l/isolated)})]
    (chk "a namespace only the root has does not resolve"
         (empty? (l/find ctx {:kind :ns :name "clojure.string"})))
    (chk "a var only the root has does not resolve"
         (empty? (l/find ctx {:kind :var :name "clojure.core/inc"})))
    (chk "the context's own namespace still resolves"
         (seq (l/find ctx {:kind :ns :name "libh"})))))

;; --- 3. shared by reference -------------------------------------------------
;; The cell, not a copy: injecting a namespace into a context by handing it the
;; host's vars depends on this, and identical? is the only way to say it.
(defcase 3 "shared by reference: a delegated var is the same cell"
  (let [d (root-dir "shared")
        ctx (l/classpath [d] {:parent (l/root)})
        req {:kind :var :name "clojure.core/inc"}
        root-cell (:cell (first (l/find (l/root) req)))
        ctx-cell (:cell (first (l/find ctx req)))]
    (chk "the root answers with a cell" (some? root-cell))
    (chk "the delegating context answers with a cell" (some? ctx-cell))
    (chk "both answers are one object" (identical? root-cell ctx-cell))
    (chk "and that object is the live var" (identical? ctx-cell #'clojure.core/inc))))

;; --- 4. deny is not a miss --------------------------------------------------
(defcase 4 "deny is not a miss: a denied name raises and never falls through"
  (let [d (write! (root-dir "denied") "libd.clj" "(ns libd) (def marker :own)")
        ctx (l/deny (l/classpath [d] {:parent (l/root)}) #{'libd})
        req {:kind :ns :name "libd"}
        e (try (l/find ctx req) nil (catch :default e e))]
    (chk "find on a denied name throws" (some? e))
    (chk "the throw carries :loader/denied" (true? (:loader/denied (ex-data e))))
    (chk "the throw names the request"
         (= [:ns "libd"] [(:kind (ex-data e)) (:name (ex-data e))]))
    (chk "load on a denied name throws too"
         (some? (try (l/load ctx req) nil (catch :default e e))))
    (chk "the context's own roots did not answer instead"
         (nil? (l/resolve ctx {:kind :var :name "libd/marker"})))))

;; --- 5. self-first ----------------------------------------------------------
(defcase 5 "self-first: own roots shadow the delegate, for the declared prefix only"
  (let [du (-> (root-dir "sf-up")
               (write! "libs1.clj" "(ns libs1) (defn who [] :delegate)")
               (write! "libs2.clj" "(ns libs2) (defn who [] :delegate)"))
        dd (-> (root-dir "sf-own")
               (write! "libs1.clj" "(ns libs1) (defn who [] :own)")
               (write! "libs2.clj" "(ns libs2) (defn who [] :own)"))
        ctx (l/self-first (l/classpath [dd] {:parent (l/classpath [du])}) #{'libs1})]
    (l/load ctx {:kind :ns :name "libs1"})
    (l/load ctx {:kind :ns :name "libs2"})
    (chk "the declared prefix comes from the context's own roots"
         (= :own ((val-of (l/resolve ctx {:kind :var :name "libs1/who"})))))
    (chk "every other name still comes from the delegate"
         (= :delegate ((val-of (l/resolve ctx {:kind :var :name "libs2/who"})))))
    (chk "the delegate is still consulted for the declared prefix"
         (seq (l/find ctx {:kind :ns :name "libs1"})))))

;; --- 6. composed delegates --------------------------------------------------
(defcase 6 "composed delegates: a host plus a pool, and parent walks the graph"
  (let [da (write! (root-dir "pool-a") "liba.clj" "(ns liba) (def marker :a)")
        db (write! (root-dir "pool-b") "libb.clj" "(ns libb) (def marker :b)")
        dc (write! (root-dir "pool-c") "libc.clj" "(ns libc) (def marker :c)")
        ctx (l/classpath [dc]
                         {:parent (l/delegating (l/root)
                                                (l/pool [(l/classpath [da])
                                                         (l/classpath [db])]))})]
    (chk "a name from the first pool member resolves"
         (seq (l/find ctx {:kind :ns :name "liba"})))
    (chk "a name from the second pool member resolves"
         (seq (l/find ctx {:kind :ns :name "libb"})))
    (chk "a name from the context's own roots resolves"
         (seq (l/find ctx {:kind :ns :name "libc"})))
    (chk "a name from the host still resolves"
         (seq (l/find ctx {:kind :ns :name "clojure.string"})))
    (chk "parent walks to the delegate" (some? (l/parent ctx)))
    (let [chain (take-while some? (iterate l/parent ctx))]
      (chk "the parent chain terminates" (< (count chain) 32))
      (chk "the parent chain reaches the composed delegate" (> (count chain) 1)))))

;; --- 7. unload --------------------------------------------------------------
(defcase 7 "unload: no new loads, resolved definitions stay live, idempotent"
  (let [d (-> (root-dir "unl")
              (write! "libu.clj" "(ns libu) (defn who [] :u)")
              (write! "libu2.clj" "(ns libu2) (def marker :u2)"))
        ctx (l/classpath [d] {:parent (l/root)})]
    (l/load ctx {:kind :ns :name "libu"})
    (let [who (val-of (l/resolve ctx {:kind :var :name "libu/who"}))
          report (l/unload! ctx)]
      (chk "unload! reports the postcondition held" (true? (:unloaded report)))
      (chk "unload! is not reported as a repeat" (false? (:already report)))
      (chk "teardown errors are reported as data" (vector? (:errors report)))
      (chk "unload! reports no teardown errors here" (empty? (:errors report)))
      (chk "unloaded? is the behavioral predicate" (true? (l/unloaded? ctx)))
      (chk "a definition resolved before the unload still works" (= :u (who)))
      (chk "a new load through the loader throws"
           (some? (try (l/load ctx {:kind :ns :name "libu2"}) nil (catch :default e e))))
      (chk "find after unload throws"
           (some? (try (l/find ctx {:kind :ns :name "libu2"}) nil (catch :default e e))))
      (let [again (l/unload! ctx)]
        (chk "the second unload! is a no-op" (true? (:already again)))
        (chk "the second unload! still reports the postcondition" (true? (:unloaded again)))))
    ;; teardown against a root that vanished underneath reports, never throws
    (let [gone (root-dir "unl-gone")
          ctx2 (l/classpath [gone] {:parent (l/root)})]
      (fs/delete-tree gone)
      (chk "teardown over a vanished root is reported, not thrown"
           (map? (l/unload! ctx2))))))

;; --- 8. resources -----------------------------------------------------------
(defcase 8 "resources: find/open-hit and the classloader facade stay in the context"
  (let [d (write! (root-dir "res") "cfg.edn" "{:from :ctx}")
        ctx (l/classpath [d] {:parent (l/root)})
        hits (l/find ctx {:kind :resource :name "cfg.edn"})
        cl (l/as-classloader ctx)]
    (chk "find locates the resource" (seq hits))
    (chk "the hit names a location, not an open stream" (string? (:url (first hits))))
    (chk "open-hit reads it" (= "{:from :ctx}" (slurp (l/open-hit ctx (first hits)))))
    (chk "getResource resolves in the context" (some? (.getResource cl "cfg.edn")))
    (chk "getResources resolves in the context"
         (seq (enumeration-seq (.getResources cl "cfg.edn"))))
    (chk "getResourceAsStream reads it"
         (= "{:from :ctx}" (slurp (.getResourceAsStream cl "cfg.edn"))))
    (chk "getParent is the delegate's facade" (some? (.getParent cl)))
    (chk "a loader has one facade, so getParent chains and identity hold"
         (identical? cl (l/as-classloader ctx)))
    (chk "the 2-arity io/resource honors the loader" (some? (io/resource "cfg.edn" cl)))
    (chk "the root does not see the context's resource" (nil? (io/resource "cfg.edn")))
    (chk "RT/baseLoader inside the context is the context's loader"
         (identical? cl (l/with-loader ctx (clojure.lang.RT/baseLoader))))))

;; --- 9. defining context ----------------------------------------------------
;; The load-bearing rule: a function requires in the context that DEFINED it,
;; whoever calls it, on whatever thread, and across a fiber park.
(defcase 9 "defining context: a fn requires where it was defined, not where it is called"
  (let [d1 (-> (root-dir "def1")
               (write! "dep.clj" "(ns dep) (def which :ctx1)")
               (write! "caller.clj"
                       "(ns caller)\n(defn peek-dep [] (require 'dep) @(ns-resolve 'dep 'which))"))
        d2 (write! (root-dir "def2") "dep.clj" "(ns dep) (def which :ctx2)")
        c1 (l/classpath [d1] {:parent (l/root)})
        c2 (l/classpath [d2] {:parent (l/root)})]
    (l/load c1 {:kind :ns :name "caller"})
    (let [f (val-of (l/resolve c1 {:kind :var :name "caller/peek-dep"}))]
      (chk "called from the root, the fn sees its own context's dep" (= :ctx1 (f)))
      (chk "called inside another context, it still sees its own"
           (= :ctx1 (l/with-loader c2 (f))))
      (chk "called from a thread in another context, it still sees its own"
           (= :ctx1 @(future (l/with-loader c2 (f)))))
      (chk "called from a fiber in another context, it still sees its own"
           (= :ctx1 (async/<!! (async/go (l/with-loader c2 (f)))))))))

;; --- 10. dispatch follows the value -----------------------------------------
(defcase 10 "dispatch follows the value: a context-2 value dispatches in context 2"
  (let [ds (write! (root-dir "disp-shared") "shp.clj"
                   "(ns shp) (defprotocol Shape (area [s]))")
        d2 (write! (root-dir "disp2") "sq.clj"
                   (str "(ns sq (:require [shp]))\n"
                        "(defrecord Square [n])\n"
                        "(extend-type Square shp/Shape (area [s] (* (:n s) (:n s))))\n"
                        "(defn make [n] (->Square n))"))
        d1 (write! (root-dir "disp1") "caller1.clj"
                   "(ns caller1 (:require [shp]))\n(defn call-area [v] (shp/area v))")
        shared (l/classpath [ds] {:parent (l/root)})
        c1 (l/classpath [d1] {:parent shared})
        c2 (l/classpath [d2] {:parent shared})]
    (l/load c2 {:kind :ns :name "sq"})
    (l/load c1 {:kind :ns :name "caller1"})
    (let [make (val-of (l/resolve c2 {:kind :var :name "sq/make"}))
          call (val-of (l/resolve c1 {:kind :var :name "caller1/call-area"}))
          v (make 3)]
      (chk "context 1 code dispatches a context 2 value through context 2's tables"
           (= 9 (call v)))
      (chk "the protocol itself is shared by reference"
           (identical? (l/resolve c1 {:kind :var :name "shp/area"})
                       (l/resolve c2 {:kind :var :name "shp/area"}))))))

;; --- 11. hits are data ------------------------------------------------------
(defcase 11 "hits are data: find opens nothing and a hit round-trips into load"
  (let [d (write! (root-dir "hits") "libp.clj" "(ns libp) (def marker :p)")
        ctx (l/classpath [d] {:parent (l/root)})
        req {:kind :ns :name "libp"}
        hit (first (l/find ctx req))]
    (chk "find answers a hit" (some? hit))
    (chk "the hit prints" (string? (pr-str hit)))
    (chk "two finds answer equal hits" (= hit (first (l/find ctx req))))
    ;; the located path, not a normalized or resolved one — a temp dir reaches
    ;; here through a symlink on macOS, so compare the tail
    (chk "the hit names the file it located"
         (and (string? (:file hit)) (str/ends-with? (:file hit) "/libp.clj")))
    (chk "find installed nothing"
         (nil? (l/resolve ctx {:kind :var :name "libp/marker"})))
    (chk "loading a hit is loading the request"
         (= (l/load ctx hit) (l/load ctx req)))))

;; --- 12. eager construction, lazy load --------------------------------------
(defcase 12 "eager construction, lazy load: the constructor validates, load reads"
  (let [missing (str tmp "/absent-root")]
    (chk "a loader over an unreadable root fails at the constructor"
         (some? (try (l/classpath [missing]) nil (catch :default e e))))
    (let [d (write! (root-dir "toctou") "libt.clj" "(ns libt) (def marker :t)")
          ctx (l/classpath [d] {:parent (l/root)})
          hit (first (l/find ctx {:kind :ns :name "libt"}))]
      (chk "find located it" (some? hit))
      (fs/delete (str d "/libt.clj"))
      (chk "a load whose file vanished after find fails at load, not silently"
           (some? (try (l/load ctx hit) nil (catch :default e e)))))))

;; --- runner -----------------------------------------------------------------
(defn run-case [[n title body]]
  (reset! failures [])
  (let [err (try (body) nil (catch :default e (or (ex-message e) (pr-str e))))
        fails @failures
        pass (and (nil? err) (empty? fails))]
    (println (format "CASE %02d %s  %s" n (if pass "PASS" "FAIL") title))
    (when err (println (str "    threw: " err)))
    (doseq [f fails] (println (str "    check failed: " f)))
    pass))

(let [ordered (sort-by first @cases)
      passed (count (filter true? (doall (map run-case ordered))))]
  (println (format "LOADERCONF %d/%d" passed (count ordered)))
  (fs/delete-tree tmp))
