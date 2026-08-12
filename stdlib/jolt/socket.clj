;; java.net.Socket / ServerSocket / InetSocketAddress for Jolt via jolt.ffi.
;; POSIX sockets + jolt.host/tagged-table + ref-put!/ref-get for state.
;;
;; Usage: (require 'jolt.socket)  ;; registers classes globally

(ns jolt.socket
  "POSIX socket support. Registers Socket, ServerSocket, InetSocketAddress,
  InetAddress and the socket stream classes with the host class registry.

  Deliberate divergences from the JVM (test/conformance/known-divergences.edn):
  a recv error reads as EOF (-1) rather than throwing, .connect ignores its
  timeout argument (always blocking), and toString formats are approximate.
  IPv4 only."
  (:require [jolt.ffi :as ffi]
            [jolt.io-poller :as poller]
            [clojure.string :as str]))

;; -- FFI --------------------------------------------------------------------
(ffi/load-library)
(def ^:private AF-INET 2)
(def ^:private SOCK-STREAM 1)

(ffi/defcfn c-socket      "socket"      [:int :int :int] :int)
(ffi/defcfn c-connect     "connect"     [:int :pointer :int] :int :blocking)
(ffi/defcfn c-bind        "bind"        [:int :pointer :int] :int)
(ffi/defcfn c-listen      "listen"      [:int :int] :int)
(ffi/defcfn c-accept      "accept"      [:int :pointer :pointer] :int :blocking)
(ffi/defcfn c-setsockopt  "setsockopt"  [:int :int :int :pointer :int] :int)
(ffi/defcfn c-getsockname "getsockname" [:int :pointer :pointer] :int)
(ffi/defcfn c-recv        "recv"        [:int :pointer :size_t :int] :ssize_t :blocking)
(ffi/defcfn c-send        "send"        [:int :pointer :size_t :int] :ssize_t :blocking)
(ffi/defcfn c-close       "close"       [:int] :int)
;; ioctl is (int fd, unsigned long request, ...) — the :varargs marker puts the
;; third argument where the callee's va_list reads it. Binding it fixed-arity
;; instead is what makes Apple arm64 return SUCCESS with the out-parameter
;; untouched, since variadic arguments travel on the stack there.
(ffi/defcfn c-ioctl       "ioctl"       [:int :ulong :varargs :pointer] :int)
(ffi/defcfn c-inet-addr   "inet_addr"   [:pointer] :uint)
(ffi/defcfn c-gethostbyname "gethostbyname" [:pointer] :pointer :blocking)

;; macOS carries BSD constants and a sin_len-led sockaddr; Linux has a 16-bit
;; sin_family and needs MSG_NOSIGNAL on send — without it a write to a
;; peer-closed socket raises SIGPIPE and kills the process (macOS suppresses
;; the signal per-fd via the SO_NOSIGPIPE socket option instead).
(def ^:private macos?
  (str/includes? (str/lower-case (or (System/getProperty "os.name") "")) "mac"))
(def ^:private sol-socket   (if macos? 0xffff 1))
(def ^:private so-reuse     (if macos? 4 2))
(def ^:private so-nosigpipe 0x1022)
(def ^:private msg-nosignal (if macos? 0 0x4000))
(def ^:private fionread (if macos? 0x4004667F 0x541B))

;; -- sockaddr helpers ---------------------------------------------------------

(defn- resolve-host [host]
  ;; sin_addr (network byte order) for a numeric IP or hostname (IPv4 only).
  ;; string->ptr NUL-terminates — a bare alloc+write-array leaves the
  ;; terminator to whatever malloc hands back.
  (let [hp (ffi/string->ptr (str host))]
    (try
      (let [addr (c-inet-addr hp)]
        (if (= addr 4294967295) ;; INADDR_NONE: not a numeric IP, try DNS
          (let [he (c-gethostbyname hp)]
            (when (ffi/null? he)
              (throw (java.io.IOException. (str "unknown host: " host))))
            (let [h-addr-list (ffi/read he :uptr 24)
                  h-addr (ffi/read h-addr-list :uptr 0)]
              (ffi/read h-addr :uint 0)))
          addr))
      (finally (ffi/free hp)))))

(defn- ip->str [ip]
  ;; ip is sin_addr in network byte order read back as a native (little-endian)
  ;; uint, so the low byte is the first octet.
  (str (bit-and ip 0xff) "."
       (bit-and (bit-shift-right ip 8) 0xff) "."
       (bit-and (bit-shift-right ip 16) 0xff) "."
       (bit-and (bit-shift-right ip 24) 0xff)))

(defn- make-sockaddr [ip port]
  ;; sockaddr_in (16 bytes): header(2) + sin_port(2, network order) +
  ;; sin_addr(4) + padding(8). BSD's header is sin_len + one-byte sin_family;
  ;; Linux's is a 16-bit little-endian sin_family.
  (let [sa (ffi/alloc 16)]
    (dotimes [i 16] (ffi/write sa :uint8 i 0))
    (if macos?
      (do (ffi/write sa :uint8 0 16)          ;; sin_len
          (ffi/write sa :uint8 1 AF-INET))
      (ffi/write sa :uint8 0 AF-INET))
    (ffi/write sa :uint8 2 (bit-and (bit-shift-right port 8) 0xff))
    (ffi/write sa :uint8 3 (bit-and port 0xff))
    (ffi/write sa :uint 4 ip)
    sa))

(defn- make-sockaddr-in [host port]
  (make-sockaddr (resolve-host host) port))

(defn- sa-port [sa]
  (bit-or (bit-shift-left (ffi/read sa :uint8 2) 8) (ffi/read sa :uint8 3)))
(defn- sa-addr [sa]
  (ip->str (ffi/read sa :uint 4)))

(defn- local-port [fd]
  (let [sa (ffi/alloc 16) lenp (ffi/alloc 4)]
    (try
      (ffi/write lenp :int 0 16)
      (if (neg? (c-getsockname fd sa lenp)) 0 (sa-port sa))
      (finally (ffi/free sa) (ffi/free lenp)))))

(defn- set-opt-1! [fd opt]
  (let [p (ffi/alloc 4)]
    (try
      (ffi/write p :int 0 1)
      (c-setsockopt fd sol-socket opt p 4)
      (finally (ffi/free p)))))

(defn- guard-fd! [fd]
  ;; accepted fds don't reliably inherit socket options — set SO_NOSIGPIPE
  ;; explicitly on every fd we hand out, and O_NONBLOCK so the R8 readiness
  ;; interception can park a fiber instead of pinning its carrier.
  (when macos? (set-opt-1! fd so-nosigpipe))
  (poller/nonblock! fd))

(defn- new-fd! []
  (let [fd (c-socket AF-INET SOCK-STREAM 0)]
    (when (neg? fd) (throw (java.io.IOException. "socket() failed")))
    (set-opt-1! fd so-reuse)
    (guard-fd! fd)
    fd))

;; -- tagged-table constructors ------------------------------------------------
;; a "class" entry makes (class x) report the mirrored class name; instance?
;; and str rendering are registered at the bottom of the file.

(defn- tt [tag class]
  (doto (jolt.host/tagged-table tag)
    (jolt.host/ref-put! :class class)))

(defn- make-inet-address [host addr]
  (doto (tt :inet-address "java.net.Inet4Address")
    (jolt.host/ref-put! :host host)
    (jolt.host/ref-put! :address addr)))

(defn- host-arg->str [h]
  ;; Socket(InetAddress, port) / ServerSocket(..., bindAddr) pass the
  ;; InetAddress table; take its literal before falling back to str.
  (if (= :inet-address (jolt.host/ref-get h :jolt/type))
    (str (or (jolt.host/ref-get h :address) (jolt.host/ref-get h :host)))
    (str h)))

(defn- connect-fd! [fd host port]
  ;; resolve + connect; frees the sockaddr either way. Returns the resolved ip.
  ;; The fd is O_NONBLOCK (fibers R8), so connect answers EINPROGRESS; wait for
  ;; writability (parking on a fiber, blocking kevent on a thread — the same
  ;; dispatch every other IO path uses), then read SO_ERROR for the verdict.
  (let [ip (resolve-host host)
        sa (make-sockaddr ip port)
        r  (loop []
             (let [r (c-connect fd sa 16)]
               (cond
                 (zero? r) 0
                 (poller/connect-pending? (poller/errno))
                 (do (poller/wait-ready fd :write)
                     (let [e (poller/so-error fd)]
                       (if (zero? e)
                         0
                         (if (poller/connect-pending? e) (recur) -1))))
                 :else r)))]
    (ffi/free sa)
    (when (neg? r)
      (throw (java.io.IOException. (str "connect failed: " host ":" port))))
    ip))

;; -- Socket ------------------------------------------------------------------

(defn- socket-ctor [& args]
  (let [fd   (new-fd!)
        inst (tt :socket "java.net.Socket")]
    (jolt.host/ref-put! inst :fd fd)
    (jolt.host/ref-put! inst :closed? false)
    (jolt.host/ref-put! inst :connected? false)
    (when (= 2 (count args))
      (let [h  (host-arg->str (first args))
            p  (int (second args))
            ip (try (connect-fd! fd h p)
                    (catch java.io.IOException e (c-close fd) (throw e)))]
        (jolt.host/ref-put! inst :connected? true)
        (jolt.host/ref-put! inst :host h)
        (jolt.host/ref-put! inst :remote-addr (ip->str ip))
        (jolt.host/ref-put! inst :port p)
        (jolt.host/ref-put! inst :local-port (local-port fd))))
    inst))

(defn- socket-close! [self]
  (when-not (jolt.host/ref-get self :closed?)
    (jolt.host/ref-put! self :closed? true)
    (c-close (jolt.host/ref-get self :fd)))
  nil)

(defn- socket-connect! [self endpoint]
  (when (jolt.host/ref-get self :closed?)
    (throw (java.io.IOException. "Socket closed")))
  (when (jolt.host/ref-get self :connected?)
    (throw (java.io.IOException. "Already connected")))
  (let [h  (str (jolt.host/ref-get endpoint :host))
        p  (jolt.host/ref-get endpoint :port)
        fd (jolt.host/ref-get self :fd)
        ip (connect-fd! fd h p)]
    (jolt.host/ref-put! self :connected? true)
    (jolt.host/ref-put! self :host h)
    (jolt.host/ref-put! self :remote-addr (ip->str ip))
    (jolt.host/ref-put! self :port p)
    (jolt.host/ref-put! self :local-port (local-port fd)))
  nil)

(defn- socket->str [self]
  (if (jolt.host/ref-get self :connected?)
    (str "Socket[addr=" (or (jolt.host/ref-get self :host) "")
         "/" (or (jolt.host/ref-get self :remote-addr) "")
         ",port=" (or (jolt.host/ref-get self :port) 0)
         ",localport=" (or (jolt.host/ref-get self :local-port) 0) "]")
    "Socket[unconnected]"))

(def ^:private socket-methods
  {"connect"
   (fn
     ([self endpoint] (socket-connect! self endpoint))
     ;; Java's timeout is milliseconds-until-abort; this connect is always
     ;; blocking (equivalent to timeout 0). Divergence, documented in the ns.
     ([self endpoint _timeout] (socket-connect! self endpoint)))

   "getInputStream"
   (fn [self]
     (doto (tt :socket-input-stream "java.net.SocketInputStream")
       (jolt.host/ref-put! :fd (jolt.host/ref-get self :fd))
       (jolt.host/ref-put! :socket self)))

   "getOutputStream"
   (fn [self]
     (doto (tt :socket-output-stream "java.net.SocketOutputStream")
       (jolt.host/ref-put! :fd (jolt.host/ref-get self :fd))
       (jolt.host/ref-put! :socket self)))

   "close"        socket-close!
   "isConnected"  (fn [self] (boolean (jolt.host/ref-get self :connected?)))
   "isClosed"     (fn [self] (boolean (jolt.host/ref-get self :closed?)))
   "isBound"      (fn [self] (boolean (jolt.host/ref-get self :connected?)))
   "getLocalPort" (fn [self] (or (jolt.host/ref-get self :local-port)
                                 (local-port (jolt.host/ref-get self :fd))))
   "getPort"      (fn [self] (or (jolt.host/ref-get self :port) 0))
   "toString"     socket->str

   "getInetAddress"
   (fn [self]
     (make-inet-address (jolt.host/ref-get self :host)
                        (jolt.host/ref-get self :remote-addr)))

   "getRemoteSocketAddress"
   (fn [self]
     (doto (tt :inet-socket-address "java.net.InetSocketAddress")
       (jolt.host/ref-put! :host (or (jolt.host/ref-get self :remote-addr)
                                     (jolt.host/ref-get self :host)))
       (jolt.host/ref-put! :port (jolt.host/ref-get self :port))))})

;; -- SocketInputStream -------------------------------------------------------
(defn- io-call [op fd wait-kind]
  ;; Run one blocking-capable syscall with the fd in O_NONBLOCK mode (fibers
  ;; R8). EAGAIN waits for readiness — parking the fiber on the poller when
  ;; there is a current fiber, blocking on a private kevent/epoll_wait when
  ;; there is not — and retries; EINTR retries immediately; anything else is
  ;; the syscall's real answer, returned as-is (callers read errno semantics).
  (loop []
    (let [r (op)]
      (cond
        (and (neg? r) (poller/eintr?)) (recur)
        (and (neg? r) (poller/eagain?)) (do (poller/wait-ready fd wait-kind) (recur))
        :else r))))

(defn- do-recv [fd buf len]
  ;; n <= 0 answers EOF: recv 0 is orderly shutdown; a negative return (error)
  ;; also reads as EOF because errno isn't reachable to tell ECONNRESET from
  ;; EINTR. Java throws SocketException there — documented divergence.
  (let [n (io-call #(c-recv fd buf len 0) fd :read)]
    (if (pos? n)
      {:n n :bytes (ffi/read-array buf n)}
      {:n -1 :bytes nil})))

;; InputStream.available — the same question the JVM asks, through the same
;; syscall: ioctl(fd, FIONREAD, &n) reports what has arrived without reading it
;; or waiting for more. The binding is what has to be right; see c-ioctl above.
(defn- socket-available [self]
  ;; Closed is an error on both, and here it is a KNOWN one — the socket carries
  ;; the flag — so it raises rather than answering, where a recv error can only
  ;; read as EOF. SocketException is the class Java raises and a subclass of
  ;; IOException, so a catch of either sees it. Asking the kernel is also not an
  ;; option once the fd is closed: the number is free to be reused by the next
  ;; socket, and the count would be somebody else's.
  (when (jolt.host/ref-get (jolt.host/ref-get self :socket) :closed?)
    (throw (java.net.SocketException. "Socket closed")))
  (let [fd (jolt.host/ref-get self :fd)
        out (ffi/alloc 4)]
    (try
      (ffi/write out :int 0 0)
      ;; a failed ioctl reads as "nothing there", the way a failed recv reads as
      ;; EOF — errno is not reachable to say more
      (if (neg? (c-ioctl fd fionread out)) 0 (max 0 (ffi/read out :int 0)))
      (finally (ffi/free out)))))

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
      (let [fd (jolt.host/ref-get self :fd) len (alength b)]
        (if (zero? len) 0
            (let [buf (ffi/alloc len)]
              (try
                (let [{:keys [n bytes]} (do-recv fd buf len)]
                  (if (pos? n) (do (dotimes [i n] (aset b i (nth bytes i))) n) -1))
                (finally (ffi/free buf)))))))
     ([self b off len]
      (let [fd (jolt.host/ref-get self :fd)]
        (if (zero? len) 0
            (let [buf (ffi/alloc len)]
              (try
                (let [{:keys [n bytes]} (do-recv fd buf len)]
                  (if (pos? n) (do (dotimes [i n] (aset b (+ off i) (nth bytes i))) n) -1))
                (finally (ffi/free buf))))))))
   "available" (fn [self] (socket-available self))
   "close"     (fn [self] (socket-close! (jolt.host/ref-get self :socket)))})

