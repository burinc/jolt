(ns rb.app)

(defn -main [& _]
  (try (require 'rb.rdr) (catch Exception _ nil))
  (throw (ex-info "after a caught load" {})))
