;; java.net.Socket / ServerSocket / InetSocketAddress for Jolt via jolt.ffi.
;; C sockets — POSIX, and ws2_32 on Windows — plus jolt.host/tagged-table and
;; ref-put!/ref-get for state.
;;
;; Usage: (require 'jolt.socket)  ;; registers classes globally

(ns jolt.socket
  "Socket support over the host's C sockets — POSIX, and Winsock on Windows.
  Registers Socket, ServerSocket, InetSocketAddress, InetAddress and the socket
  stream classes with the host class registry.

  Deliberate divergences from the JVM (test/conformance/known-divergences.edn):
  a recv error reads as EOF (-1) rather than throwing, and toString formats are
  approximate. IPv4 only.

  On Windows, additionally: sockets are blocking, because the readiness poller is
  kqueue/epoll and there is none there — so a fiber blocked on a socket holds its
  carrier rather than parking, which is a jolt superset java.net never promised,
  and SO_TIMEOUT and the connect timeout are accepted but not enforced, since
  both are waits on that poller — and NetworkInterface enumerates nothing, for
  want of a GetAdaptersAddresses walk. These are recorded entries; InetAddress
  and the sockets themselves work (jolt-lang/jolt#1107)."
  (:require [jolt.ffi :as ffi]
            [jolt.io-poller :as poller]
            [jolt.socket.native :as native]
            [clojure.string :as str]))

;; -- platform ----------------------------------------------------------------
;; Every C call, constant and struct layout lives in jolt.socket.native, which
;; knows macOS, Linux and Windows apart (jolt-lang/jolt#1107 is what answering
;; Linux's numbers on Windows cost). What is left here is the java.net object
;; model over it.
(def ^:private windows? (= :windows native/os))

;; -- sockaddr helpers ---------------------------------------------------------

(defn- resolve-host
  "The IPv4 address host names, as a dotted quad — a numeric literal answers
  itself without a lookup."
  [host]
  (let [{:keys [addrs]} (native/resolve-addrs (str host) 0 {:family native/af-inet})]
    (native/free-addrs! addrs)
    (or (:ip (first addrs))
        (throw (java.net.UnknownHostException. (str host))))))

(defn- make-sockaddr-in
  "[sa len] for host:port, IPv4. The caller frees sa."
  [host port]
  (native/make-sockaddr native/af-inet (resolve-host host) port))

(defn- local-port [fd]
  (max 0 (native/local-port fd)))

(defn- guard-fd! [fd]
  ;; accepted fds don't reliably inherit socket options — close-on-exec and
  ;; SO_NOSIGPIPE go on every fd we hand out (native/guard-accepted!), and
  ;; O_NONBLOCK so the R8 readiness interception can park a fiber instead of
  ;; pinning its carrier.
  ;;
  ;; nonblock! is a no-op on Windows, deliberately: there is no readiness poller
  ;; there (jolt.io-poller is kqueue/epoll), so a non-blocking socket would answer
  ;; WSAEWOULDBLOCK with nothing able to wait for it. Blocking sockets are also
  ;; what the JVM's own java.net.Socket is — the non-blocking fd plus the poller
  ;; is jolt's fiber extension over it, not the java.net contract — so this is a
  ;; missing jolt superset on Windows, not a missing java.net behaviour. Recorded
  ;; in test/conformance/known-divergences.edn (jolt-lang/jolt#1107).
  (native/guard-accepted! fd)
  (poller/nonblock! fd))

(defn- new-fd! []
  (let [fd (native/new-socket native/af-inet)]
    ;; SO_REUSEADDR on POSIX, as the JDK sets it; nothing on Windows, where the
    ;; option means sharing a live listener and the JDK binds exclusively, so a
    ;; busy port is a BindException there (native/set-listener-reuse!)
    (native/set-listener-reuse! fd)
    (poller/nonblock! fd)
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

;; -- fd lifetime ---------------------------------------------------------------
;; A socket's fd is live while any operation is using it. Closing marks the
;; socket closed, which stops new operations, and wakes the ones blocked on it
;; (poller/cancel!); the fd itself is closed by whichever of the closer or the
;; last operation out comes second. That is the JDK's shape, and the reason is
;; the same: a closed fd number is handed to the next socket or pipe the process
;; opens, so an operation that retried on it would read that socket's bytes or
;; write to its peer (jolt#1183, jolt-hmnr). process.ss counts its pipe fds the
;; same way.
;;
;; Windows has no poller to wake anything: its sockets are blocking, and only
;; closesocket makes a blocked recv or accept return. So close releases the fd
;; at once there, and the woken operation raises on seeing the socket closed.
(defn- fd-release! [fd]
  (poller/forget! fd)
  (native/c-close fd))

;; Under the owner's lock: claims the release, answering the fd to close, when the
;; socket is closed and nothing is using it (or FORCE?).
(defn- claim-release! [owner force?]
  (when (and (jolt.host/ref-get owner :closed?)
             (or force? (zero? (or (jolt.host/ref-get owner :ops) 0)))
             (not (jolt.host/ref-get owner :released?)))
    (jolt.host/ref-put! owner :released? true)
    (jolt.host/ref-get owner :fd)))

(defn- op-enter! [owner]
  (locking owner
    (when (jolt.host/ref-get owner :closed?)
      (throw (java.net.SocketException. "Socket closed")))
    (jolt.host/ref-put! owner :ops (inc (or (jolt.host/ref-get owner :ops) 0)))))

(defn- op-leave! [owner]
  (when-let [fd (locking owner
                  (jolt.host/ref-put! owner :ops (dec (jolt.host/ref-get owner :ops)))
                  (claim-release! owner false))]
    (fd-release! fd)))

(defmacro ^:private with-op [owner & body]
  `(let [o# ~owner]
     (op-enter! o#)
     (try ~@body (finally (op-leave! o#)))))

(defn- close-owner! [owner]
  (let [[first? fd] (locking owner
                      (if (jolt.host/ref-get owner :closed?)
                        [false nil]
                        (do (jolt.host/ref-put! owner :closed? true)
                            [true (claim-release! owner windows?)])))]
    (cond
      fd (fd-release! fd)
      first? (poller/cancel! (jolt.host/ref-get owner :fd))))
  nil)

;; An operation woken by close raises what the JVM's does: a read, accept or
;; connect "Socket closed", a write cut off mid-send "Broken pipe".
(defn- raise-if-closed! [owner msg]
  (when (jolt.host/ref-get owner :closed?)
    (throw (java.net.SocketException. msg))))

(defn- connect-fd! [owner fd host port deadline]
  ;; resolve + connect; frees the sockaddr either way. Returns the resolved ip.
  ;; The fd is O_NONBLOCK (fibers R8), so connect answers EINPROGRESS; wait for
  ;; writability (parking on a fiber, blocking kevent on a thread — the same
  ;; dispatch every other IO path uses), then read SO_ERROR for the verdict.
  ;; DEADLINE (epoch ms, or nil for none) bounds that wait: connect(endpoint,
  ;; timeout). Blocking Windows sockets never get there, so the bound is not
  ;; enforced on Windows (recorded divergence, jolt-lang/jolt#1107).
  (let [ip (resolve-host host)
        [sa len] (native/make-sockaddr native/af-inet ip port)
        ;; 0 when connected, else the failure's errno (-1 when there is none)
        e  (try
             (loop []
               (let [[r e] (native/c-connect fd sa len)]
                 (cond
                   (zero? r) 0
                   (native/connect-pending? e)
                   (let [t (poller/wait-ready fd :write deadline)]
                     (raise-if-closed! owner "Socket closed")
                     (when (= t :timeout)
                       (throw (java.net.SocketTimeoutException. "Connect timed out")))
                     (let [e (native/pending-error fd)]
                       (cond (zero? e) 0
                             (native/connect-pending? e) (recur)
                             :else e)))
                   :else (if (pos? e) e -1))))
             (finally (ffi/free sa)))]
    (cond
      (zero? e) ip
      (= e native/econnrefused) (throw (java.net.ConnectException. "Connection refused"))
      :else (throw (java.io.IOException. (str "connect failed: " host ":" port))))))

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
            ip (try (connect-fd! inst fd h p nil)
                    (catch java.io.IOException e (fd-release! fd) (throw e)))]
        (jolt.host/ref-put! inst :connected? true)
        (jolt.host/ref-put! inst :host h)
        (jolt.host/ref-put! inst :remote-addr ip)
        (jolt.host/ref-put! inst :port p)
        (jolt.host/ref-put! inst :local-port (local-port fd))))
    inst))

(defn- socket-close! [self] (close-owner! self))

(defn- ensure-socket-open! [self]
  (when (jolt.host/ref-get self :closed?)
    (throw (java.net.SocketException. "Socket is closed"))))

;; getInputStream, getOutputStream and the two shutdowns refuse a socket that is
;; not connected, in the JDK's order: closed first, then unconnected.
(defn- ensure-socket-connected! [self]
  (ensure-socket-open! self)
  (when-not (jolt.host/ref-get self :connected?)
    (throw (java.net.SocketException. "Socket is not connected"))))

;; shutdownInput / shutdownOutput (jolt-lang/jolt#1208). The flag is the JDK's
;; isInputShutdown / isOutputShutdown: set by a call that succeeds, kept after
;; close, and asked by the streams, since what the JDK answers after a half-close
;; is decided by the flag rather than by the kernel — a read after shutdownInput
;; is EOF even over data that had already arrived, which Linux would still hand
;; back. A write after shutdownOutput reaches send and fails there with EPIPE, as
;; the JDK's does. The shutdown also wakes a read parked on the poller, which
;; then sees the flag.
(defn- socket-shutdown! [self how flag already]
  (ensure-socket-connected! self)
  (when (jolt.host/ref-get self flag)
    (throw (java.net.SocketException. already)))
  ;; the flag goes up before the call: the shutdown wakes a parked read, which
  ;; must find it set rather than recv data SHUT_RD left queued
  (jolt.host/ref-put! self flag true)
  (with-op self
    (let [[r e] (native/c-shutdown (jolt.host/ref-get self :fd) how)]
      ;; ENOTCONN is not an error here, as it is not in the JDK's Net.shutdown:
      ;; macOS answers it once both directions have seen a FIN, and the socket
      ;; is then as shut down as the caller asked
      (when (and (neg? r) (not= e native/enotconn))
        (jolt.host/ref-put! self flag false)
        (throw (java.net.SocketException.
                 (native/error-message e))))))
  nil)

(defn- socket-connect! [self endpoint timeout]
  ;; The JDK's order: the timeout is validated before the socket's state, and
  ;; timeout 0 is the untimed connect the 1-arity is.
  (when (neg? timeout)
    (throw (IllegalArgumentException. "connect: timeout can't be negative")))
  (ensure-socket-open! self)
  (when (jolt.host/ref-get self :connected?)
    (throw (java.net.SocketException. "Already connected")))
  ;; A connect that fails closes the socket, as the JDK's does — a refused or
  ;; timed-out socket is not left half-connected for the caller to reuse.
  (try
    (with-op self
      (let [h  (str (jolt.host/ref-get endpoint :host))
            p  (jolt.host/ref-get endpoint :port)
            fd (jolt.host/ref-get self :fd)
            ip (connect-fd! self fd h p (when (pos? timeout)
                                          (+ (System/currentTimeMillis) timeout)))]
        (jolt.host/ref-put! self :connected? true)
        (jolt.host/ref-put! self :host h)
        (jolt.host/ref-put! self :remote-addr ip)
        (jolt.host/ref-put! self :port p)
        (jolt.host/ref-put! self :local-port (local-port fd))))
    (catch java.io.IOException e
      (close-owner! self)
      (throw e)))
  nil)

;; SO_TIMEOUT: milliseconds a read (Socket) or an accept (ServerSocket) may wait
;; before raising SocketTimeoutException; 0, the default, waits forever. It bounds
;; each call, not the connection, and a timeout leaves the socket usable. The
;; JDK validates it after the closed check; the two classes word the negative
;; case differently. Accepted sockets start at 0 — they do not inherit it.
(defn- so-timeout [self] (or (jolt.host/ref-get self :so-timeout) 0))

(defn- set-so-timeout! [self ms negative-msg]
  (when (jolt.host/ref-get self :closed?)
    (throw (java.net.SocketException. "Socket is closed")))
  (when (neg? ms) (throw (IllegalArgumentException. negative-msg)))
  (jolt.host/ref-put! self :so-timeout (int ms))
  nil)

(defn- get-so-timeout [self]
  (when (jolt.host/ref-get self :closed?)
    (throw (java.net.SocketException. "Socket is closed")))
  (so-timeout self))

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
     ([self endpoint] (socket-connect! self endpoint 0))
     ([self endpoint timeout] (socket-connect! self endpoint (int timeout))))

   "setSoTimeout" (fn [self ms] (set-so-timeout! self ms "timeout can't be negative"))
   "getSoTimeout" get-so-timeout

   "getInputStream"
   (fn [self]
     (ensure-socket-connected! self)
     (when (jolt.host/ref-get self :in-shutdown?)
       (throw (java.net.SocketException. "Socket input is shutdown")))
     ;; :jolt/in-stream: a java.io.InputStream to clojure.java.io's coercions
     ;; (io-streams.ss user-in-stream?), so io/reader, slurp and io/copy take it
     (doto (tt :socket-input-stream "java.net.SocketInputStream")
       (jolt.host/ref-put! :jolt/in-stream true)
       (jolt.host/ref-put! :fd (jolt.host/ref-get self :fd))
       (jolt.host/ref-put! :socket self)))

   "getOutputStream"
   (fn [self]
     (ensure-socket-connected! self)
     (when (jolt.host/ref-get self :out-shutdown?)
       (throw (java.net.SocketException. "Socket output is shutdown")))
     (doto (tt :socket-output-stream "java.net.SocketOutputStream")
       (jolt.host/ref-put! :jolt/out-stream true)
       (jolt.host/ref-put! :fd (jolt.host/ref-get self :fd))
       (jolt.host/ref-put! :socket self)))

   "close"        socket-close!
   "shutdownInput"
   (fn [self] (socket-shutdown! self native/shut-rd :in-shutdown? "Socket input is already shutdown"))
   "shutdownOutput"
   (fn [self] (socket-shutdown! self native/shut-wr :out-shutdown? "Socket output is already shutdown"))
   "isInputShutdown"  (fn [self] (boolean (jolt.host/ref-get self :in-shutdown?)))
   "isOutputShutdown" (fn [self] (boolean (jolt.host/ref-get self :out-shutdown?)))
   "isConnected"  (fn [self] (boolean (jolt.host/ref-get self :connected?)))
   "isClosed"     (fn [self] (boolean (jolt.host/ref-get self :closed?)))
   "isBound"      (fn [self] (boolean (jolt.host/ref-get self :connected?)))
   ;; -1 until connected, as Java answers for an unbound socket. Never asked of
   ;; the fd: once closed its number may be another socket's.
   "getLocalPort" (fn [self] (or (jolt.host/ref-get self :local-port) -1))
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
(defn- io-call
  ([owner op fd wait-kind] (io-call owner op fd wait-kind 0 nil))
  ([owner op fd wait-kind timeout-ms timeout-msg]
  ;; Run one blocking-capable syscall with the fd in O_NONBLOCK mode (fibers
  ;; R8). EAGAIN waits for readiness — parking the fiber on the poller when
  ;; there is a current fiber, blocking on a private kevent/epoll_wait when
  ;; there is not — and retries; EINTR retries immediately; anything else is
  ;; the syscall's real answer, returned as-is. OP hands back the captured
  ;; [result errno] pair from one foreign return path (jolt.ffi
  ;; :capture-native-error) — every binding io-call drives is declared that
  ;; way. The errno is spent on that classification and not returned, so a
  ;; caller sees a terminal failure only as a negative result.
  ;;
  ;; OWNER is the socket: the call counts as one of its operations, so a close
  ;; meanwhile wakes the wait and leaves the fd open until this call has left.
  ;; A socket found closed after a wait, or behind a failure, raises.
  ;;
  ;; A positive TIMEOUT-MS bounds the whole call (SO_TIMEOUT): the waits share
  ;; one deadline, and running out raises SocketTimeoutException with
  ;; TIMEOUT-MSG — never a -1 that a read would take for EOF. A close that lands
  ;; first still raises as a close.
  (with-op owner
    (let [closed-msg (if (= wait-kind :write) "Broken pipe" "Socket closed")
          deadline (when (pos? timeout-ms) (+ (System/currentTimeMillis) timeout-ms))]
      (loop []
        (let [[r e] (op)]
          (cond
            (and (neg? r) (native/eintr? e)) (recur)
            (and (neg? r) (native/eagain? e))
            (let [t (poller/wait-ready fd wait-kind deadline)]
              (raise-if-closed! owner closed-msg)
              (when (= t :timeout)
                (throw (java.net.SocketTimeoutException. timeout-msg)))
              (recur))
            :else
            (do
              (when (neg? r) (raise-if-closed! owner closed-msg))
              ;; A negative return that is neither retryable nor a wait is where a
              ;; socket read turns into EOF (do-recv below), and the caller then
              ;; sees a closed connection with no reason attached. It is the one
              ;; place a syscall failure goes quiet, so say what it was when asked.
              (when (and (neg? r) (jolt.host/getenv "JOLT_DEBUG"))
                (binding [*out* *err*]
                  (println "jolt.socket: fd" fd wait-kind "syscall failed, errno" e
                           "- answered as EOF")))
              r))))))))

;; A read of a socket whose input is shut down is EOF, whatever the kernel still
;; holds (see socket-shutdown!).
(defn- input-shutdown? [stream]
  (jolt.host/ref-get (jolt.host/ref-get stream :socket) :in-shutdown?))

(defn- do-recv [owner fd buf len]
  ;; n <= 0 answers EOF: recv 0 is orderly shutdown; a negative return (error)
  ;; also reads as EOF. Java throws SocketException there — documented
  ;; divergence. What is left of the error is a CHOICE, not a limitation:
  ;; io-call classifies a captured errno and returns only the syscall result,
  ;; so a reset arrives here as -1 with nothing attached. Retryable errnos are
  ;; already gone by this point — io-call loops on EINTR and waits out EAGAIN
  ;; — so every negative n here is terminal. Narrowing that to SocketException
  ;; on ECONNRESET means widening io-call's contract to hand the errno back.
  (let [n (if (jolt.host/ref-get owner :in-shutdown?)
            -1
            (io-call owner #(native/c-recv fd buf len 0) fd :read
                     (so-timeout owner) "Read timed out"))
        ;; a read parked when shutdownInput landed is woken by it, and may find
        ;; data that arrived meanwhile; the JDK answers EOF there too
        n (if (jolt.host/ref-get owner :in-shutdown?) -1 n)]
    (if (pos? n)
      {:n n :bytes (ffi/read-array buf n)}
      {:n -1 :bytes nil})))

;; A stream of a closed socket must not reach its fd: close frees the number,
;; and the next socket to open is handed it, so a read would take that socket's
;; bytes and a write would send to its peer (jolt#1183). The socket carries the
;; flag, so this is a KNOWN error and raises what Java raises — SocketException,
;; a subclass of IOException, so a catch of either sees it. A zero-length read
;; or write never reaches the fd and answers 0 / nil on a closed socket, as the
;; JVM's does, so callers guard after that shortcut.
(defn- ensure-open! [stream]
  (when (jolt.host/ref-get (jolt.host/ref-get stream :socket) :closed?)
    (throw (java.net.SocketException. "Socket closed"))))

;; InputStream.available — the same question the JVM asks, through the same
;; syscall: ioctl(fd, FIONREAD, &n) reports what has arrived without reading it
;; or waiting for more (native/available).
(defn- socket-available [self]
  ;; Closed raises rather than answering 0, where a recv error can only read as
  ;; EOF; asking the kernel would count some other socket's bytes. A shut-down
  ;; input has nothing to read, whatever arrived.
  (ensure-open! self)
  (if (input-shutdown? self)
    0
    (with-op (jolt.host/ref-get self :socket)
      ;; a failed ioctl reads as "nothing there", the way a failed recv reads
      ;; as EOF
      (max 0 (native/available (jolt.host/ref-get self :fd))))))

(def ^:private socket-input-stream-methods
  {"read"
   (fn
     ([self]
      (ensure-open! self)
      (let [fd (jolt.host/ref-get self :fd) buf (ffi/alloc 1)]
        (try
          (let [{:keys [n]} (do-recv (jolt.host/ref-get self :socket) fd buf 1)]
            (if (pos? n) (bit-and (ffi/read buf :uint8 0) 0xff) -1))
          (finally (ffi/free buf)))))
     ([self b]
      (let [fd (jolt.host/ref-get self :fd) len (alength b)]
        (if (zero? len) 0
            (let [_ (ensure-open! self) buf (ffi/alloc len)]
              (try
                (let [{:keys [n bytes]} (do-recv (jolt.host/ref-get self :socket) fd buf len)]
                  (if (pos? n) (do (dotimes [i n] (aset b i (nth bytes i))) n) -1))
                (finally (ffi/free buf)))))))
     ([self b off len]
      (let [fd (jolt.host/ref-get self :fd)]
        (if (zero? len) 0
            (let [_ (ensure-open! self) buf (ffi/alloc len)]
              (try
                (let [{:keys [n bytes]} (do-recv (jolt.host/ref-get self :socket) fd buf len)]
                  (if (pos? n) (do (dotimes [i n] (aset b (+ off i) (nth bytes i))) n) -1))
                (finally (ffi/free buf))))))))
   "available" (fn [self] (socket-available self))
   "close"     (fn [self] (socket-close! (jolt.host/ref-get self :socket)))})

;; -- SocketOutputStream ------------------------------------------------------
(defn- send-fully! [owner fd buf len]
  ;; loop over short sends; a non-positive return is a dead peer (EPIPE /
  ;; ECONNRESET) — throw like Java rather than silently dropping the rest.
  (loop [off 0]
    (when (< off len)
      (let [s (io-call owner #(native/c-send fd (+ buf off) (- len off) native/msg-nosignal) fd :write)]
        (when-not (pos? s)
          (throw (java.net.SocketException. "Broken pipe")))
        (recur (+ off s))))))

(defn- write-bytes! [self bytes off len]
  (when (pos? len)
    (ensure-open! self)
    (let [fd (jolt.host/ref-get self :fd) buf (ffi/alloc len)]
      (try
        (dotimes [i len]
          (ffi/write buf :uint8 (bit-and (aget bytes (+ off i)) 0xff) i))
        (send-fully! (jolt.host/ref-get self :socket) fd buf len)
        (finally (ffi/free buf))))))

(def ^:private socket-output-stream-methods
  {"write"
   (fn
     ;; OutputStream.write has TWO one-argument overloads on the JVM: write(int)
     ;; writes a byte, and write(byte[]) — the convenience method the abstract
     ;; class defines as write(b, 0, b.length) — writes the array. Dispatching on
     ;; the argument is the only way to tell them apart here, and without it a
     ;; byte array reached (int b) and reported "class [B cannot be cast to class
     ;; java.lang.Number", which named neither the socket nor the overload
     ;; (jolt#954). This is the same argument-shaped dispatch io-streams.ss's
     ;; out-stream/write does.
     ([self b]
      (if (bytes? b)
        (write-bytes! self b 0 (alength b))
        (let [_ (ensure-open! self)
              fd (jolt.host/ref-get self :fd)
              buf (ffi/alloc 1)]
          (try
            (ffi/write buf :uint8 (bit-and (int b) 0xff))
            (send-fully! (jolt.host/ref-get self :socket) fd buf 1)
            (finally (ffi/free buf))))))
     ([self bytes off len] (write-bytes! self bytes off len)))
   "flush" (fn [self] nil)
   "close" (fn [self] (socket-close! (jolt.host/ref-get self :socket)))})

;; -- ServerSocket ------------------------------------------------------------
;; Bind fd to bind-host:port and start listening, or throw. Shared by the ctor
;; forms that bind on construction and by the bind method, which is the only way
;; a no-arg socket ever becomes bound.
;;
;; close-on-failure? is the difference between the two callers, not a knob. The
;; ctor owns its fd and no caller has seen it yet, so a failed bind must close it
;; or it leaks. bind must NOT close, because Java leaves a failed bind's socket
;; open — the caller still holds it and is the one who closes or retries.
(defn- bind-listen! [fd bind-host port backlog close-on-failure?]
  ;; any failure closes fd when asked, an unknown bind host included
  (try
    (let [[sa len] (make-sockaddr-in bind-host port)]
      (when (neg? (first (try (native/c-bind fd sa len) (finally (ffi/free sa)))))
        (throw (java.io.IOException. (str "bind failed on port " port))))
      (when (neg? (first (native/c-listen fd backlog)))
        (throw (java.io.IOException. "listen() failed"))))
    (catch :default e
      (when close-on-failure? (native/c-close fd))
      (throw e))))

(defn- server-ctor [& args]
  ;; [] [port] [port backlog] [port backlog bindAddr]. The arg'd forms bind the
  ;; wildcard address unless bindAddr says otherwise, like Java, and port 0 asks
  ;; the kernel for an ephemeral port that getsockname recovers.
  ;;
  ;; The NO-ARG form makes an UNBOUND socket, which is what Java's does: nothing
  ;; is bound and nothing listens until bind is called. It used to bind an
  ;; ephemeral wildcard port right here, so (ServerSocket.) answered isBound true
  ;; and a real getLocalPort where the JVM answers false and -1, and it held a
  ;; port the caller never asked for.
  (if (zero? (count args))
    (doto (tt :server-socket "java.net.ServerSocket")
      (jolt.host/ref-put! :fd (new-fd!))
      (jolt.host/ref-put! :closed? false)
      (jolt.host/ref-put! :bound? false))
    (let [port      (int (first args))
          backlog   (if (>= (count args) 2) (int (second args)) 50)
          bind-host (if (>= (count args) 3) (host-arg->str (nth args 2)) "0.0.0.0")
          fd        (new-fd!)]
      (bind-listen! fd bind-host port backlog true)
      (doto (tt :server-socket "java.net.ServerSocket")
        (jolt.host/ref-put! :fd fd)
        (jolt.host/ref-put! :closed? false)
        (jolt.host/ref-put! :bound? true)
        (jolt.host/ref-put! :bind-addr bind-host)
        (jolt.host/ref-put! :port (if (zero? port) (local-port fd) port))))))

;; (.bind ss endpoint) / (.bind ss endpoint backlog), the two overloads
;; ServerSocket declares. Java's default backlog is 50, the same one the
;; [port backlog] ctor form defaults to.
(defn- server-bind! [self endpoint backlog]
  (when (jolt.host/ref-get self :closed?)
    (throw (java.net.SocketException. "Socket is closed")))
  (when (jolt.host/ref-get self :bound?)
    (throw (java.net.SocketException. "Already bound")))
  (let [h  (str (or (jolt.host/ref-get endpoint :host) "0.0.0.0"))
        p  (int (or (jolt.host/ref-get endpoint :port) 0))
        fd (jolt.host/ref-get self :fd)]
    (bind-listen! fd h p backlog false)
    (jolt.host/ref-put! self :bound? true)
    (jolt.host/ref-put! self :bind-addr h)
    (jolt.host/ref-put! self :port (if (zero? p) (local-port fd) p)))
  nil)

(defn- server->str [self]
  (if (jolt.host/ref-get self :bound?)
    (let [ba (or (jolt.host/ref-get self :bind-addr) "0.0.0.0")]
      (str "ServerSocket[addr=" ba "/" ba
           ",localport=" (or (jolt.host/ref-get self :port) 0) "]"))
    "ServerSocket[unbound]"))

(def ^:private server-socket-methods
  {"accept"
   (fn [self]
     (when (jolt.host/ref-get self :closed?)
       (throw (java.net.SocketException. "Socket is closed")))
     ;; A no-arg socket has an fd but nothing is listening on it, so accept would
     ;; block or fail obscurely. Java names the case.
     (when-not (jolt.host/ref-get self :bound?)
       (throw (java.net.SocketException. "Socket is not bound yet")))
     (let [[sa lenp] (native/alloc-sockaddr)]
       (try
         (let [cfd (io-call self #(native/c-accept (jolt.host/ref-get self :fd) sa lenp)
                            (jolt.host/ref-get self :fd) :read
                            (so-timeout self) "Accept timed out")]
           (when (neg? cfd) (throw (java.io.IOException. "accept() failed")))
           (guard-fd! cfd)
           (doto (tt :socket "java.net.Socket")
             (jolt.host/ref-put! :fd cfd)
             (jolt.host/ref-put! :closed? false)
             (jolt.host/ref-put! :connected? true)
             (jolt.host/ref-put! :host (native/sockaddr-ip sa))
             (jolt.host/ref-put! :remote-addr (native/sockaddr-ip sa))
             (jolt.host/ref-put! :port (native/sockaddr-port sa))
             (jolt.host/ref-put! :local-port (local-port cfd))))
         (finally (ffi/free sa) (ffi/free lenp)))))

   "close"
   (fn [self]
     (close-owner! self))

   "setSoTimeout" (fn [self ms] (set-so-timeout! self ms "timeout < 0"))
   "getSoTimeout" get-so-timeout

   "bind"
   (fn
     ([self endpoint] (server-bind! self endpoint 50))
     ([self endpoint backlog] (server-bind! self endpoint (int backlog))))

   "isClosed"     (fn [self] (boolean (jolt.host/ref-get self :closed?)))
   ;; Java's isBound asks "was this ever bound", not "is it usable now": it stays
   ;; true after close, and it is false on a fresh no-arg socket. Answering
   ;; (not closed?) had it backwards at both ends.
   "isBound"      (fn [self] (boolean (jolt.host/ref-get self :bound?)))
   ;; -1 until bound, as Java answers, and the port survives close.
   "getLocalPort" (fn [self]
                    (if (jolt.host/ref-get self :bound?)
                      (or (jolt.host/ref-get self :port) 0)
                      -1))
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
       (make-inet-address h (try (resolve-host h)
                                 (catch java.io.IOException _ nil)))))
   "toString"      isa->str})

;; -- host identity: local host + network interfaces ---------------------------

(defn- ifaddr-entries
  "One map per getifaddrs entry: {:name :ip :mac}. java.net here is IPv4 only,
  so a v6 entry keeps only its name — an interface with no IPv4 address (utun,
  wg, a v6-only link) still exists and getByName still finds it.

  Empty on Windows, which has no getifaddrs (native/interface-addresses).
  getLocalHost answers from gethostname plus the resolver, which is the primary
  path on every platform and the one the JDK's own Windows getLocalHost uses;
  NetworkInterface enumerates nothing there, recorded in
  test/conformance/known-divergences.edn (jolt-lang/jolt#1107)."
  []
  (map (fn [{:keys [family] :as e}]
         (if (= family native/af-inet)
           (dissoc e :family)
           (dissoc e :family :ip)))
       (native/interface-addresses)))

;; -- InetAddress --------------------------------------------------------------
(defn- inet-address-ctor [& _]
  (make-inet-address "localhost" "127.0.0.1"))

(defn- inet-address->str [self]
  (str (or (jolt.host/ref-get self :host) "")
       "/" (or (jolt.host/ref-get self :address) "")))

(def ^:private inet-address-methods
  {"getHostAddress" (fn [self] (or (jolt.host/ref-get self :address) "127.0.0.1"))
   ;; Resolves on first call and caches, as the JVM does — an address built
   ;; from a literal or read off an interface carries no name until asked.
   "getHostName"
   (fn [self]
     (let [h (jolt.host/ref-get self :host)]
       (if (str/blank? h)
         (let [addr (jolt.host/ref-get self :address)
               nm (or (and addr (native/reverse-lookup addr)) addr)]
           (jolt.host/ref-put! self :host nm)
           nm)
         h)))
   ;; The JVM reverse-resolves and caches; so does this, on the address it holds,
   ;; falling back to the name it was built with and then to the address itself.
   "getCanonicalHostName"
   (fn [self]
     (or (jolt.host/ref-get self :canonical)
         (let [addr (jolt.host/ref-get self :address)
               nm (or (and addr (native/reverse-lookup addr))
                      (jolt.host/ref-get self :host)
                      addr)]
           (jolt.host/ref-put! self :canonical nm)
           nm)))
   ;; the four address octets, network order — the JVM's byte[].
   "getAddress"
   (fn [self]
     (byte-array (mapv (fn [o] (Integer/parseInt o))
                       (str/split (or (jolt.host/ref-get self :address) "127.0.0.1") #"\."))))
   "equals"   (fn [self other]
                (boolean (and (= :inet-address (jolt.host/ref-get other :jolt/type))
                              (= (jolt.host/ref-get self :address)
                                 (jolt.host/ref-get other :address)))))
   "hashCode" (fn [self] (hash (jolt.host/ref-get self :address)))
   "isLoopbackAddress" (fn [self] (= "127.0.0.1" (jolt.host/ref-get self :address)))
   "toString"       inet-address->str})

(defn- all-addresses-of
  "Every IPv4 address the resolver has for host; a numeric literal resolves to
  itself without a lookup."
  [host]
  (let [{:keys [addrs]} (native/resolve-addrs (str host) 0 {:family native/af-inet})]
    (native/free-addrs! addrs)
    (when (empty? addrs)
      (throw (java.io.IOException. (str "unknown host: " host))))
    (mapv :ip addrs)))

(def ^:private inet-address-statics
  {"getByName"
   (fn [h] (make-inet-address (str h) (resolve-host h)))
   "getAllByName"
   ;; an array, as on the JVM, so alength and aget hold on the result.
   (fn [h] (object-array (mapv (fn [ip] (make-inet-address (str h) ip))
                               (all-addresses-of h))))
   "getLoopbackAddress"
   (fn [] (make-inet-address "localhost" "127.0.0.1"))
   ;; gethostname(2) plus whatever the resolver says that name is. A machine
   ;; whose own name does not resolve — a laptop off any DNS that knows it — is
   ;; answered from its own interfaces rather than by throwing
   ;; UnknownHostException, which is what the JVM does there.
   "getLocalHost"
   (fn []
     (let [nm (native/host-name)]
       (make-inet-address
         nm
         (or (try (resolve-host nm) (catch java.io.IOException _ nil))
             (first (remove (fn [ip] (= "127.0.0.1" ip))
                            (keep :ip (ifaddr-entries))))
             "127.0.0.1"))))})

;; -- java.util.Enumeration ----------------------------------------------------
;; NetworkInterface hands back Enumerations, which enumeration-seq drives
;; through hasMoreElements/nextElement.

(defn- make-enumeration [coll]
  (doto (tt :enumeration "java.util.Enumeration")
    (jolt.host/ref-put! :rest (seq coll))))

(def ^:private enumeration-methods
  {"hasMoreElements" (fn [self] (boolean (jolt.host/ref-get self :rest)))
   "nextElement"     (fn [self]
                       (let [r (jolt.host/ref-get self :rest)]
                         (when-not r
                           (throw (ex-info "no more elements" {})))
                         (jolt.host/ref-put! self :rest (next r))
                         (first r)))
   "toString"        (fn [_] "java.util.Enumeration")})

;; -- java.net.NetworkInterface ------------------------------------------------
;; A snapshot, as on the JVM: the addresses and hardware address are read when
;; the interface is looked up, not on each call.

(defn- make-network-interface [nm addresses mac]
  (doto (tt :network-interface "java.net.NetworkInterface")
    (jolt.host/ref-put! :name nm)
    (jolt.host/ref-put! :addresses addresses)
    (jolt.host/ref-put! :mac mac)))

(defn- network-interfaces []
  ;; Preserve the order getifaddrs reports, one interface per distinct name.
  (let [entries (ifaddr-entries)
        names (distinct (map :name entries))]
    (mapv (fn [nm]
            (let [mine (filter (fn [e] (= nm (:name e))) entries)]
              (make-network-interface
                nm
                ;; No hostname: an address read off an interface is unresolved
                ;; on the JVM too (its toString is "/1.2.3.4"), and resolving
                ;; every one of them eagerly would put a DNS round trip per
                ;; address in the way of enumerating interfaces. .getHostName
                ;; resolves on demand.
                (mapv (fn [e] (make-inet-address "" (:ip e))) (filter :ip mine))
                (first (keep :mac mine)))))
          names)))

(defn- ni->str [self]
  (str "name:" (jolt.host/ref-get self :name)
       " (" (jolt.host/ref-get self :name) ")"))

(def ^:private network-interface-methods
  {"getName"        (fn [self] (jolt.host/ref-get self :name))
   ;; jolt has no separate friendly name for an interface, as Linux does not
   ;; either — the JVM reports the name for both there.
   "getDisplayName" (fn [self] (jolt.host/ref-get self :name))
   "getInetAddresses" (fn [self] (make-enumeration (jolt.host/ref-get self :addresses)))
   "getHardwareAddress" (fn [self] (jolt.host/ref-get self :mac))
   "isLoopback"     (fn [self] (boolean (some (fn [a] (= "127.0.0.1" (jolt.host/ref-get a :address)))
                                              (jolt.host/ref-get self :addresses))))
   "toString"       ni->str})

(def ^:private network-interface-statics
  {"getNetworkInterfaces" (fn [] (make-enumeration (network-interfaces)))
   "getByName" (fn [nm] (or (first (filter (fn [ni] (= (str nm) (jolt.host/ref-get ni :name)))
                                           (network-interfaces)))
                            nil))
   "getByInetAddress"
   (fn [addr]
     (let [want (host-arg->str addr)]
       (or (first (filter (fn [ni]
                            (some (fn [a] (= want (jolt.host/ref-get a :address)))
                                  (jolt.host/ref-get ni :addresses)))
                          (network-interfaces)))
           nil)))})

;; -- value-semantics + registration -------------------------------------------

(def ^:private tag->classes
  {:socket               #{"Socket" "java.net.Socket"}
   :server-socket        #{"ServerSocket" "java.net.ServerSocket"}
   :socket-input-stream  #{"InputStream" "java.io.InputStream"}
   :socket-output-stream #{"OutputStream" "java.io.OutputStream"}
   :inet-socket-address  #{"InetSocketAddress" "java.net.InetSocketAddress"
                           "SocketAddress" "java.net.SocketAddress"}
   :inet-address         #{"InetAddress" "java.net.InetAddress"
                           "Inet4Address" "java.net.Inet4Address"}
   :network-interface    #{"NetworkInterface" "java.net.NetworkInterface"}
   :enumeration          #{"Enumeration" "java.util.Enumeration"}})

(def ^:private tag->render
  {:socket              socket->str
   :server-socket       server->str
   :inet-socket-address isa->str
   :inet-address        inet-address->str
   :network-interface   ni->str})

(def ^:private registered? (atom false))

(defn register-all! []
  (when (compare-and-set! registered? false true)
    (clojure.core/__register-class-methods! :socket socket-methods)
    (clojure.core/__register-class-methods! :socket-input-stream socket-input-stream-methods)
    (clojure.core/__register-class-methods! :socket-output-stream socket-output-stream-methods)
    (clojure.core/__register-class-methods! :server-socket server-socket-methods)
    (clojure.core/__register-class-methods! :inet-socket-address inet-socket-address-methods)
    (clojure.core/__register-class-methods! :inet-address inet-address-methods)
    (clojure.core/__register-class-methods! :network-interface network-interface-methods)
    (clojure.core/__register-class-methods! :enumeration enumeration-methods)

    (clojure.core/__register-class-ctor! "InetSocketAddress" isa-ctor)
    (clojure.core/__register-class-ctor! "java.net.InetSocketAddress" isa-ctor)

    (clojure.core/__register-class-ctor! "InetAddress" inet-address-ctor)
    (clojure.core/__register-class-ctor! "java.net.InetAddress" inet-address-ctor)
    (clojure.core/__register-class-statics! "InetAddress" inet-address-statics)
    (clojure.core/__register-class-statics! "java.net.InetAddress" inet-address-statics)

    (clojure.core/__register-class-statics! "NetworkInterface" network-interface-statics)
    (clojure.core/__register-class-statics! "java.net.NetworkInterface" network-interface-statics)

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