;; -- SocketOutputStream ------------------------------------------------------
(defn- send-fully! [fd buf len]
  ;; loop over short sends; a non-positive return is a dead peer (EPIPE /
  ;; ECONNRESET) — throw like Java rather than silently dropping the rest.
  (loop [off 0]
    (when (< off len)
      (let [s (io-call #(c-send fd (+ buf off) (- len off) msg-nosignal) fd :write)]
        (when-not (pos? s)
          (throw (java.io.IOException. "Broken pipe")))
        (recur (+ off s))))))

(def ^:private socket-output-stream-methods
  {"write"
   (fn
     ([self b]
      (let [fd (jolt.host/ref-get self :fd) buf (ffi/alloc 1)]
        (try
          (ffi/write buf :uint8 0 (bit-and (int b) 0xff))
          (send-fully! fd buf 1)
          (finally (ffi/free buf)))))
     ([self bytes off len]
      (when (pos? len)
        (let [fd (jolt.host/ref-get self :fd) buf (ffi/alloc len)]
          (try
            (dotimes [i len]
              (ffi/write buf :uint8 i (bit-and (aget bytes (+ off i)) 0xff)))
            (send-fully! fd buf len)
            (finally (ffi/free buf)))))))
   "flush" (fn [self] nil)
   "close" (fn [self] (socket-close! (jolt.host/ref-get self :socket)))})

;; -- ServerSocket ------------------------------------------------------------
(defn- server-ctor [& args]
  ;; [] [port] [port backlog] [port backlog bindAddr] — binds the wildcard
  ;; address unless bindAddr says otherwise, like Java. Port 0 asks the kernel
  ;; for an ephemeral port; getsockname recovers the real one.
  (let [port      (if (pos? (count args)) (int (first args)) 0)
        backlog   (if (>= (count args) 2) (int (second args)) 50)
        bind-host (if (>= (count args) 3) (host-arg->str (nth args 2)) "0.0.0.0")
        fd        (new-fd!)
        sa        (make-sockaddr-in bind-host port)]
    (when (neg? (c-bind fd sa 16))
      (c-close fd) (ffi/free sa)
      (throw (java.io.IOException. (str "bind failed on port " port))))
    (ffi/free sa)
    (when (neg? (c-listen fd backlog))
      (c-close fd)
      (throw (java.io.IOException. "listen() failed")))
    (doto (tt :server-socket "java.net.ServerSocket")
      (jolt.host/ref-put! :fd fd)
      (jolt.host/ref-put! :closed? false)
      (jolt.host/ref-put! :bind-addr bind-host)
      (jolt.host/ref-put! :port (if (zero? port) (local-port fd) port)))))

(defn- server->str [self]
  (let [ba (or (jolt.host/ref-get self :bind-addr) "0.0.0.0")]
    (str "ServerSocket[addr=" ba "/" ba
         ",localport=" (or (jolt.host/ref-get self :port) 0) "]")))

(def ^:private server-socket-methods
  {"accept"
   (fn [self]
     (when (jolt.host/ref-get self :closed?)
       (throw (java.io.IOException. "ServerSocket closed")))
     (let [sa (ffi/alloc 16) lenp (ffi/alloc 4)]
       (try
         (ffi/write lenp :int 0 16)
         (let [cfd (io-call #(c-accept (jolt.host/ref-get self :fd) sa lenp)
                            (jolt.host/ref-get self :fd) :read)]
           (when (neg? cfd) (throw (java.io.IOException. "accept() failed")))
           (guard-fd! cfd)
           (doto (tt :socket "java.net.Socket")
             (jolt.host/ref-put! :fd cfd)
             (jolt.host/ref-put! :closed? false)
             (jolt.host/ref-put! :connected? true)
             (jolt.host/ref-put! :host (sa-addr sa))
             (jolt.host/ref-put! :remote-addr (sa-addr sa))
             (jolt.host/ref-put! :port (sa-port sa))
             (jolt.host/ref-put! :local-port (local-port cfd))))
         (finally (ffi/free sa) (ffi/free lenp)))))

   "close"
   (fn [self]
     (when-not (jolt.host/ref-get self :closed?)
       (jolt.host/ref-put! self :closed? true)
       (c-close (jolt.host/ref-get self :fd)))
     nil)

   "isClosed"     (fn [self] (boolean (jolt.host/ref-get self :closed?)))
   "isBound"      (fn [self] (not (jolt.host/ref-get self :closed?)))
   "getLocalPort" (fn [self] (or (jolt.host/ref-get self :port) 0))
   "toString"     server->str})

;; -- InetSocketAddress -------------------------------------------------------
(defn- isa-ctor [& args]
  ;; (InetSocketAddress. port) is the wildcard address, like Java.
  (let [h (if (= 1 (count args)) "0.0.0.0" (host-arg->str (first args)))
        p (int (if (= 1 (count args)) (first args) (second args)))]
    (doto (tt :inet-socket-address "java.net.InetSocketAddress")
      (jolt.host/ref-put! :host h)
      (jolt.host/ref-put! :port p))))

(defn- isa->str [self]
  (str (or (jolt.host/ref-get self :host) "0.0.0.0")
       ":" (or (jolt.host/ref-get self :port) 0)))

(def ^:private inet-socket-address-methods
  {"getHostName"   (fn [self] (or (jolt.host/ref-get self :host) "0.0.0.0"))
   "getHostString" (fn [self] (or (jolt.host/ref-get self :host) "0.0.0.0"))
   "getPort"       (fn [self] (or (jolt.host/ref-get self :port) 0))
   "isUnresolved"  (fn [self] false)
   "getAddress"
   (fn [self]
     (let [h (or (jolt.host/ref-get self :host) "0.0.0.0")]
       (make-inet-address h (try (ip->str (resolve-host h))
                                 (catch java.io.IOException _ nil)))))
   "toString"      isa->str})

;; -- InetAddress --------------------------------------------------------------
(defn- inet-address-ctor [& _]
  (make-inet-address "localhost" "127.0.0.1"))

(defn- inet-address->str [self]
  (str (or (jolt.host/ref-get self :host) "")
       "/" (or (jolt.host/ref-get self :address) "")))

(def ^:private inet-address-methods
  {"getHostAddress" (fn [self] (or (jolt.host/ref-get self :address) "127.0.0.1"))
   "getHostName"    (fn [self] (or (jolt.host/ref-get self :host)
                                   (jolt.host/ref-get self :address)))
   "toString"       inet-address->str})

(def ^:private inet-address-statics
  {"getByName"
   (fn [h] (make-inet-address (str h) (ip->str (resolve-host h))))
   "getLoopbackAddress"
   (fn [] (make-inet-address "localhost" "127.0.0.1"))})

;; -- value-semantics + registration -------------------------------------------

(def ^:private tag->classes
  {:socket               #{"Socket" "java.net.Socket"}
   :server-socket        #{"ServerSocket" "java.net.ServerSocket"}
   :socket-input-stream  #{"InputStream" "java.io.InputStream"}
   :socket-output-stream #{"OutputStream" "java.io.OutputStream"}
   :inet-socket-address  #{"InetSocketAddress" "java.net.InetSocketAddress"
                           "SocketAddress" "java.net.SocketAddress"}
   :inet-address         #{"InetAddress" "java.net.InetAddress"
                           "Inet4Address" "java.net.Inet4Address"}})

