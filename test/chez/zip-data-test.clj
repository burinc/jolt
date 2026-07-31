;; clojure.zip + clojure.data acceptance gate — the parts real libraries reach for
;; (data.zip drives xml-zip/node; cider-nrepl renders test failures with
;; clojure.data/diff). Both load on require, so they cannot be corpus rows: the
;; corpus runner loads no loader.
;;
;; Every expectation is checked against reference Clojure 1.12.5, including the
;; SHAPE of the result — diff's map arm returns a seq, its vector and set arms
;; return vectors, and code that prints a diff sees the difference.
;;
;; Prints the `ZIP-DATA OK` / `ZIP-DATA FAIL` sentinel smoke.sh greps.
(ns zip-data-gate
  (:require [clojure.zip :as z]
            [clojure.data :as d]))

(def ^:private fails (atom []))
(def ^:private passes (atom 0))

(defn- ok= [got want label]
  (if (= got want)
    (swap! passes inc)
    (swap! fails conj (str label ": want " (pr-str want) " got " (pr-str got)))))

(def ^:private xml
  {:tag :a :attrs nil
   :content [{:tag :b :attrs {:id "1"} :content ["x"]}
             {:tag :c :attrs nil :content ["y"]}]})

;; --- clojure.zip ------------------------------------------------------------------
(ok= (z/node (z/xml-zip xml)) xml "xml-zip node is the root element")
(ok= (:tag (z/node (z/down (z/xml-zip xml)))) :b "xml-zip descends into :content")
(ok= (:tag (z/node (z/right (z/down (z/xml-zip xml))))) :c "right moves to the next sibling")
(ok= (z/node (z/down (z/vector-zip [1 [2 3]]))) 1 "vector-zip node")
(ok= (z/node (z/down (z/seq-zip '(1 (2 3))))) 1 "seq-zip node")
(ok= (z/root (z/edit (z/down (z/vector-zip [1 2])) inc)) [2 2] "edit replaces at the location")
(ok= (z/root (z/insert-right (z/down (z/vector-zip [1 2])) 9)) [1 9 2] "insert-right")
(ok= (z/root (z/remove (z/down (z/vector-zip [1 2])))) [2] "remove")
(ok= (vec (take-while (complement z/end?) (iterate z/next (z/vector-zip [1 [2]]))))
     (vec (take 4 (iterate z/next (z/vector-zip [1 [2]]))))
     "next walks the whole tree before reporting end?")
(ok= (z/branch? (z/vector-zip [1])) true "a vector is a branch")
(ok= (z/children (z/vector-zip [1 2])) [1 2] "children of the root")
(ok= (z/lefts (z/right (z/down (z/vector-zip [1 2])))) [1] "lefts")
(ok= (z/rights (z/down (z/vector-zip [1 2]))) [2] "rights")

;; --- clojure.data -----------------------------------------------------------------
;; The map arm of diff yields a SEQ (the reference reduces with (doall (map …))),
;; the vector and set arms yield vectors. Anything that prints a diff shows it.
(ok= (pr-str (d/diff {:a 1 :b 2} {:a 1 :c 3}))
     "({:b 2} {:c 3} {:a 1})"
     "diff of maps prints as a seq of three")
(ok= (d/diff [1 2 3] [1 9 3]) [[nil 2] [nil 9] [1 nil 3]] "diff of vectors is positional")
(ok= (d/diff #{1 2} #{2 3}) [#{1} #{3} #{2}] "diff of sets")
(ok= (d/diff 1 1) [nil nil 1] "diff of equal atoms is only-in-both")
(ok= (d/diff 1 2) [1 2 nil] "diff of unequal atoms has no common part")
(ok= (d/diff {:a {:b 1 :c 2}} {:a {:b 1 :c 9}})
     (list {:a {:c 2}} {:a {:c 9}} {:a {:b 1}})
     "diff recurses into nested maps")
(ok= (d/diff nil {:a 1}) [nil {:a 1} nil] "diff against nil")
(ok= (d/equality-partition {}) :map "equality-partition of a map")
(ok= [(d/equality-partition []) (d/equality-partition #{}) (d/equality-partition 1)]
     [:sequential :set :atom]
     "equality-partition of the other categories")

(let [n @passes f @fails]
  (doseq [m f] (println "zip-data FAIL " m))
  (println "ZIP-DATA-RESULT pass" n "fail" (count f))
  (println (if (zero? (count f)) "ZIP-DATA OK" "ZIP-DATA FAIL"))
  (flush))
