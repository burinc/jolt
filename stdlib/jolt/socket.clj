#!/usr/bin/env jolt
;; java.net.Socket / ServerSocket / InetSocketAddress for Jolt via jolt.ffi.
;; POSIX sockets + jolt.host/tagged-table + ref-put!/ref-get for state.
;;
;; Usage: (require 'jolt.socket)  ;; registers classes globally

(ns jolt.socket
  "POSIX socket support. Registers Socket, ServerSocket, InetSocketAddress."
  (:require [jolt.ffi :as ffi]
            [clojure.string :as str]))

;; -- FFI --------------------------------------------------------------------
(ffi/load-library)
(def ^:private AF-INET 2)
(def ^:private SOCK-STREAM 1)

(ffi/defcfn c-socket     "socket"     [:int :int :int] :int)
(ffi/defcfn c-connect    "connect"    [:int :pointer :int] :int)
(ffi/defcfn c-bind       "bind"       [:int :pointer :int] :int)
(ffi/defcfn c-listen     "listen"     [:int :int] :int)
(ffi/defcfn c-accept     "accept"     [:int :pointer :pointer] :int :blocking)
(ffi/defcfn c-setsockopt "setsockopt" [:int :int :int :pointer :int] :int)
(ffi/defcfn c-recv       "recv"       [:int :pointer :size_t :int] :ssize_t :blocking)
(ffi/defcfn c-send       "send"       [:int :pointer :size_t :int] :ssize_t :blocking)
(ffi/defcfn c-close      "close"      [:int] :int)
(ffi/defcfn c-inet-addr  "inet_addr"  [:pointer] :uint)
(ffi/defcfn c-gethostbyname "gethostbyname" [:pointer] :pointer)

(def ^:private os-name    (str/lower-case (or (System/getProperty "os.name") "")))
(def ^:private sol-socket (if (str/includes? os-name "mac") 0xffff 1))
(def ^:private so-reuse   (if (str/includes? os-name "mac") 4 2))

;; -- sockaddr helpers --------------------------------------------------------
(defn- make-sockaddr-in [host port]
  ;; Build sockaddr_in (16 bytes): sin_family(2) + sin_port(2) + sin_addr(4) + padding(8)
  ;; Use inet_addr for numeric IPs, gethostbyname for hostnames.
  (let [hb (.getBytes (str host) "UTF-8")
        hp (ffi/alloc (inc (alength hb)))]
    (ffi/write-array hp hb)
    (let [addr (c-inet-addr hp)
          ip (if (= addr 4294967295) ;; inet_addr returns 0xFFFFFFFF as unsigned for non-numeric
               (let [he (c-gethostbyname hp)]
                 (when (zero? he)
                   (ffi/free hp)
                   (throw (RuntimeException. (str "gethostbyname failed for " host))))
                 (let [h-addr-list (ffi/read he :uptr 24)
                       h-addr (ffi/read h-addr-list :uptr 0)]
                   (ffi/read h-addr :uint 0)))
               addr)
          sa (ffi/alloc 16)]
      (ffi/free hp)
      (dotimes [i 16] (ffi/write sa :uint8 i 0))
      (ffi/write sa :uint8 0 AF-INET) ;; sin_family
      ;; sin_port in network byte order
      (ffi/write sa :uint8 2 (bit-and (bit-shift-right port 8) 0xff))
      (ffi/write sa :uint8 3 (bit-and port 0xff))
      ;; sin_addr in network byte order (ip already in network order)
      (ffi/write sa :uint 4 ip)
      sa)))

(defn- make-loopback-sa [port]
  (let [sa (ffi/alloc 16)]
    (dotimes [i 16] (ffi/write sa :uint8 i 0))
    ;; sin_family (2 bytes): AF_INET = 2, little-endian
    (ffi/write sa :uint8 0 AF-INET)
    ;; sin_port (2 bytes): network byte order (big-endian)
    (ffi/write sa :uint8 2 (bit-and (bit-shift-right port 8) 0xff))
    (ffi/write sa :uint8 3 (bit-and port 0xff))
    ;; sin_addr (4 bytes): 127.0.0.1 in network byte order
    (ffi/write sa :uint8 4 127)
    (ffi/write sa :uint8 7 1) ;; 127.0.0.1
    sa))

(defn- new-fd! []
  (let [fd (c-socket AF-INET SOCK-STREAM 0)]
    (when (neg? fd) (throw (java.io.IOException. "socket() failed")))
    (let [opt (ffi/alloc 4)]
      (ffi/write opt :int 0 1)
      (c-setsockopt fd sol-socket so-reuse opt 4)
      (ffi/free opt))
    fd))

;; -- Socket ------------------------------------------------------------------

(defn- socket-ctor [& args]
  (let [fd  (new-fd!)
        cap (if (= 2 (count args))
              (let [h (str (first args)) p (int (second args)) sa (make-sockaddr-in h p)]
                (let [r (c-connect fd sa 16)]
                  (ffi/free sa)
                  (when (neg? r) (c-close fd) (throw (java.io.IOException. (str "connect failed: " h ":" p)))))
                {:connected? true :host h :port p})
              {:connected? false :host nil :port nil})
        inst (jolt.host/tagged-table :socket)]
    (jolt.host/ref-put! inst :fd fd)
    (jolt.host/ref-put! inst :closed? false)
    (jolt.host/ref-put! inst :connected? (:connected? cap))
    (when (:host cap) (jolt.host/ref-put! inst :host (:host cap)))
    (when (:port cap) (jolt.host/ref-put! inst :port (:port cap)))
    inst))

(def ^:private socket-methods
  {"connect"
   (fn [self endpoint]
     (when (jolt.host/ref-get self :closed?)
       (throw (java.io.IOException. "Socket closed")))
     (when (jolt.host/ref-get self :connected?)
       (throw (java.io.IOException. "Already connected")))
     (let [h  (jolt.host/ref-get endpoint :host)
           p  (jolt.host/ref-get endpoint :port)
           fd (jolt.host/ref-get self :fd)
           sa (make-sockaddr-in h p)]
       (let [r (c-connect fd sa 16)]
         (ffi/free sa)
         (when (neg? r) (throw (java.io.IOException. "connect() failed")))))
     (jolt.host/ref-put! self :connected? true)
     nil)

   "getInputStream"
   (fn [self]
     (let [inst (jolt.host/tagged-table :socket-input-stream)]
       (jolt.host/ref-put! inst :fd (jolt.host/ref-get self :fd))
       inst))

   "getOutputStream"
   (fn [self]
     (let [inst (jolt.host/tagged-table :socket-output-stream)]
       (jolt.host/ref-put! inst :fd (jolt.host/ref-get self :fd))
       inst))

   "close"
   (fn [self]
     (when-not (jolt.host/ref-get self :closed?)
       (jolt.host/ref-put! self :closed? true)
       (c-close (jolt.host/ref-get self :fd)))
     nil)

   "isConnected" (fn [self] (boolean (jolt.host/ref-get self :connected?)))
   "isClosed"    (fn [self] (boolean (jolt.host/ref-get self :closed?)))
   "isBound"     (fn [self] (boolean (jolt.host/ref-get self :connected?)))

   "getLocalPort"
   (fn [self] (or (jolt.host/ref-get self :local-port) 0))

   "toString"
   (fn [self]
     (str "Socket[connected=" (jolt.host/ref-get self :connected?)
          " closed=" (jolt.host/ref-get self :closed?) "]"))

   "getInetAddress"  (fn [self] (jolt.host/tagged-table :inet-address))
   "getRemoteSocketAddress" (fn [self] (jolt.host/tagged-table :inet-socket-address))})

;; -- SocketInputStream -------------------------------------------------------
(defn- do-recv [fd buf len]
  (let [n (c-recv fd buf len 0)]
    (if (pos? n)
      (let [rb (ffi/read-array buf n)] {:n n :bytes rb})
      {:n -1 :bytes nil})))

(def ^:private socket-input-stream-methods
  {"read"
   (fn
     ([self]
      (let [fd (jolt.host/ref-get self :fd) buf (ffi/alloc 1)]
        (try
          (let [{:keys [n]} (do-recv fd buf 1)]
            (if (pos? n) (bit-and (ffi/read buf :uint8 0) 0xff) -1))
          (finally (ffi/free buf)))))
     ([self b]
      (let [fd (jolt.host/ref-get self :fd) len (alength b) buf (ffi/alloc (max 1 len))]
        (try
          (let [{:keys [n bytes]} (do-recv fd buf len)]
            (if (pos? n) (do (dotimes [i n] (aset b i (nth bytes i))) n) -1))
          (finally (ffi/free buf)))))
     ([self b off len]
      (let [fd (jolt.host/ref-get self :fd) buf (ffi/alloc (max 1 len))]
        (try
          (let [{:keys [n bytes]} (do-recv fd buf len)]
            (if (pos? n) (do (dotimes [i n] (aset b (+ off i) (nth bytes i))) n) -1))
          (finally (ffi/free buf))))))
   "available" (fn [self] 0)
   "close"     (fn [self] nil)})

;; -- SocketOutputStream ------------------------------------------------------
(def ^:private socket-output-stream-methods
  {"write"
   (fn
     ([self b]
      (let [fd (jolt.host/ref-get self :fd)
            data (byte-array [(unchecked-byte b)])
            n (alength data) buf (ffi/alloc n)]
        (try (ffi/write-array buf data)
             (loop [off 0]
               (when (< off n)
                 (let [s (c-send fd (+ buf off) (- n off) 0)]
                   (when (pos? s) (recur (+ off s))))))
             (finally (ffi/free buf)))))
     ([self bytes off len]
      (let [fd (jolt.host/ref-get self :fd) buf (ffi/alloc len)]
        (try
          (dotimes [i len] (ffi/write buf :uint8 i (aget bytes (+ off i))))
          (loop [t 0]
            (when (< t len)
              (let [s (c-send fd (+ buf t) (- len t) 0)]
                (when (pos? s) (recur (+ t s))))))
          (finally (ffi/free buf))))))
   "flush" (fn [self] nil)
   "close" (fn [self] nil)})

;; -- ServerSocket ------------------------------------------------------------
(defn- server-ctor [& args]
  (let [port (if (pos? (count args)) (int (first args)) 0)
        fd   (new-fd!)
        sa   (make-loopback-sa port)]
    (when (neg? (c-bind fd sa 16))
      (c-close fd) (ffi/free sa)
      (throw (java.io.IOException. (str "bind failed on port " port))))
    (ffi/free sa)
    (when (neg? (c-listen fd 50))
      (c-close fd) (throw (java.io.IOException. "listen() failed")))
    (let [inst (jolt.host/tagged-table :server-socket)]
      (jolt.host/ref-put! inst :fd fd)
      (jolt.host/ref-put! inst :closed? false)
      (jolt.host/ref-put! inst :port port)
      inst)))

(def ^:private server-socket-methods
  {"accept"
   (fn [self]
     (when (jolt.host/ref-get self :closed?)
       (throw (java.io.IOException. "ServerSocket closed")))
     (let [cfd (c-accept (jolt.host/ref-get self :fd) ffi/null ffi/null)]
       (when (neg? cfd) (throw (java.io.IOException. "accept() failed")))
       (let [inst (jolt.host/tagged-table :socket)]
         (jolt.host/ref-put! inst :fd cfd)
         (jolt.host/ref-put! inst :closed? false)
         (jolt.host/ref-put! inst :connected? true)
         inst)))

   "close"
   (fn [self]
     (when-not (jolt.host/ref-get self :closed?)
       (jolt.host/ref-put! self :closed? true)
       (c-close (jolt.host/ref-get self :fd)))
     nil)

   "isClosed"     (fn [self] (boolean (jolt.host/ref-get self :closed?)))
   "isBound"      (fn [self] (not (jolt.host/ref-get self :closed?)))
   "getLocalPort" (fn [self] (or (jolt.host/ref-get self :port) 0))
   "toString"     (fn [self]
                    (str "ServerSocket[port=" (jolt.host/ref-get self :port)
                         " closed=" (jolt.host/ref-get self :closed?) "]"))})

;; -- InetSocketAddress -------------------------------------------------------
(defn- isa-ctor [& args]
  (let [h (if (= 1 (count args)) "127.0.0.1" (str (first args)))
        p (int (if (= 1 (count args)) (first args) (second args)))
        inst (jolt.host/tagged-table :inet-socket-address)]
    (jolt.host/ref-put! inst :host h)
    (jolt.host/ref-put! inst :port p)
    inst))

(def ^:private inet-socket-address-methods
  {"getHostName" (fn [self] (or (jolt.host/ref-get self :host) "127.0.0.1"))
   "getPort"     (fn [self] (or (jolt.host/ref-get self :port) 0))
   "toString"    (fn [self]
                   (let [h (or (jolt.host/ref-get self :host) "127.0.0.1")
                         p (or (jolt.host/ref-get self :port) 0)]
                     (str h ":" p)))})

(defn- inet-address-ctor [& _]
  (let [inst (jolt.host/tagged-table :inet-address)]
    (jolt.host/ref-put! inst :address "127.0.0.1")
    inst))

(def ^:private inet-address-methods
  {"getHostAddress" (fn [self] (or (jolt.host/ref-get self :address) "127.0.0.1"))
   "toString"       (fn [self] (or (jolt.host/ref-get self :address) "127.0.0.1"))})

;; -- Registration ------------------------------------------------------------
(def ^:private registered? (atom false))

(defn register-all! []
  (when (compare-and-set! registered? false true)
    (clojure.core/__register-class-methods! :socket socket-methods)
    (clojure.core/__register-class-methods! :socket-input-stream socket-input-stream-methods)
    (clojure.core/__register-class-methods! :socket-output-stream socket-output-stream-methods)
    (clojure.core/__register-class-methods! :server-socket server-socket-methods)
    (clojure.core/__register-class-methods! :inet-socket-address inet-socket-address-methods)
    (clojure.core/__register-class-methods! :inet-address inet-address-methods)

    (clojure.core/__register-class-ctor! "InetSocketAddress" isa-ctor)
    (clojure.core/__register-class-ctor! "java.net.InetSocketAddress" isa-ctor)

    (clojure.core/__register-class-ctor! "InetAddress" inet-address-ctor)
    (clojure.core/__register-class-ctor! "java.net.InetAddress" inet-address-ctor)

    (clojure.core/__register-class-ctor! "Socket" socket-ctor)
    (clojure.core/__register-class-ctor! "java.net.Socket" socket-ctor)

    (clojure.core/__register-class-ctor! "ServerSocket" server-ctor)
    (clojure.core/__register-class-ctor! "java.net.ServerSocket" server-ctor)

    (println "[jolt.socket] Registered Socket, ServerSocket, InetSocketAddress")
    true))

(register-all!)
