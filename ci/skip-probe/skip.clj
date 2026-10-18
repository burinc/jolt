(let [f (java.io.File/createTempFile "jskip" ".bin")]
  (println "file" (str f))
  (try
    (spit f "0123456789")
    (with-open [i (java.io.FileInputStream. f)]
      (println "skip ->" (try (pr-str (.skip i Long/MAX_VALUE))
                              (catch Throwable e (str "threw " (.getName (class e)) ": " (ex-message e)))))
      (println "read ->" (try (pr-str (.read i))
                              (catch Throwable e (str "threw " (.getName (class e)) ": " (ex-message e))))))
    (with-open [i (java.io.FileInputStream. f)]
      (println "corpus row form ->"
               (pr-str (try [(.skip i Long/MAX_VALUE) (.read i)]
                            (catch java.io.IOException e (ex-message e))))))
    (finally (.delete f))))