(def ^:private tag->render
  {:socket              socket->str
   :server-socket       server->str
   :inet-socket-address isa->str
   :inet-address        inet-address->str})

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
    (clojure.core/__register-class-statics! "InetAddress" inet-address-statics)
    (clojure.core/__register-class-statics! "java.net.InetAddress" inet-address-statics)

    (clojure.core/__register-class-ctor! "Socket" socket-ctor)
    (clojure.core/__register-class-ctor! "java.net.Socket" socket-ctor)

    (clojure.core/__register-class-ctor! "ServerSocket" server-ctor)
    (clojure.core/__register-class-ctor! "java.net.ServerSocket" server-ctor)

    ;; (instance? java.net.Socket s) etc.; only ever asserts true — anything
    ;; else defers to the next check and the built-ins.
    (clojure.core/__register-instance-check!
      (fn [cn val]
        (let [cs (tag->classes (jolt.host/ref-get val :jolt/type))]
          (when (and cs (contains? cs cn)) true))))

    ;; (str sock) renders through toString like Java; pred is two cheap lookups.
    (clojure.core/__register-str!
      (fn [x] (contains? tag->render (jolt.host/ref-get x :jolt/type)))
      (fn [x] ((tag->render (jolt.host/ref-get x :jolt/type)) x)))
    true))

(register-all!)
