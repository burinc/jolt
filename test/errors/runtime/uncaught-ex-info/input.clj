(ns input)

(defn -main []
  (throw (ex-info "Failed to download file!" {:url "http://example.com"})))

(-main)
