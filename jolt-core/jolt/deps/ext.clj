;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

(ns jolt.deps.ext
  "The coordinate-type SPI for dependency expansion, following
  clojure.tools.deps.extensions: a coordinate type registers its identifying
  keys (coord-type-keys) and implements dep-id / coord-deps / coord-root /
  compare-versions. jolt.deps registers :mvn / :git / :local; a test harness
  can register a fake type against the same expansion engine, exactly like
  tools.deps' faken extension.

  Maven version ordering — the ComparableVersion semantics tools.deps gets from
  maven-resolver, so :mvn/version conflicts resolve newest-wins without the JVM
  — lives in grenadine.version, which jolt.deps' :mvn method calls."
  (:require [clojure.set :as set]))

;;;; Methods switching on coordinate type — lifted from
;;;; clojure.tools.deps.extensions (multimethod table read via `methods`
;;;; instead of the JVM .getMethodTable).

(defmulti coord-type-keys
  "Takes a coordinate type and returns valid set of keys indicating that coord type"
  (fn [type] type))

(defmethod coord-type-keys :default [type] #{})

(defn procurer-types
  "Returns set of registered procurer types (results may change if procurer methods are registered)."
  []
  (disj (-> (methods coord-type-keys) keys set) :default))

(defn coord-type
  "Determine the coordinate type of the coordinate, based on the self-published procurer
  keys from coord-type-keys."
  [coord]
  (when (map? coord)
    (let [exts (procurer-types)
          coord-keys (-> coord keys set)
          matches (reduce (fn [ms type]
                            (cond-> ms
                              (seq (set/intersection (coord-type-keys type) coord-keys))
                              (conj type)))
                    [] exts)]
      (case (count matches)
        0 (throw (ex-info (str "Coord of unknown type: " (pr-str coord)) {:coord coord}))
        1 (first matches)
        (throw (ex-info (str "Coord type is ambiguous: " (pr-str coord)) {:coord coord}))))))

(defn- throw-bad-coord
  [lib coord]
  (if (map? coord)
    (throw (ex-info (str "No coordinate type found for library " lib " in coordinate " (pr-str coord))
                    {:lib lib :coord coord}))
    (throw (ex-info (str "Bad coordinate for library " lib ", expected map: " (pr-str coord))
                    {:lib lib :coord coord}))))

(defmulti dep-id
  "Returns an identifier value that can be used to detect a lib/coord cycle while
  expanding deps."
  (fn [lib coord] (coord-type coord)))

(defmethod dep-id :default [lib coord] (throw-bad-coord lib coord))

(defmulti coord-deps
  "Returns the child dependencies of a procured coordinate as a seq of
  [lib coord] entries. Procures (clone/fetch/extract) as a side effect;
  jolt.deps memoizes per [lib dep-id]."
  (fn [lib coord] (coord-type coord)))

(defmethod coord-deps :default [lib coord] (throw-bad-coord lib coord))

(defmulti coord-summary
  "Returns a one-line description of a lib at a coordinate — the library name
  plus whatever names its version (a Maven version, a git tag or short sha, a
  local path). The dependency tree (`jolt -Stree`) prints these."
  (fn [lib coord] (coord-type coord)))

(defmethod coord-summary :default [lib _coord] (str lib))

(defmulti coord-info
  "Returns procurement info for a coordinate: {:root dir-or-nil, :manifest kw,
  :natives [...], :prep coords-with-:deps/prep-lib}. :root nil means the
  coordinate contributes nothing (an intrinsic or sourceless dep)."
  (fn [lib coord] (coord-type coord)))

(defmethod coord-info :default [lib coord] (throw-bad-coord lib coord))

(defmulti compare-versions
  "Given two coordinates for the same library, return a comparator value
  (negative, zero, positive) ordering them by version. Throws when no ordering
  exists between the coordinate types/values."
  (fn [lib coord-x coord-y] [(coord-type coord-x) (coord-type coord-y)]))

(defmethod compare-versions :default
  [lib coord-x coord-y]
  (throw (ex-info (str "Unable to compare versions for " lib ": "
                       (pr-str coord-x) " and " (pr-str coord-y))
                  {:lib lib :coord-x coord-x :coord-y coord-y})))
