;; test/chez/concurrent-require.clj — two threads requiring one namespace.
;;
;; Nothing used to serialize load-namespace*, so both threads passed the
;; loaded-ns check and both ran the target's top-level forms, double-running
;; every def and side effect in it. Worse, the mark-before-load that terminates a
;; require CYCLE marks the namespace loaded BEFORE its forms run, so to a second
;; thread it read as fully loaded while it was still half-built — a require that
;; returns having defined nothing.
;;
;; The loader now follows JLS 12.4.2, the JVM's class-initialization procedure,
;; per namespace: in progress by another thread means block until notified, in
;; progress by this thread means complete normally (the cycle break, which is
;; what mark-before-load already did).
;;
;; Two properties, and the second is the one that mattered:
;;   A. the target's top level ran EXACTLY once, however many threads required it
;;   B. every thread, on return from its require, saw the LAST form in the file
;;
;; Then the other half of the question, which one namespace cannot ask: threads
;; requiring DIFFERENT namespaces at once. One shared target means only one load
;; ever runs, so it exercises none of what happens when two do. Loading distinct
;; namespaces in parallel broke two ways, and both are gated on this file now:
;;
;;   C. every require completes. The compiler's emit session is one process-global
;;      unit and emit-with-cells save/restores its slots per def, so two threads
;;      emitting at once trade constant pools and a namespace that compiles fine
;;      alone dies on "variable _kc$81 is not bound". The require gate serializes
;;      loads for exactly this reason.
;;   D. every namespace is in *loaded-libs* afterwards. The loader used to conj
;;      the ref with a bare read-modify-write, so two threads finishing together
;;      dropped one of the two marks — and a namespace missing from *loaded-libs*
;;      reads as unloaded and runs its top level again on the next require, which
;;      is the bug A tests for, arriving through the other table. A separate probe
;;      lost 3 to 15 of 24 that way. This assertion does not isolate it while the
;;      gate stands (C fails first, and with the gate no two marks overlap), so it
;;      is here as the check that starts carrying weight the day the gate goes.
;;   E. two threads entering one require cycle from opposite ends report it instead
;;      of hanging, and one of them still completes. This is where the JVM gives up
;;      and deadlocks; the loader walks its wait-for graph before blocking.
;;   F. a (dosync (require ...)) that has to wait does not deadlock the loader. It
;;      parks holding stm-lock, so nothing a load does may ever need stm-lock back.
;;      Found by modelling the lock graph rather than by running anything: the cycle
;;      is stm-lock -> the load being waited on -> stm-lock, and it hung outright.
;;
;; Run: jolt run test/chez/concurrent-require.clj  (wired into smoke.sh)

(ns concurrent-require)

(def n-threads 8)
(def n-distinct 12)
(def tmp-root (str "/tmp/jolt-ldrtest-" (System/currentTimeMillis)))

;; The target. defonce keeps the SAME atom across a second load while the swap!
;; below it runs again, so the counter reads 2 if the file was loaded twice — it
;; measures double-loading directly rather than inferring it. `sentinel` is the
;; last form in the file on purpose: a thread that returned from require while
;; another was still loading would not see it. The loop widens the window.
(def target-src
  (str "(ns ldrtest.target)\n"
       "(defonce counter (atom 0))\n"
       "(swap! counter inc)\n"
       "(def slow (reduce + (range 200000)))\n"
       "(def sentinel :loaded)\n"))

;; One namespace per thread for phase two, aimed at the emit-session scratch rather
;; than being merely distinct: the keyword literals feed the hoisted constant pool,
;; the protocol call and the record feed the per-def cache cells, and the loop and
;; anon fns feed the gensym counter and the fn-source registry. A file of bare
;; (def x 1) exercises none of it. `sentinel` is a VALUE, so a corrupted compile
;; that somehow produced loadable code still has to produce the right answer.
(defn- distinct-src [i]
  (str "(ns ldrtest.m" i ")\n"
       "(defprotocol P" i " (go [this x]))\n"
       "(defrecord R" i " [a b] P" i " (go [this x] (+ a b x)))\n"
       "(def tags [:k" i "/a :k" i "/b :k" i "/c :k" i "/d :k" i "/e])\n"
       "(defn tally [n]\n"
       "  (loop [i 0 acc 0]\n"
       "    (if (< i n) (recur (inc i) (+ acc (go (->R" i " i 2) i))) acc)))\n"
       "(defn pick [m] (get m :k" i "/a (get m :k" i "/b :none)))\n"
       "(def sentinel {:tally (tally 20) :pick (pick {:k" i "/b " i "}) :tags tags})\n"))

;; (tally 20) sums (i + 2 + i) over 0..19 = 2*190 + 40.
(def tally-expected 420)

