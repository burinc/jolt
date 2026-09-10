(ns provsquat.install
  "Registers the class it declares — and one it does not. The undeclared
  registration is what used to decide java.security.Signature for the whole
  program whenever this namespace happened to load first.")

(__register-class-statics! "javax.crypto.Mac"
                           {"getInstance" (fn [algo] (str "squatter-mac:" algo))})

;; undeclared: this class belongs to provclaim, which declares it
(__register-class-statics! "java.security.Signature"
                           {"getInstance" (fn [algo] (str "squatter-sig:" algo))})
(__register-class-ctor! "java.security.Signature" (fn [& _] "squatter-sig-ctor"))
(__register-class-ctor! "Signature" (fn [& _] "squatter-sig-ctor"))

;; ...but a member provclaim's shim does NOT answer is additive, not a
;; substitution, and still goes through: a claim is authority over what the
;; provider implements, not a reservation on the name.
(__register-class-statics! "java.security.Signature"
                           {"getMaxSigLength" (fn [_] "squatter-extra")})

;; ...and the other half of the real jolt.crypto symptom: a class this namespace
;; registers that a DIFFERENT library declares, where that library never loads.
(__register-class-statics! "java.security.KeyPairGenerator"
                           {"getInstance" (fn [algo] (str "squatter-kpg:" algo))})

;; ...and undeclared registrations that read differently to the diagnostic
;; (jolt#926). java.security.KeyStore is a class NOTHING implements and nothing
;; declares, so the note's advice — declare it in :jolt/provides — is the fix.
;;
;; Each is preceded by a USER TYPE whose simple name collides with it, because
;; "does the runtime provide this class?" is answered from the host ctor and
;; statics tables under BOTH spellings, and a deftype writes the ctor table
;; while a defrecord writes both (its static `create`). Recording either as the
;; host's would silence the note through the short name alone — and
;; register-class-provider!, which runs at deps time before any user type
;; exists, would still accept a :jolt/provides claim on the class. The two
;; answers have to agree. deftype first, so the ctor half fails on its own.
(deftype KeyStore [_])
(__register-class-statics! "java.security.KeyStore"
                           {"getDefaultType" (fn [] "squatter-ks")})
(defrecord MessageDigest [_])
(__register-class-statics! "java.security.MessageDigest"
                           {"getInstance" (fn [_] "squatter-md")})
;; java.util.Base64 is one the RUNTIME implements, so register-class-provider!
;; refuses a claim on it and the same advice cannot be taken: extending it member
;; by member at install is the only route, and it is the additive case. No note.
(__register-class-statics! "java.util.Base64"
                           {"getMimeDecoder" (fn [] "squatter-b64")})
