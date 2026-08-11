;; test/chez/dyn-binding.clj — the dynamic-var binding gate (jolt-3bo).
;; Run through jolt (wired into host/chez/smoke.sh).
;;
;; WHY THIS EXISTS. A var read no longer walks the binding stack unless the var's
;; dyn-bound? flag says it has been bound at some point (Clojure's
;; Var.threadBound). That is only correct while one invariant holds: if a cell is
;; in any frame of this thread's stack, its flag is set. Break it and the var
;; silently reads its ROOT while a binding for it is in scope — no error, no
;; crash, just the wrong value, which is the worst shape a bug can have.
;;
;; The invariant is kept by routing every push through one helper. The hazard is
;; therefore a NEW push site that does not use it, and the sites most likely to
;; grow one are the two that never went through push-thread-bindings in the first
;; place: the loader's per-file vars and the agent's *agent*. They are checked
;; first, below, because the ordinary binding path would keep passing while they
;; broke.
;;
;; Each of the three push sites was sabotaged in turn to confirm this file
;; actually catches it — the loader's and the agent's fail on their own check, and
;; push-thread-bindings fails on the agent's, since agents convey through it.
;;
;; Semantics only, no timing: the cost is bench/dyn-binding (`make dynbench`), and
;; a timing assertion in a gate is how the concurrency scenarios in this same PR
;; ended up flaky on a loaded CI box.

(def ^:dynamic *a* :root)
(def ^:dynamic *b* :root-b)
(def not-dynamic 7)

(def failures (atom []))
(defn- chk [label got want]
  (when-not (= got want)
    (swap! failures conj (str label ": got " (pr-str got) " want " (pr-str want)))))

;; ORDER MATTERS. The direct-push checks run FIRST, before anything below that
;; could set the flag for them by accident. with-bindings and bound-fn re-push the
;; map get-thread-bindings hands back, which contains every var bound at that
;; instant — including the loader's *file* — so running them first LAUNDERS the
;; flag onto those cells and a push site that forgot to set it still reads
;; correctly. Verified by sabotage: with the checks in the other order, removing
;; the flag from the loader's own push left this file passing.

;; --- the paths that push a frame DIRECTLY ------------------------------------
;; *agent* is bound by the agent machinery (java/concurrency.ss), not by
;; push-thread-bindings. If that push stops flagging the cell, *agent* reads its
;; root — nil — inside the action, and nothing else in this file notices.
(let [a (agent :v)
      seen (promise)]
  (send a (fn [st] (deliver seen (= *agent* a)) st))
  (chk "*agent* is bound inside an agent action" (deref seen 5000 :timeout) true))

;; *file* is bound by the loader around each file it loads (loader.ss), again by a
;; direct push. Reading it from a loaded file is the only way to see that frame.
;;
;; The (in-ns) afterwards is not decoration: load-file leaks the loaded file's
;; namespace into the caller (jolt-zjb), so without it every form BELOW this one
;; compiles inside dyn.probe.file and fails to resolve `failures`. Restore by hand
;; and leave the divergence to its own change.
(let [here (ns-name *ns*)
      tmp (str (System/getProperty "java.io.tmpdir") "/jolt-dyn-binding-probe.clj")]
  (spit tmp "(ns dyn.probe.file) (def seen-file *file*)\n")
  (load-file tmp)
  (in-ns here)
  (chk "*file* names the loading file"
       (boolean (re-find #"jolt-dyn-binding-probe" (str @(resolve 'dyn.probe.file/seen-file))))
       true)
  (.delete (java.io.File. tmp)))


;; --- the ordinary path (push-thread-bindings) --------------------------------
(chk "root read" *a* :root)
(chk "bound read" (binding [*a* 1] *a*) 1)
(chk "nested shadowing" (binding [*a* 1] (binding [*a* 2] *a*)) 2)
(chk "restored after the binding" (do (binding [*a* 1] *a*) *a*) :root)
;; the monotone flag must not make a var read as bound once it has been unbound
(chk "unbound read AFTER a past binding" (do (binding [*a* 1] *a*) *a*) :root)
(chk "two vars at depth"
     (binding [*a* 1] (binding [*b* 2] (binding [*a* 3] (binding [*b* 4] [*a* *b*])))) [3 4])
(chk "thread-bound? outside" (thread-bound? #'*a*) false)
(chk "thread-bound? inside" (binding [*a* 1] (thread-bound? #'*a*)) true)
(chk "thread-bound? on a never-bound var" (thread-bound? #'*b*) false)
(chk "set! inside a binding" (binding [*a* 1] (set! *a* 9) *a*) 9)
(chk "set! leaves the root alone" (do (binding [*a* 1] (set! *a* 9)) *a*) :root)
(chk "set! outside throws" (try (set! *a* 3) :no-throw (catch Throwable _ :threw)) :threw)
(chk "binding a non-dynamic var throws"
     (try (eval '(binding [not-dynamic 1] not-dynamic)) :no-throw (catch Throwable _ :threw)) :threw)
(chk "get-thread-bindings sees the binding"
     (binding [*a* 1] (contains? (get-thread-bindings) #'*a*)) true)
(chk "with-bindings replays a frame" (with-bindings {#'*a* 5} *a*) 5)
(chk "bound-fn carries it" (binding [*a* 4] ((bound-fn [] *a*))) 4)
(chk "conveyed to a future" (binding [*a* 6] @(future *a*)) 6)
(chk "conveyed to a raw thread"
     (binding [*a* 8] (let [p (promise)] (.start (Thread. (fn [] (deliver p *a*)))) @p)) 8)
(chk "with-redefs swaps the root" (with-redefs [*b* :redef] *b*) :redef)
(chk "with-redefs restores" (do (with-redefs [*b* :redef] *b*) *b*) :root-b)

(if (empty? @failures)
  (println "DYN-BINDING OK")
  (do (println "DYN-BINDING FAILED")
      (doseq [f @failures] (println "  " f))
      (System/exit 1)))