;; The two halves of a genuine require cycle, for property E. Each half announces
;; itself and waits for the other BEFORE requiring it, so both threads are certainly
;; inside their own load when they reach across — without that the faster thread
;; finishes both namespaces on its own and there is no cross-thread cycle to detect,
;; which made this pass for the wrong reason on roughly one run in three. The wait
;; is bounded so a loader that really is wedged fails by timeout rather than
;; spinning here forever.
(def cycle-gate (atom 0))
(defn- cycle-src [me other]
  (str "(ns ldrtest." me ")\n"
       "(swap! concurrent-require/cycle-gate inc)\n"
       "(loop [n 0]\n"
       "  (when (and (< @concurrent-require/cycle-gate 2) (< n 3000))\n"
       "    (Thread/sleep 1) (recur (inc n))))\n"
       "(require 'ldrtest." other ")\n"
       "(def sentinel :" me ")\n"))

(def dosync-src
  (str "(ns ldrtest.boom)\n"
       "(def x (reduce + (range 8000000)))\n"
       "(throw (ex-info \"boom\" {}))\n"))

(defn- write-sources! []
  (let [dir (str tmp-root "/ldrtest")]
    (.mkdirs (java.io.File. dir))
    (spit (str dir "/target.clj") target-src)
    (doseq [i (range n-distinct)]
      (spit (str dir "/m" i ".clj") (distinct-src i)))
    (spit (str dir "/x.clj") (cycle-src "x" "y"))
    (spit (str dir "/y.clj") (cycle-src "y" "x"))
    (spit (str dir "/boom.clj") dosync-src)))

;; A gate every thread spins on, so they all enter require together — without it
;; the first finishes before the rest start and there is no race to lose.
(defn- run-together [n f]
  (let [go? (atom false)
        fs (doall (for [i (range n)]
                    (future (while (not @go?) (Thread/sleep 1))
                            (f i))))]
    (reset! go? true)
    (mapv deref fs)))

