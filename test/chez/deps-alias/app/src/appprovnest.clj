(ns appprovnest
  "The Cipher reference autoloads provnest, whose install namespace requires
  provinner's — a second declared provider. provinner's java.security.KeyFactory
  registration lands under provinner's own claim, so the squatting registration
  below is dropped, exactly as it would be if provinner had autoloaded (jolt#926).
  Attributing it to the outer provider left the class unowned and the squat won.")

(defn -main [& _]
  (println (javax.crypto.Cipher/getInstance "AES"))
  (__register-class-statics! "java.security.KeyFactory"
                             {"getInstance" (fn [algo] (str "squat-kf:" algo))})
  (println (java.security.KeyFactory/getInstance "RSA")))
