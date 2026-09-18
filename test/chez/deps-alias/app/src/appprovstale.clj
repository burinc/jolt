(ns appprovstale
  "A dependency claims java.util.zip.CRC32, which the runtime provides: the
   runtime's CRC32 answers, and the library's other claim still autoloads it.")

(defn -main [& _]
  (let [c (java.util.zip.CRC32.)]
    (.update c (.getBytes "abc" "UTF-8"))
    (println (str "crc:" (.getValue c) " " (javax.crypto.SecretKeyFactory/getInstance "x")))))
