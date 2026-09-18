; Jolt Standard Library: clojure.reflect
;
; Port of Clojure 1.12's clojure.reflect and its JavaReflector. The reference
; splits into reflect.clj (the protocols, type-reflect, reflect) and
; reflect/java.clj (flag-descriptors, the member records, JavaReflector); both
; are here, and both are the reference implementation apart from the two things
; jolt has no bytecode for.
;
; What differs, and why:
;
; * There is no AsmReflector. It reads .class bytes; jolt has none. The
;   :reflector option still works for a caller supplying its own.
;
; * The member sets are what jolt's registries KNOW a class declares — a
;   deftype/defrecord's fields, and every method registered against the type by
;   whichever protocol or interface declares it — not what the JVM ships. A host
;   class jolt models by other means (String's methods are a `cond`, not data)
;   reports no members rather than guessing. :bases and :flags come from the
;   class graph and are faithful.
;
; * typesym uses .getName. The reference routes through ASM's Type to spell
;   arrays as byte[] rather than [B; jolt's own array class names already read
;   that way, so the extra hop has nothing to correct.

(ns clojure.reflect
  (:require [clojure.set :as set]
            [clojure.string :as str]))

(defprotocol Reflector
  "Protocol for reflection implementers."
  (do-reflect [reflector typeref]))

(defprotocol TypeReference
  "A TypeReference can be unambiguously converted to a type name on
   the host platform.

   All typerefs are normalized into symbols. If you need to
   normalize a typeref yourself, call typesym."
  (typename [o] "Returns Java name as returned by ASM getClassName, e.g. byte[], java.lang.String[]"))

(extend-protocol TypeReference
  clojure.lang.Symbol
  (typename [s] (str/replace (str s) "<>" "[]"))

  java.lang.Class
  (typename [c] (.getName c))

  java.lang.String
  (typename [s] (str/replace s "<>" "[]")))

(defn- typesym
  "Given a typeref, create a legal Clojure symbol version of the
   type's name."
  [t]
  (-> (typename t)
      (str/replace "[]" "<>")
      (symbol)))

(defn- access-flag
  [[name flag & contexts]]
  {:name name :flag flag :contexts (set (map keyword contexts))})

(def ^{:doc "The Java access bitflags, along with their friendly names and
the kinds of objects to which they can apply."}
  flag-descriptors
  (vec
   (map access-flag
        [[:public 0x0001 :class :field :method]
         [:private 0x002 :class :field :method]
         [:protected 0x0004 :class :field :method]
         [:static 0x0008 :field :method]
         [:final 0x0010 :class :field :method]
         [:synchronized 0x0020 :method]
         [:volatile 0x0040 :field]
         [:bridge 0x0040 :method]
         [:varargs 0x0080 :method]
         [:transient 0x0080 :field]
         [:native 0x0100 :method]
         [:interface 0x0200 :class]
         [:abstract 0x0400 :class :method]
         [:strict 0x0800 :method]
         [:synthetic 0x1000 :class :field :method]
         [:annotation 0x2000 :class]
         [:enum 0x4000 :class :field :inner]])))

(defn- parse-flags
  "Convert reflection bitflags into a set of keywords."
  [flags context]
  (reduce
   (fn [result fd]
     (if (and (get (:contexts fd) context)
              (not (zero? (bit-and flags (:flag fd)))))
       (conj result (:name fd))
       result))
   #{}
   flag-descriptors))

(defrecord Constructor
  [name declaring-class parameter-types exception-types flags])

(defn- constructor->map
  [constructor]
  (Constructor.
   (symbol (.getName constructor))
   (typesym (.getDeclaringClass constructor))
   (vec (map typesym (.getParameterTypes constructor)))
   (vec (map typesym (.getExceptionTypes constructor)))
   (parse-flags (.getModifiers constructor) :method)))

(defn- declared-constructors
  "Return a set of the declared constructors of class as a Clojure map."
  [cls]
  (set (map constructor->map (.getDeclaredConstructors cls))))

(defrecord Method
  [name return-type declaring-class parameter-types exception-types flags])

(defn- method->map
  [method]
  (Method.
   (symbol (.getName method))
   (typesym (.getReturnType method))
   (typesym (.getDeclaringClass method))
   (vec (map typesym (.getParameterTypes method)))
   (vec (map typesym (.getExceptionTypes method)))
   (parse-flags (.getModifiers method) :method)))

(defn- declared-methods
  "Return a set of the declared methods of class as a Clojure map."
  [cls]
  (set (map method->map (.getDeclaredMethods cls))))

(defrecord Field
  [name type declaring-class flags])

(defn- field->map
  [field]
  (Field.
   (symbol (.getName field))
   (typesym (.getType field))
   (typesym (.getDeclaringClass field))
   (parse-flags (.getModifiers field) :field)))

(defn- declared-fields
  "Return a set of the declared fields of class as a Clojure map."
  [cls]
  (set (map field->map (.getDeclaredFields cls))))

(defn- typeref->class
  [typeref]
  (if (class? typeref)
    typeref
    (Class/forName (typename typeref))))

(deftype JavaReflector [classloader]
  Reflector
  (do-reflect [_ typeref]
    (let [cls (typeref->class typeref)]
      {:bases (not-empty (set (map typesym (bases cls))))
       :flags (parse-flags (.getModifiers cls) :class)
       :members (set/union (declared-fields cls)
                           (declared-methods cls)
                           (declared-constructors cls))})))

(def ^:private default-reflector (JavaReflector. nil))

(defn type-reflect
  "Alpha - subject to change.
   Reflect on a typeref, returning a map with :bases, :flags, and
  :members. In the discussion below, names are always Clojure symbols.

   :bases            a set of names of the type's bases
   :flags            a set of keywords naming the boolean attributes
                     of the type.
   :members          a set of the type's members. Each member is a map
                     and can be a constructor, method, or field.

   Keys common to all members:
   :name             name of the type
   :declaring-class  name of the declarer
   :flags            keyword naming boolean attributes of the member

   Keys specific to constructors:
   :parameter-types  vector of parameter type names
   :exception-types  vector of exception type names

   Key specific to methods:
   :parameter-types  vector of parameter type names
   :exception-types  vector of exception type names
   :return-type      return type name

   Keys specific to fields:
   :type             type name

   Options:

     :ancestors     in addition to the keys described above, also
                    include an :ancestors key with the entire set of
                    ancestors, and add all ancestor members to
                    :members.
     :reflector     implementation to use. Defaults to JavaReflector."
  [typeref & options]
  (let [{:keys [ancestors reflector]}
        (merge {:reflector default-reflector}
               (apply hash-map options))
        refl (partial do-reflect reflector)
        result (refl typeref)]
    (if ancestors
      (let [make-ancestor-map (fn [names] (zipmap names (map refl names)))]
        (loop [reflections (make-ancestor-map (:bases result))]
          (let [ancestors-visited (set (keys reflections))
                ancestors-to-visit (set/difference (set (mapcat :bases (vals reflections)))
                                                   ancestors-visited)]
            (if (seq ancestors-to-visit)
              (recur (merge reflections (make-ancestor-map ancestors-to-visit)))
              (apply merge-with into result {:ancestors ancestors-visited}
                     (map #(select-keys % [:members]) (vals reflections)))))))
      result)))

(defn reflect
  "Alpha - subject to change.
   Reflect on the type of obj (or obj itself if obj is a class).
   Return value and options are the same as for type-reflect. "
  [obj & options]
  (apply type-reflect (if (class? obj) obj (class obj)) options))