;; Properties A and B: n threads, one namespace.
(defn- one-namespace-failures []
  (let [saw (atom [])
        errs (atom [])]
    (run-together n-threads
      (fn [_]
        (try
          (require 'ldrtest.target)
          ;; resolved AFTER require returns: property B
          (swap! saw conj (some? (resolve 'ldrtest.target/sentinel)))
          (catch Throwable e
            (swap! errs conj (str (.getMessage e)))))))
    (let [loads (deref @(resolve 'ldrtest.target/counter))
          sentinels @saw]
      (cond-> []
        (seq @errs)
        (conj (str "requires threw: " (pr-str @errs)))
        (not= 1 loads)
        (conj (str "the target's top level ran " loads " times, expected 1"))
        (not= n-threads (count sentinels))
        (conj (str "only " (count sentinels) " of " n-threads
                   " threads completed their require"))
        (not (every? true? sentinels))
        (conj (str (count (remove true? sentinels)) " of " n-threads
                   " threads returned from require before the"
                   " namespace's last form had run"))))))

;; Properties C and D: one namespace per thread, all at once.
(defn- distinct-namespaces-failures []
  (let [errs (atom [])
        done (atom [])]
    (run-together n-distinct
      (fn [i]
        (try
          (require (symbol (str "ldrtest.m" i)))
          (let [s (deref (resolve (symbol (str "ldrtest.m" i "/sentinel"))))]
            (swap! done conj (= tally-expected (:tally s)))
            (when-not (= tally-expected (:tally s))
              (swap! errs conj (str "m" i " compiled to the wrong value: tally="
                                    (:tally s) ", expected " tally-expected))))
          (catch Throwable e
            (swap! errs conj (str "m" i ": " (.getMessage e)))))))
    (let [libs (deref (deref (resolve 'clojure.core/*loaded-libs*)))
          missing (atom [])]
      (doseq [i (range n-distinct)]
        (when-not (contains? libs (symbol (str "ldrtest.m" i)))
          (swap! missing conj i)))
      (cond-> []
        (seq @errs)
        (conj (str "parallel requires of distinct namespaces threw: " (pr-str @errs)))
        (not (every? true? @done))
        (conj (str (count (remove true? @done)) " of " n-distinct
                   " parallel requires returned without defining the namespace"))
        (seq @missing)
        (conj (str (count @missing) " of " n-distinct
                   " namespaces are missing from *loaded-libs* after loading in"
                   " parallel: " (pr-str @missing)))))))

;; Property E: two threads entering one require cycle from opposite ends. On the JVM
;; this is a hang — spec-conformant, and OpenJDK closed it won't fix — because each
;; thread ends up waiting on a class the other is initializing. The loader records
;; the owner of every in-flight load, so it walks the wait-for graph before blocking
;; and raises instead. What we assert is both halves of that: SOMEBODY reports the
;; cycle rather than the pair hanging, and the other thread still finishes its load.
;; A hang here fails the run by timeout rather than by assertion, so the deref is
;; bounded — a wedged loader must not wedge the suite.
(defn- deref-timeout [f ms]
  (let [done (atom false) out (atom nil)]
    (future (reset! out (deref f)) (reset! done true))
    (loop [waited 0]
      (cond @done [:ok @out]
            (>= waited ms) [:timeout nil]
            :else (do (Thread/sleep 5) (recur (+ waited 5)))))))

(defn- cycle-failures []
  (let [go? (atom false)
        run (fn [ns-name]
              (future (while (not @go?) (Thread/sleep 1))
                      (try (require (symbol (str "ldrtest." ns-name))) [:ok nil]
                           (catch Throwable e [:err (str (.getMessage e))]))))
        fx (run "x")
        fy (run "y")]
    (reset! go? true)
    (let [[sx rx] (deref-timeout fx 15000)
          [sy ry] (deref-timeout fy 15000)]
      (cond
        (or (= :timeout sx) (= :timeout sy))
        ["two threads entering a require cycle from opposite ends hung; the"
         " wait-for graph walk did not fire"]
        :else
        (let [outcomes [rx ry]
              reported (filter (fn [r] (and (= :err (first r))
                                            (re-find #"Deadlocked require" (second r))))
                               outcomes)
              completed (filter (fn [r] (= :ok (first r))) outcomes)
              other-errs (filter (fn [r] (and (= :err (first r))
                                              (not (re-find #"Deadlocked require" (second r)))))
                                 outcomes)]
          (cond-> []
            (seq other-errs)
            (conj (str "the require cycle raised something other than the cycle"
                       " report: " (pr-str (mapv second other-errs))))
            (empty? reported)
            (conj (str "neither thread reported the require cycle; got "
                       (pr-str outcomes)))
            (empty? completed)
            (conj (str "both threads failed on the require cycle; one of them"
                       " should still complete its load"))))))))

;; Property F: a (dosync (require ...)) that has to wait must not deadlock the loader.
;;
;; jolt-sync holds stm-lock across the whole transaction body, and condition-wait
;; releases ldr-load-mu and nothing else, so a dosync that parks in step 2 sits there
;; holding stm-lock. If a load ever needed stm-lock to finish, the two would wait on
;; each other forever. It did: ldr-mark-loaded! went through the STM, so the rollback
;; on a failing load re-took it, and this test hung outright. The mark writes the
;; ambient transaction's log when there is one and takes a leaf mutex otherwise, so
;; the edge does not exist. The load here THROWS on purpose — that is the path with
;; the wide window.
(defn- dosync-wait-failures []
  (let [plain (future (try (require 'ldrtest.boom) :loaded
                           (catch Throwable _ :threw)))
        ;; long enough to be inside the load, short enough to be before it throws
        _ (Thread/sleep 40)
        txn (future (try (dosync (require 'ldrtest.boom)) :loaded
                         (catch Throwable _ :threw)))
        [s1 _] (deref-timeout plain 20000)
        [s2 _] (deref-timeout txn 20000)]
    (cond-> []
      (or (= :timeout s1) (= :timeout s2))
      (conj (str "a (dosync (require ...)) waiting on another thread's load"
                 " deadlocked: the transaction holds stm-lock while parked and the"
                 " load needed it back")))))

(defn- clean-up! []
  ;; the temp root is per-run (currentTimeMillis), so clean it up rather than
  ;; leave one behind on every smoke run
  (doseq [i (range n-distinct)]
    (try (.delete (java.io.File. (str tmp-root "/ldrtest/m" i ".clj")))
         (catch Throwable _ nil)))
  (doseq [p [(str tmp-root "/ldrtest/target.clj") (str tmp-root "/ldrtest/x.clj")
             (str tmp-root "/ldrtest/y.clj") (str tmp-root "/ldrtest/boom.clj")
             (str tmp-root "/ldrtest") tmp-root]]
    (try (.delete (java.io.File. p)) (catch Throwable _ nil))))

(defn -main []
  (write-sources!)
  (jolt.host/set-source-roots! (vec (cons tmp-root (jolt.host/source-roots))))
  (let [failures (-> []
                     (into (one-namespace-failures))
                     (into (distinct-namespaces-failures))
                     (into (cycle-failures))
                     (into (dosync-wait-failures)))]
    (clean-up!)
    (if (seq failures)
      (do (doseq [f failures] (println "FAIL:" f))
          (println "CONCURRENT-REQUIRE FAILED")
          (System/exit 1))
      (println "CONCURRENT-REQUIRE OK" n-threads "threads on 1 namespace,"
               n-distinct "namespaces in parallel, cycle and dosync-wait not hung"))))

(-main)
