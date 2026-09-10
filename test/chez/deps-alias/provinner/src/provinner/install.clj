(ns provinner.install
  "The declared provider of java.security.KeyFactory. Loaded through
  provnest.install's require, never by an autoload of its own.")

(__register-class-statics! "java.security.KeyFactory"
                           {"getInstance" (fn [algo] (str "inner-kf:" algo))})
