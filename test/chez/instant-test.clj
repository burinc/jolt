;; clojure.instant acceptance gate. Every expectation here is reference-Clojure
;; behavior, checked against `clojure -M` on the same inputs.
;;
;; Not corpus rows: the corpus runner deliberately loads no loader (see
;; run-corpus.ss), so a namespace that is not baked into the seed cannot be
;; required there. clojure.instant loads on require, so it is gated through the
;; real CLI, like the pprint / fs / parser suites.
;;
;; Prints per-case PASS/FAIL plus the `INSTANT OK` / `INSTANT FAIL` sentinel
;; smoke.sh greps.
(ns instant-gate
  (:require [clojure.instant :as inst]))

(def ^:private fails (atom []))
(def ^:private passes (atom 0))

(defn- ok= [got want label]
  (if (= got want)
    (swap! passes inc)
    (swap! fails conj (str label ": want " (pr-str want) " got " (pr-str got)))))

(defn- threw [f label]
  (ok= (try (f) :no-throw (catch Throwable e (.getMessage e))) label label))

;; --- parse-timestamp: the ten fields, defaults, and the nanosecond zero-fill ----
;; The fraction is zero-filled on the RIGHT to 9 digits, so ".12345" is 123450000
;; nanoseconds, not 12345.
(ok= (inst/parse-timestamp vector "2020-03-04T05:06:07.12345+01:30")
     [2020 3 4 5 6 7 123450000 1 1 30]
     "parse-timestamp full")
(ok= (inst/parse-timestamp vector "2020") [2020 1 1 0 0 0 0 0 0 0]
     "parse-timestamp year only defaults")
(ok= (inst/parse-timestamp vector "2020-06") [2020 6 1 0 0 0 0 0 0 0]
     "parse-timestamp year-month defaults")
(ok= (inst/parse-timestamp vector "2020-06-07T08") [2020 6 7 8 0 0 0 0 0 0]
     "parse-timestamp elided minutes")
(ok= (inst/parse-timestamp vector "2020-06-07T08:09:10Z") [2020 6 7 8 9 10 0 0 0 0]
     "parse-timestamp Z is offset zero")
(ok= (inst/parse-timestamp vector "2020-06-07T08:09:10-04:30") [2020 6 7 8 9 10 0 -1 4 30]
     "parse-timestamp negative offset sign")

;; --- read-instant-date: agrees with the #inst reader, offset converted to UTC ---
(ok= (inst/read-instant-date "2020-01-02T03:04:05.678-05:00")
     #inst "2020-01-02T03:04:05.678-05:00"
     "read-instant-date matches the #inst reader")
(ok= (pr-str (inst/read-instant-date "2020-01-02"))
     "#inst \"2020-01-02T00:00:00.000-00:00\""
     "read-instant-date fills elided components")
(ok= (pr-str (inst/read-instant-date "2020-01-02T03:04:05.678-05:00"))
     "#inst \"2020-01-02T08:04:05.678-00:00\""
     "read-instant-date converts the offset to UTC")
(ok= (.getTime (inst/read-instant-date "1970-01-01T00:00:00.000Z")) 0
     "read-instant-date at the epoch")
(ok= (.getTime (inst/read-instant-date "1969-12-31T23:59:59.999Z")) -1
     "read-instant-date before the epoch")
(ok= (pr-str (inst/read-instant-date "2020-02-29"))
     "#inst \"2020-02-29T00:00:00.000-00:00\""
     "read-instant-date leap day")

;; --- validated: the extra-grammatical RFC3339 restrictions -----------------------
;; The message text is the reference's, built from the unevaluated test form.
(threw #(inst/read-instant-date "2020-13-01") "failed: (<= 1 months 12)")
(threw #(inst/read-instant-date "2019-02-29")
       "failed: (<= 1 days (days-in-month months (leap-year? years)))")
(threw #(inst/read-instant-date "2020-01-01T24:00:00") "failed: (<= 0 hours 23)")
(threw #(inst/read-instant-date "2020-01-01T00:60:00") "failed: (<= 0 minutes 59)")
;; second 60 is the leap second — legal only when minutes is 59
(ok= (pr-str (inst/read-instant-date "2020-01-01T00:59:60"))
     "#inst \"2020-01-01T01:00:00.000-00:00\""
     "leap second at minute 59 is accepted")
(threw #(inst/read-instant-date "2020-01-01T00:58:60")
       "failed: (<= 0 seconds (if (= minutes 59) 60 59))")
(threw #(inst/read-instant-date "nope") "Unrecognized date/time syntax: nope")

;; --- read-instant-timestamp / -calendar ------------------------------------------
;; java.sql.Timestamp is java.util.Date on jolt, so the fraction is milliseconds;
;; the instant itself is the same one the JVM computes.
(ok= (.getTime (inst/read-instant-timestamp "1999-12-31T23:59:59.999Z")) 946684799999
     "read-instant-timestamp instant")
(ok= (.getTimeInMillis (inst/read-instant-calendar "2020-01-02T00:00:00Z")) 1577923200000
     "read-instant-calendar instant")

;; --- as a data reader ------------------------------------------------------------
(ok= (binding [*data-readers* {'inst inst/read-instant-date}]
       (read-string "#inst \"2020-01-02\""))
     #inst "2020-01-02"
     "bound into *data-readers* for the inst tag")

(let [n @passes f @fails]
  (doseq [m f] (println "instant FAIL " m))
  (println "INSTANT-RESULT pass" n "fail" (count f))
  (println (if (zero? (count f)) "INSTANT OK" "INSTANT FAIL"))
  (flush))
