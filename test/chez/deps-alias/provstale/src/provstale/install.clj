(ns provstale.install
  "A provider whose claim on java.util.zip.CRC32 the runtime has overtaken.")

(__register-class-statics! "javax.crypto.SecretKeyFactory"
                           {"getInstance" (fn [algo] (str "stale-skf:" algo))})
