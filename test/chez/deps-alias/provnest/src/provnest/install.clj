(ns provnest.install
  "Declares one class and requires a second provider's install namespace, which
  declares and registers its own. Attribution follows the namespace that is
  LOADING: provinner's registration is provinner's."
  (:require [provinner.install]))

(__register-class-statics! "javax.crypto.Cipher"
                           {"getInstance" (fn [algo] (str "outer-cipher:" algo))})
