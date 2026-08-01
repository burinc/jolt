;; An org.slf4j backend for conformance runs, registered as host classes.
;;
;; clojure.tools.logging picks its backend at LOAD time: impl/find-factory probes
;; slf4j, commons-logging, log4j2, log4j and java.util.logging in turn with
;; (Class/forName …), and throws "Valid logging implementation could not be found"
;; when every one is absent. On jolt every one is absent, so the namespace cannot
;; load at all and the whole suite is a load-fail.
;;
;; Rather than replace clojure.tools.logging.impl — which would mean testing our
;; port instead of the library — this registers the classes its FIRST probe looks
;; for. tools.logging then takes its normal slf4j path: Class/forName finds
;; org.slf4j.Logger, it extends its Logger protocol onto that class, and asks
;; LoggerFactory for loggers. The library under test is unmodified and every code
;; path it exercises is its own.
;;
;; Required to be loaded BEFORE clojure.tools.logging, hence :preload in the
;; manifest — find-factory runs at load and only sees classes registered by then.
(ns jolt.shim.slf4j)

;; Levels the suite asserts on, most to least verbose. A logger is enabled for a
;; level at or above its threshold; the default mirrors slf4j's usual INFO.
(def ^:private level-rank {:trace 0 :debug 1 :info 2 :warn 3 :error 4})
(def ^:private threshold (atom :trace))

(defn set-threshold!
  "Lower bound for enabled?. Exposed so a test harness can quiet a run."
  [level]
  (reset! threshold level))

;; Emitted lines, so a harness can assert on output without capturing stderr.
(def captured (atom []))

(defn- enabled-at? [level]
  (>= (level-rank level 0) (level-rank @threshold 0)))

(defn- emit! [logger-name level msg throwable]
  (swap! captured conj {:logger logger-name :level level :message msg :throwable throwable})
  (binding [*out* *err*]
    (println (str (.toUpperCase (name level)) " " logger-name " - " msg))
    (when throwable
      (println (str "  " (or (ex-message throwable) (str throwable)))))))

;; A logger is a tagged host value so (class logger) reads org.slf4j.Logger and
;; tools.logging's (extend org.slf4j.Logger …) dispatches on it.
(defn- make-logger [nm]
  (let [t (jolt.host/tagged-table :org.slf4j/logger)]
    (jolt.host/ref-put! t :jolt.shim/type :org.slf4j/logger)
    (jolt.host/ref-put! t :name nm)
    t))

(def ^:private loggers (atom {}))
(defn- get-logger [nm]
  (let [nm (str nm)]
    (or (get @loggers nm)
        (let [l (make-logger nm)] (swap! loggers assoc nm l) l))))

(defn- logger-name [self] (jolt.host/ref-get self :name))

(__register-class-methods! :org.slf4j/logger
  (into {"getName" (fn [self] (logger-name self))}
        (mapcat (fn [[lvl enabled-method log-method]]
                  [[enabled-method (fn [_self] (enabled-at? lvl))]
                   [log-method (fn [self msg & [throwable]]
                                 (emit! (logger-name self) lvl msg throwable)
                                 nil)]])
                [[:trace "isTraceEnabled" "trace"]
                 [:debug "isDebugEnabled" "debug"]
                 [:info  "isInfoEnabled"  "info"]
                 [:warn  "isWarnEnabled"  "warn"]
                 [:error "isErrorEnabled" "error"]])))

;; The factory object LoggerFactory/getILoggerFactory hands back; tools.logging
;; calls .getLogger on it per namespace.
(def ^:private ilogger-factory
  (let [t (jolt.host/tagged-table :org.slf4j/factory)]
    t))
(__register-class-methods! :org.slf4j/factory
  {"getLogger" (fn [_self nm] (get-logger nm))})

;; Registering statics is also what makes Class/forName resolve these names, which
;; is precisely what impl/class-found? asks.
(__register-class-statics! "org.slf4j.LoggerFactory"
  {"getILoggerFactory" (fn [& _] ilogger-factory)
   "getLogger" (fn [nm & _] (get-logger nm))})
(__register-class-statics! "org.slf4j.Logger" {})
(__register-class-statics! "org.slf4j.ILoggerFactory" {})

;; A logger has to REPORT org.slf4j.Logger, not just answer to its methods:
;; tools.logging does (extend org.slf4j.Logger Logger {…}), and protocol dispatch
;; keys on the value's class. Without this the value's class is :object, the
;; extend lands on a class nothing reports, and every call fails "No method
;; enabled? in Logger".
(defn- slf4j-logger? [v]
  (and (jolt.host/table? v) (= :org.slf4j/logger (jolt.host/ref-get v :jolt.shim/type))))

;; The tag list must carry BOTH spellings. A graph-modeled class canonicalizes to
;; its simple last segment, so (extend org.slf4j.Logger …) files the impl under
;; "Logger"; (class x) meanwhile should read the fully qualified name. Reporting
;; only the FQN leaves the impl under a tag the value never claims.
(__register-class!
 slf4j-logger?
 (fn [_] "org.slf4j.Logger")
 (fn [_] ["Logger" "org.slf4j.Logger" "java.lang.Object" "Object"]))

(__register-instance-check!
 (fn [class-name v]
   (when (slf4j-logger? v)
     (boolean (#{"org.slf4j.Logger" "Logger"} class-name)))))

;; Reporting the class is not enough on its own: (extend org.slf4j.Logger …) files
;; the impl under the CANONICAL tag for that name, and a name jolt's class graph
;; has never heard of canonicalizes to a local, namespace-qualified tag instead —
;; so the impl lands under a tag no value reports and dispatch misses with "No
;; method enabled? in Logger". Declaring the class puts it in the graph, which is
;; what canonical-host-tag consults.
(jolt.host/register-class-supers! "org.slf4j.Logger" ["java.lang.Object"])
(jolt.host/register-class-supers! "org.slf4j.ILoggerFactory" ["java.lang.Object"])
