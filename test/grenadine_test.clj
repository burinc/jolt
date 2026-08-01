(ns grenadine-test
  (:require [grenadine.graph :as graph]
            [jolt.deps :as deps]))

(defn- coord
  [artifact version]
  {:group "demo" :artifact artifact :version version})

(def poms
  {["a" "1"] {:deps [(coord "c" "1")]}
   ["b" "1"] {:deps [(coord "c" "2")]}
   ["c" "1"] {:deps [(coord "only-old" "1")]}
   ["c" "2"] {:deps []}
   ["only-old" "1"] {:deps []}})

(defn- pom-fn
  [{:keys [artifact version]}]
  (or (get poms [artifact version])
      (throw (ex-info "missing fixture POM"
                      {:artifact artifact :version version}))))

(let [resolution
      (graph/resolve-graph
       {'demo/a {:mvn/version "1"}
        'demo/b {:mvn/version "1"}}
       {:pom-fn pom-fn :mediation :tools-deps})]
  (when-not (= "2" (get-in resolution [:selected ["demo" "c"]
                                       :coords :version]))
    (throw (ex-info "Grenadine selected the wrong version"
                    {:resolution resolution})))
  (when (get-in resolution [:selected ["demo" "only-old"]])
    (throw (ex-info "Grenadine retained a losing-version subtree"
                    {:resolution resolution}))))

(def effective-poms
  {["demo" "parent" "1"]
   "<project>
      <modelVersion>4.0.0</modelVersion>
      <groupId>demo</groupId><artifactId>parent</artifactId><version>1</version>
      <properties><managed.version>2</managed.version></properties>
      <dependencyManagement><dependencies>
        <dependency>
          <groupId>demo</groupId><artifactId>managed</artifactId>
          <version>${managed.version}</version>
        </dependency>
      </dependencies></dependencyManagement>
    </project>"

   ["demo" "child" "1"]
   "<project>
      <modelVersion>4.0.0</modelVersion>
      <parent>
        <groupId>demo</groupId><artifactId>parent</artifactId><version>1</version>
      </parent>
      <artifactId>child</artifactId>
      <dependencies>
        <dependency><groupId>demo</groupId><artifactId>managed</artifactId></dependency>
        <dependency>
          <groupId>org.clojure</groupId><artifactId>clojure</artifactId>
          <version>1.9.0</version>
        </dependency>
      </dependencies>
    </project>"})

(defn- effective-pom-text
  [{:keys [group artifact version]}]
  (get effective-poms [group artifact version]))

(with-redefs-fn
  {(var jolt.deps/pom-text) effective-pom-text}
  (fn []
    (let [raw (@#'deps/effective-pom-deps
               'demo/child {:mvn/version "1"})
          filtered (into {} (@#'deps/filter-deps raw "."))]
      (when-not (= {'demo/managed {:mvn/version "2"}} filtered)
        (throw
         (ex-info "Jolt did not use Grenadine's effective POM or prune Clojure"
                  {:raw raw :filtered filtered}))))))

(println "grenadine gate: passed")
