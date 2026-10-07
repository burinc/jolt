;; Minimal monadic-parser core, adapted from rm-hull/jasentaa
;; (MIT). A parser is a fn from input to a seq of [value remaining] results;
;; do* threads them together.

(ns jolt.parser.monad)

(defn failure [& args]
  '())

(defn bind [v f]
  (f v))

(defn return [v]
  (fn [input]
    (list [v input])))

;; Each result is fed to f only when the caller reaches it. mapcat (apply
;; concat) realizes a few results ahead at every level, and in a recursive
;; parser like many each of those realizes ahead below it, so taking the first
;; parse went quadratic (on the JVM as well).
(defn >>= [m f]
  (fn [input]
    ((fn step [rs]
       (lazy-seq
        (when-let [rs (seq rs)]
          (let [[v tail] (first rs)]
            (concat (bind tail (f v)) (step (rest rs)))))))
     (bind input m))))

(defn- merge-bind [body bind]
  (if (and (not= clojure.lang.Symbol (type bind))
           (= 3 (count bind))
           (= '<- (second bind)))
    `(>>= ~(last bind) (fn [~(first bind)] ~body))
    `(>>= ~bind (fn [~'_] ~body))))

(defmacro do* [& forms]
  (reduce merge-bind (last forms) (reverse (butlast forms))))
