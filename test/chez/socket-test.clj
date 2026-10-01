;; jolt.socket gate — the java.net.Socket/ServerSocket surface over real
;; loopback TCP. Run: bin/jolt run test/chez/socket-test.clj (smoke.sh greps
;; for "SOCKET-TEST OK"). Every server binds port 0 (kernel-assigned), so
;; parallel gates never collide on a port.
(ns socket-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]))

(require 'jolt.socket)

(def failures (atom []))

;; announce BEFORE evaluating, and flush: a check that blocks (accept/recv
;; with no peer) must name itself in the log rather than hang silently.
(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

;; connect lands in the listen backlog, so single-threaded connect-then-accept
;; is safe; every helper closes what it opens.
(defn with-pair [f]
  (let [server (java.net.ServerSocket. 0)
        client (java.net.Socket. "127.0.0.1" (.getLocalPort server))
        conn   (.accept server)]
    (try (f server client conn)
         (finally (.close conn) (.close client) (.close server)))))

;; roundtrip both directions
(with-pair
  (fn [server client conn]
    (let [msg (.getBytes "hello over tcp" "UTF-8")]
      (.write (.getOutputStream client) msg 0 (alength msg)))
    (let [buf (byte-array 64)
          n   (.read (.getInputStream conn) buf 0 64)]
      (check-eq "roundtrip client->server" (String. buf 0 n "UTF-8") "hello over tcp"))
    (let [msg (.getBytes "pong" "UTF-8")]
      (.write (.getOutputStream conn) msg 0 (alength msg)))
    (let [buf (byte-array 16)
          n   (.read (.getInputStream client) buf 0 16)]
      (check-eq "roundtrip server->client" (String. buf 0 n "UTF-8") "pong"))))

;; hostname resolution (gethostbyname path)
(let [server (java.net.ServerSocket. 0)
      client (java.net.Socket. "localhost" (.getLocalPort server))]
  (check-eq "hostname connect" (.isConnected client) true)
  (.close client) (.close server))

;; binary-safe bytes above 127
(with-pair
  (fn [server client conn]
    (let [data (byte-array [(unchecked-byte 0) (unchecked-byte 127)
                            (unchecked-byte 128) (unchecked-byte 200)
                            (unchecked-byte 255)])]
      (.write (.getOutputStream client) data 0 5)
      (let [buf (byte-array 8)
            n   (.read (.getInputStream conn) buf 0 8)]
        (check-eq "binary bytes" [n (mapv #(bit-and % 0xff) (take n buf))]
                  [5 [0 127 128 200 255]])))))

;; single-byte write/read arities; zero-length read answers 0 like Java
(with-pair
  (fn [server client conn]
    (.write (.getOutputStream client) 65)
    (check-eq "single byte" (.read (.getInputStream conn)) 65)
    (check-eq "zero-length read" (.read (.getInputStream client) (byte-array 0)) 0)))

;; OutputStream.write(byte[]) — the abstract class's convenience overload, and
;; the form library code reaches for. It shares an arity with write(int), so the
;; argument is what tells them apart; without that a byte array landed on the
;; single-byte arm and reported "class [B cannot be cast to class
;; java.lang.Number", naming neither the socket nor the overload (jolt#954).
(with-pair
  (fn [server client conn]
    (.write (.getOutputStream client) (.getBytes "hi" "UTF-8"))
    (let [buf (byte-array 8)
          n   (.read (.getInputStream conn) buf 0 8)]
      (check-eq "write(byte[]) writes the whole array" (String. buf 0 n "UTF-8") "hi"))))

;; …and it is binary-safe and empty-safe, like the 3-arg form beside it
(with-pair
  (fn [server client conn]
    (let [out (.getOutputStream client)]
      (.write out (byte-array 0))                    ; a no-op, not a hang
      (.write out (byte-array [(unchecked-byte 0) (unchecked-byte 255)])))
    (let [buf (byte-array 4)
          n   (.read (.getInputStream conn) buf 0 4)]
      (check-eq "write(byte[]) is binary-safe"
                [n (mapv #(bit-and % 0xff) (take n buf))] [2 [0 255]]))))

;; read into an offset
(with-pair
  (fn [server client conn]
    (let [msg (.getBytes "ab" "UTF-8")]
      (.write (.getOutputStream client) msg 0 2))
    (let [buf (byte-array [(byte 45) (byte 45) (byte 45) (byte 45)])
          n   (.read (.getInputStream conn) buf 1 2)]
      (check-eq "offset read" [n (String. buf 0 4 "UTF-8")] [2 "-ab-"]))))

;; EOF after peer close
(with-pair
  (fn [server client conn]
    (.close client)
    (check-eq "eof read" (.read (.getInputStream conn)) -1)))

;; refused connect throws (bind an ephemeral port, close it, dial it)
(let [server (java.net.ServerSocket. 0)
      port   (.getLocalPort server)]
  (.close server)
  (check-eq "refused connect throws"
            (try (java.net.Socket. "127.0.0.1" port) "no-throw"
                 (catch java.io.IOException e "threw"))
            "threw"))

;; bind conflict throws
(let [server (java.net.ServerSocket. 0)]
  (check-eq "bind conflict throws"
            (try (java.net.ServerSocket. (.getLocalPort server)) "no-throw"
                 (catch java.io.IOException e "threw"))
            "threw")
  (.close server))

;; -- the unbound ServerSocket and .bind --------------------------------------
;; (ServerSocket.) makes an UNBOUND socket, as Java's does. It used to bind an
;; ephemeral wildcard port in the constructor, so it answered isBound true and a
;; real getLocalPort where the JVM answers false and -1, and .bind did not exist
;; to bind it afterwards. Every expectation below was read off JVM Clojure 1.12,
;; error classes and messages included. Ports stay kernel-assigned (0).
(let [s (java.net.ServerSocket.)]
  (check-eq "a fresh no-arg ServerSocket is not bound" (.isBound s) false)
  (check-eq "an unbound socket has no local port" (.getLocalPort s) -1)
  (check-eq "an unbound socket says so" (str s) "ServerSocket[unbound]")
  (check-eq "accept on an unbound socket throws rather than blocking"
            (try (.accept s) "no-throw"
                 (catch java.net.SocketException e (.getMessage e)))
            "Socket is not bound yet")
  (.close s))

(let [s (java.net.ServerSocket.)]
  (.bind s (java.net.InetSocketAddress. "127.0.0.1" 0))
  (check-eq "bind makes it bound" (.isBound s) true)
  (check-eq "bind assigns a real port" (pos? (.getLocalPort s)) true)
  (check-eq "re-binding a bound socket throws"
            (try (.bind s (java.net.InetSocketAddress. "127.0.0.1" 0)) "no-throw"
                 (catch java.net.SocketException e (.getMessage e)))
            "Already bound")
  (.close s)
  ;; Java's isBound asks "was it ever bound", so close does not clear it, and
  ;; the port it was bound to is still readable.
  (check-eq "isBound survives close" (.isBound s) true)
  (check-eq "the port survives close" (pos? (.getLocalPort s)) true))

;; the two-argument overload takes the backlog Java's does
(let [s (java.net.ServerSocket.)]
  (.bind s (java.net.InetSocketAddress. "127.0.0.1" 0) 10)
  (check-eq "the 2-arg bind binds too" (pos? (.getLocalPort s)) true)
  (.close s))

(let [s (java.net.ServerSocket.)]
  (.close s)
  (check-eq "bind after close throws"
            (try (.bind s (java.net.InetSocketAddress. "127.0.0.1" 0)) "no-throw"
                 (catch java.net.SocketException e (.getMessage e)))
            "Socket is closed"))

;; a bound-by-.bind socket is a working server, not just a bound fd
(let [srv (java.net.ServerSocket.)]
  (.bind srv (java.net.InetSocketAddress. "127.0.0.1" 0))
  (let [client (java.net.Socket. "127.0.0.1" (.getLocalPort srv))
        conn   (.accept srv)]
    (check-eq "a socket bound by .bind accepts connections"
              (some? conn) true)
    (.close conn) (.close client))
  (.close srv))

;; what #1093 was actually doing: probing whether a port is free. The held port
;; must refuse and a free one must take it — the failing form reported every
;; port unavailable.
(let [held (java.net.ServerSocket.)]
  (.bind held (java.net.InetSocketAddress. "127.0.0.1" 0))
  (let [taken (.getLocalPort held)]
    (check-eq "binding a held port is refused"
              (let [s (java.net.ServerSocket.)]
                (try (do (.bind s (java.net.InetSocketAddress. "127.0.0.1" taken)) :bound)
                     (catch java.io.IOException _ :refused)
                     (finally (.close s))))
              :refused))
  (.close held))
(check-eq "binding a free port succeeds"
          (let [s (java.net.ServerSocket.)]
            (try (do (.bind s (java.net.InetSocketAddress. "127.0.0.1" 0)) :bound)
                 (catch java.io.IOException _ :refused)
                 (finally (.close s))))
          :bound)

;; write to a peer-closed socket throws instead of silently dropping — and the
;; process must survive it (SIGPIPE guarded via MSG_NOSIGNAL / SO_NOSIGPIPE).
(let [server (java.net.ServerSocket. 0)
      client (java.net.Socket. "127.0.0.1" (.getLocalPort server))
      conn   (.accept server)
      out    (.getOutputStream client)
      msg    (.getBytes "x" "UTF-8")]
  (.close conn)
  (Thread/sleep 100)
  ;; the first write may itself draw the RST (timing differs by platform), so
  ;; both live inside the try: what's asserted is that SOME write throws.
  (check-eq "broken pipe throws"
            (try (.write out msg 0 1)
                 (Thread/sleep 100)
                 (.write out msg 0 1)
                 "no-throw"
                 (catch java.io.IOException e "threw"))
            "threw")
  (.close client) (.close server))

;; port 0 reports the kernel-assigned port; connected sockets know both ends
(with-pair
  (fn [server client conn]
    (check-eq "server ephemeral port" (pos? (.getLocalPort server)) true)
    (check-eq "client local port" (pos? (.getLocalPort client)) true)
    (check-eq "client remote port" (.getPort client) (.getLocalPort server))
    (check-eq "accepted peer port" (.getPort conn) (.getLocalPort client))
    (check-eq "accepted peer addr" (.getHostAddress (.getInetAddress conn)) "127.0.0.1")))

;; class model: class / instance? / str-through-toString
(with-pair
  (fn [server client conn]
    (check-eq "class Socket" (.getName (class client)) "java.net.Socket")
    (check-eq "class ServerSocket" (.getName (class server)) "java.net.ServerSocket")
    (check-eq "instance? Socket" (instance? java.net.Socket client) true)
    (check-eq "instance? cross-class" (instance? java.net.ServerSocket client) false)
    (check-eq "instance? InputStream" (instance? java.io.InputStream (.getInputStream client)) true)
    (check-eq "str routes toString" (str/starts-with? (str client) "Socket[addr=") true)
    (check-eq "unconnected toString" (str (java.net.Socket.)) "Socket[unconnected]")))

;; InetAddress / InetSocketAddress
(check-eq "getByName localhost" (.getHostAddress (java.net.InetAddress/getByName "localhost")) "127.0.0.1")
(check-eq "getByName class" (.getName (class (java.net.InetAddress/getByName "localhost"))) "java.net.Inet4Address")
(let [isa (java.net.InetSocketAddress. "127.0.0.1" 8080)]
  (check-eq "isa port" (.getPort isa) 8080)
  ;; getHostString, not getHostName: the JVM reverse-resolves a literal to
  ;; "localhost" (nameservice-dependent); getHostString answers the literal
  ;; on both. jolt's getHostName skips the reverse lookup — known divergence.
  (check-eq "isa host" (.getHostString isa) "127.0.0.1")
  (check-eq "isa getAddress" (.getHostAddress (.getAddress isa)) "127.0.0.1"))

;; no-arg Socket + .connect(endpoint)
(let [server (java.net.ServerSocket. 0)
      client (java.net.Socket.)]
  (.connect client (java.net.InetSocketAddress. "127.0.0.1" (.getLocalPort server)))
  (check-eq "connect endpoint" (.isConnected client) true)
  (.close client) (.close server))

;; ServerSocket(port, backlog, bindAddr) restricts the bind
(let [lb (java.net.ServerSocket. 0 5 (java.net.InetAddress/getByName "127.0.0.1"))]
  (check-eq "bindAddr honored" (str/includes? (str lb) "addr=127.0.0.1") true)
  (.close lb))

;; closing a stream closes the socket, like Java
(with-pair
  (fn [server client conn]
    (.close (.getInputStream conn))
    (check-eq "stream close closes socket" (.isClosed conn) true)))

;; a closed socket's streams raise instead of touching the fd: the number is
;; free once closed, and the next socket to open gets it. Without the guard A's
;; read takes B's first byte and A's write reaches B's peer (jolt#1183). The JVM
;; prints SocketException "Socket closed" for every call below.
(let [server (java.net.ServerSocket. 0)
      port   (.getLocalPort server)
      a      (java.net.Socket. "127.0.0.1" port)
      a-peer (.accept server)
      a-in   (.getInputStream a)
      a-out  (.getOutputStream a)
      _      (.close a)
      b      (java.net.Socket. "127.0.0.1" port)
      b-peer (.accept server)
      raised (fn [f] (try (f) :no-throw
                          (catch java.net.SocketException e [:socket-exception (ex-message e)])))]
  (try
    (let [msg (.getBytes "hello-B" "UTF-8")]
      (.write (.getOutputStream b-peer) msg 0 (alength msg)))
    (check-eq "read() on a closed socket" (raised #(.read a-in)) [:socket-exception "Socket closed"])
    (check-eq "read(b) on a closed socket" (raised #(.read a-in (byte-array 4)))
              [:socket-exception "Socket closed"])
    (check-eq "read(b off len) on a closed socket" (raised #(.read a-in (byte-array 4) 0 4))
              [:socket-exception "Socket closed"])
    (check-eq "write(int) on a closed socket" (raised #(.write a-out 65))
              [:socket-exception "Socket closed"])
    (check-eq "write(b) on a closed socket" (raised #(.write a-out (.getBytes "from-A")))
              [:socket-exception "Socket closed"])
    (check-eq "write(b off len) on a closed socket" (raised #(.write a-out (.getBytes "from-A") 0 6))
              [:socket-exception "Socket closed"])
    ;; zero-length calls never reach the fd, and the JVM answers them closed
    (check-eq "zero-length calls on a closed socket"
              [(.read a-in (byte-array 0)) (.read a-in (byte-array 4) 0 0)
               (.write a-out (byte-array 0)) (.write a-out (byte-array 4) 0 0)]
              [0 0 nil nil])
    (let [buf (byte-array 64) n (.read (.getInputStream b) buf 0 64)]
      (check-eq "the next socket keeps its own bytes" (String. buf 0 n "UTF-8") "hello-B"))
    (check-eq "the next socket's peer got nothing from the closed one"
              (.available (.getInputStream b-peer)) 0)
    (finally (.close b-peer) (.close b) (.close a-peer) (.close server))))

;; the rest of a closed socket's surface answers from the object, never the fd
;; (which may be another socket's by now), and raises what the JVM raises.
(let [server (java.net.ServerSocket. 0)
      port   (.getLocalPort server)
      a      (java.net.Socket. "127.0.0.1" port)
      a-peer (.accept server)
      u      (java.net.Socket.)
      raised (fn [f] (try (f) :no-throw
                          (catch java.net.SocketException e [:socket-exception (ex-message e)])))]
  (check-eq "an unbound socket's local port is -1" (.getLocalPort u) -1)
  (.close a) (.close u)
  (check-eq "getInputStream on a closed socket" (raised #(.getInputStream a))
            [:socket-exception "Socket is closed"])
  (check-eq "getOutputStream on a closed socket" (raised #(.getOutputStream a))
            [:socket-exception "Socket is closed"])
  (check-eq "a closed unbound socket's local port is -1" (.getLocalPort u) -1)
  (check-eq "connect on a closed socket"
            (raised #(.connect u (java.net.InetSocketAddress. "127.0.0.1" port)))
            [:socket-exception "Socket is closed"])
  (.close a-peer) (.close server)
  (check-eq "accept on a closed server socket" (raised #(.accept server))
            [:socket-exception "Socket is closed"]))

;; Closing a socket is how another thread stops a blocked read or accept, and the
;; blocked call raises. It used to wait on in a private kqueue/epoll that close
;; never signalled, so it hung for good. The JVM prints
;; [SocketException "Socket closed"] for each of these; a write stuck on a full
;; send buffer answers "Broken pipe" there instead.
(defn blocked-then-closed [call target]
  (let [p (promise)
        _ (future (deliver p (try (call) :no-throw
                                  (catch java.net.SocketException e
                                    [:socket-exception (ex-message e)]))))]
    (Thread/sleep 200)
    (.close target)
    (deref p 5000 :hung)))

(with-pair
  (fn [server client conn]
    (let [in (.getInputStream conn)]
      (check-eq "close wakes a thread blocked in read"
                (blocked-then-closed #(.read in) conn)
                [:socket-exception "Socket closed"]))))

(let [server (java.net.ServerSocket. 0)]
  (check-eq "close wakes a thread blocked in accept"
            (blocked-then-closed #(.accept server) server)
            [:socket-exception "Socket closed"]))

(with-pair
  (fn [server client conn]
    ;; The peer never reads, so the send buffer fills and a write blocks. A slow
    ;; machine can still be copying a chunk when close lands, and the next write
    ;; then raises "Socket closed", which is also what the JVM does there; what
    ;; matters is that the writer wakes and raises.
    (let [out (.getOutputStream client)
          chunk (byte-array (* 64 1024))
          r (blocked-then-closed #(loop [] (.write out chunk) (recur)) client)]
      (check-eq "close wakes a thread blocked in write"
                (if (contains? #{[:socket-exception "Broken pipe"]
                                 [:socket-exception "Socket closed"]} r)
                  :raised
                  r)
                :raised))))

;; The same on a fiber, where the woken read used to retry recv on the fd number
;; close had freed: B, opened right after, is handed that number, and A's read
;; took B's bytes. A's fd stays reserved until its read has left.
(require '[jolt.fibers :as fib])
(let [server (java.net.ServerSocket. 0)
      port   (.getLocalPort server)
      a      (java.net.Socket. "127.0.0.1" port)
      a-peer (.accept server)
      a-in   (.getInputStream a)
      p      (promise)
      _      (fib/spawn (fn [] (deliver p (try (.read a-in) :no-throw
                                               (catch java.net.SocketException e
                                                 [:socket-exception (ex-message e)])))))
      _      (Thread/sleep 200)
      _      (.close a)
      b      (java.net.Socket. "127.0.0.1" port)
      b-peer (.accept server)]
  (try
    (.write (.getOutputStream b-peer) (.getBytes "B" "UTF-8") 0 1)
    (check-eq "close wakes a fiber blocked in read" (deref p 5000 :hung)
              [:socket-exception "Socket closed"])
    (check-eq "the woken fiber left the next socket's bytes alone"
              (.read (.getInputStream b)) (int \B))
    (finally (.close b-peer) (.close b) (.close a-peer) (.close server))))

;; Half-close (jolt-lang/jolt#1208): shutdownOutput sends FIN and keeps the read
;; direction, shutdownInput reads EOF and keeps the write direction, and the two
;; is*Shutdown predicates report it. Every expected value below is what JDK 21
;; answers for the same forms over loopback TCP (certify.clj over these forms as
;; corpus rows: 6/6 certified). They cannot live in the corpus itself, whose
;; runner has no jolt.socket to install.
(defn- sock-msg [f]
  (try (f) :ok (catch java.net.SocketException e (.getMessage e))))

(with-pair
  (fn [server c s]
    (.write (.getOutputStream c) 120)
    (let [before (.isOutputShutdown c)
          _ (.shutdownOutput c)
          si (.getInputStream s)]
      (.write (.getOutputStream s) 122)
      (check-eq "shutdownOutput sends the peer EOF and leaves this side reading"
                [before (.isOutputShutdown c) (.isInputShutdown c)
                 (.read si) (.read si) (.read si)
                 (.read (.getInputStream c)) (.isClosed c) (.isConnected c)]
                [false true false 120 -1 -1 122 false true]))))

(with-pair
  (fn [server c s]
    (let [o (.getOutputStream c)]
      (.shutdownOutput c)
      (check-eq "after shutdownOutput a write throws and the state is named"
                [(sock-msg #(.write o 1)) (sock-msg #(.write o (byte-array [1 2])))
                 (sock-msg #(.write o (byte-array 0))) (sock-msg #(.flush o))
                 (sock-msg #(.shutdownOutput c)) (sock-msg #(.getOutputStream c))
                 (sock-msg #(.getInputStream c))]
                ["Broken pipe" "Broken pipe" :ok :ok "Socket output is already shutdown"
                 "Socket output is shutdown" :ok]))))

(with-pair
  (fn [server c s]
    (.write (.getOutputStream s) 113)
    (Thread/sleep 100)
    (let [i (.getInputStream c)]
      (.shutdownInput c)
      (check-eq "shutdownInput reads EOF over pending data and leaves this side writing"
                [(.isInputShutdown c) (.isOutputShutdown c)
                 (.read i) (.read i (byte-array 4)) (.read i (byte-array 4) 0 4)
                 (.read i (byte-array 0)) (.available i)
                 (.readLine (java.io.BufferedReader. (java.io.InputStreamReader. i)))
                 (sock-msg #(.getInputStream c)) (sock-msg #(.shutdownInput c))
                 (do (.write (.getOutputStream c) 119) (.read (.getInputStream s)))]
                [true false -1 -1 -1 0 0 nil "Socket input is shutdown"
                 "Socket input is already shutdown" 119]))))

(let [u (java.net.Socket.)]
  (check-eq "a half-close needs a connected, open socket"
            [(sock-msg #(.shutdownOutput u)) (sock-msg #(.shutdownInput u))
             (.isOutputShutdown u) (.isInputShutdown u)
             (sock-msg #(.getInputStream u)) (sock-msg #(.getOutputStream u))
             (do (.close u) (sock-msg #(.shutdownOutput u))) (sock-msg #(.getInputStream u))]
            ["Socket is not connected" "Socket is not connected" false false
             "Socket is not connected" "Socket is not connected"
             "Socket is closed" "Socket is closed"]))

(with-pair
  (fn [server c s]
    (.shutdownOutput c)
    (.close c)
    (check-eq "the half-closed state outlives close, which then refuses a shutdown"
              [(.isOutputShutdown c) (.isInputShutdown c) (sock-msg #(.shutdownOutput c))
               (sock-msg #(.shutdownInput c)) (sock-msg #(.getInputStream c))]
              [true false "Socket is closed" "Socket is closed" "Socket is closed"])))

(with-pair
  (fn [server c s]
    (let [f (future (.read (.getInputStream c)))]
      (Thread/sleep 200)
      (.shutdownInput c)
      (check-eq "shutdownInput wakes a thread blocked in read with EOF"
                (deref f 5000 :blocked) -1))))

;; On a fiber the read is parked on the poller rather than blocked in recv, and
;; the shutdown has to reach it the same way.
(with-pair
  (fn [server c s]
    (let [p (promise)
          in (.getInputStream c)]
      (fib/spawn (fn [] (deliver p (try (.read in) (catch Throwable e [:threw (str e)])))))
      (Thread/sleep 200)
      (.shutdownInput c)
      (check-eq "shutdownInput wakes a fiber blocked in read with EOF"
                (deref p 5000 :blocked) -1))))

;; The peer of a half-closed socket sees a whole conversation: request, FIN,
;; then the response and the close — what a proxy pumping one direction does.
(with-pair
  (fn [server c s]
    (let [co (.getOutputStream c)]
      (.write co (.getBytes "request" "UTF-8"))
      (.shutdownOutput c)
      ;; not slurp: it closes the stream, and closing a socket's stream closes
      ;; the socket, on the JVM as here
      (let [in (.getInputStream s)
            req (loop [acc []]
                  (let [b (.read in)]
                    (if (neg? b) (String. (byte-array acc) "UTF-8") (recur (conj acc b)))))]
        (.write (.getOutputStream s) (.getBytes (str "echo:" req) "UTF-8"))
        (.close s)
        (check-eq "a request half-closed by the client reads to EOF, and the reply arrives"
                  (slurp (.getInputStream c)) "echo:request")))))

;; A socket's streams are java.io streams to clojure.java.io: io/reader,
;; io/writer, io/input-stream, io/output-stream and io/copy all raised "Cannot
;; open" over them, so the ordinary (io/reader (.getInputStream sock)) did not
;; work. Measured against JDK 21 (the flush is the JVM's: io/output-stream is a
;; BufferedOutputStream there).
(with-pair
  (fn [server c s]
    (io/copy "abc\n" (.getOutputStream c))
    (let [w (io/writer (.getOutputStream c))] (.write w "de\n") (.flush w))
    (let [o (io/output-stream (.getOutputStream c))]
      (io/copy (.getBytes "x\ny\n" "UTF-8") o)
      (.flush o))
    (.shutdownOutput c)
    (check-eq "clojure.java.io reads and writes a socket's streams"
              [(vec (line-seq (io/reader (io/input-stream (.getInputStream s))))) (.isClosed c)]
              [["abc" "de" "x" "y"] false])))

;; available() is a real byte count, from the same ioctl(FIONREAD) the JVM asks.
;; It answered 0 always, which java.io permits ("an estimate") but which leaves
;; (pos? (.available in)) false forever. ioctl is variadic, and binding it
;; fixed-arity is what made it look unreachable: on Apple arm64 the call returns
;; SUCCESS with the out-parameter untouched. jolt.ffi's :varargs marker puts the
;; argument where the callee reads it. The JVM prints [0 14 9 0] for this.
(with-pair
  (fn [server client conn]
    (let [in (.getInputStream conn)
          msg (.getBytes "hello over tcp" "UTF-8")]
      (check-eq "available before anything is sent" (.available in) 0)
      (.write (.getOutputStream client) msg 0 (alength msg))
      ;; loopback delivery is not instant; wait for it rather than assume it
      (loop [tries 0]
        (when (and (zero? (.available in)) (< tries 100))
          (Thread/sleep 10)
          (recur (inc tries))))
      (check-eq "available counts what arrived" (.available in) 14)
      (.read in (byte-array 5) 0 5)
      (check-eq "available drops by what was read" (.available in) 9)
      (.read in (byte-array 64) 0 64)
      (check-eq "available is 0 once drained" (.available in) 0))))

;; and it is not bounded by any buffer of jolt's — the kernel's whole count,
;; which is what the JVM answers here too
(with-pair
  (fn [server client conn]
    (let [in (.getInputStream conn)]
      (.write (.getOutputStream client) (byte-array 20000) 0 20000)
      (loop [tries 0]
        (when (and (< (.available in) 20000) (< tries 100))
          (Thread/sleep 10)
          (recur (inc tries))))
      (check-eq "available counts past any buffer" (.available in) 20000))))

;; a peer that closed leaves its bytes readable, and the count with them
(let [server (java.net.ServerSocket. 0)
      client (java.net.Socket. "127.0.0.1" (.getLocalPort server))
      conn   (.accept server)
      in     (.getInputStream conn)]
  (.write (.getOutputStream client) (.getBytes "tail" "UTF-8") 0 4)
  (.close client)
  (loop [tries 0]
    (when (and (zero? (.available in)) (< tries 100))
      (Thread/sleep 10)
      (recur (inc tries))))
  (check-eq "available after the peer closed" (.available in) 4)
  (.read in (byte-array 8) 0 8)
  (check-eq "available at end of stream" (.available in) 0)
  (.close conn) (.close server))

;; and a CLOSED socket raises SocketException, as Java's does. Asking the kernel
;; about a closed fd would be worse than wrong: the number is free to have been
;; reused by the next socket, so the count would be somebody else's.
(with-pair
  (fn [server client conn]
    (let [in (.getInputStream conn)]
      (.close conn)
      (check-eq "available on a closed socket"
                (try (.available in)
                     (catch java.io.IOException e [(class e) (.getMessage e)]))
                [java.net.SocketException "Socket closed"]))))


;; -- SO_TIMEOUT and the timed connect (jolt-lang/jolt#1191, #1192) -------------
;; Every expectation here was read off JDK 20, messages included. A timed-out
;; read or accept raises SocketTimeoutException and leaves the socket open and
;; usable; a timed-out or refused connect closes it.
(defn thrown [f]
  (try (f) :no-throw
       (catch Exception e [(.getSimpleName (class e)) (ex-message e)])))

(defn elapsed-ms [f]
  (let [t0 (System/currentTimeMillis)]
    [(f) (- (System/currentTimeMillis) t0)]))

(with-pair
  (fn [server client conn]
    (check-eq "getSoTimeout defaults to 0" (.getSoTimeout client) 0)
    (.setSoTimeout client 300)
    (check-eq "getSoTimeout round-trips" (.getSoTimeout client) 300)
    (check-eq "a negative SO_TIMEOUT is refused"
              (thrown #(.setSoTimeout client -1))
              ["IllegalArgumentException" "timeout can't be negative"])
    (check-eq "an accepted socket does not inherit the listener's timeout"
              (.getSoTimeout conn) 0)
    (let [in (.getInputStream client)
          [r ms] (elapsed-ms #(thrown (fn [] (.read in))))]
      (check-eq "a read with nothing to read times out" r
                ["SocketTimeoutException" "Read timed out"])
      (check-eq "…after about the timeout" (<= 250 ms 2000) true)
      (check-eq "…and is an InterruptedIOException"
                (try (.read in) (catch java.io.InterruptedIOException _ :caught))
                :caught)
      (check-eq "…and leaves the socket open" (.isClosed client) false)
      (.write (.getOutputStream conn) (.getBytes "ok" "UTF-8") 0 2)
      (let [buf (byte-array 8)
            n (.read in buf 0 8)]
        (check-eq "the next read after a timeout gets the data" (String. buf 0 n "UTF-8") "ok"))
      ;; bytes already there are returned, whatever the timeout
      (.write (.getOutputStream conn) 65)
      (check-eq "a read with data waiting returns it" (.read in) 65)
      (check-eq "the timed-out read is not EOF"
                (thrown #(.read in (byte-array 4)))
                ["SocketTimeoutException" "Read timed out"])
      ;; 0 is infinite again
      (.setSoTimeout client 0)
      (future (Thread/sleep 400) (.write (.getOutputStream conn) 66))
      (check-eq "SO_TIMEOUT 0 blocks until data" (.read in) 66))
    (.close client)
    (check-eq "setSoTimeout on a closed socket"
              (thrown #(.setSoTimeout client 5)) ["SocketException" "Socket is closed"])
    (check-eq "getSoTimeout on a closed socket"
              (thrown #(.getSoTimeout client)) ["SocketException" "Socket is closed"])))

(let [server (java.net.ServerSocket. 0)]
  (check-eq "ServerSocket getSoTimeout defaults to 0" (.getSoTimeout server) 0)
  (.setSoTimeout server 200)
  (check-eq "ServerSocket getSoTimeout round-trips" (.getSoTimeout server) 200)
  (check-eq "ServerSocket refuses a negative timeout"
            (thrown #(.setSoTimeout server -1)) ["IllegalArgumentException" "timeout < 0"])
  (let [[r ms] (elapsed-ms #(thrown (fn [] (.accept server))))]
    (check-eq "accept with nobody dialing times out" r
              ["SocketTimeoutException" "Accept timed out"])
    (check-eq "…after about the timeout" (<= 150 ms 2000) true))
  (let [c (java.net.Socket. "127.0.0.1" (.getLocalPort server))
        a (.accept server)]
    (check-eq "the listener still accepts after a timeout" (.isConnected a) true)
    (.close a) (.close c))
  (.close server)
  (check-eq "ServerSocket getSoTimeout on a closed socket"
            (thrown #(.getSoTimeout server)) ["SocketException" "Socket is closed"]))

;; The same on a fiber: the timeout wakes the parked fiber with the exception, not
;; EOF and not a hang, and close still wins over a timeout that has not expired.
(with-pair
  (fn [server client conn]
    (.setSoTimeout client 200)
    (let [p (promise)]
      (fib/spawn (fn [] (deliver p (thrown #(.read (.getInputStream client))))))
      (check-eq "a fiber's read times out" (deref p 5000 :hung)
                ["SocketTimeoutException" "Read timed out"]))
    (let [p (promise)]
      (fib/spawn (fn [] (deliver p (thrown #(.read (.getInputStream client))))))
      (Thread/sleep 50)
      (.write (.getOutputStream conn) 67)
      (check-eq "a fiber's timed read still gets data that arrives in time"
                (deref p 5000 :hung) :no-throw))
    (.setSoTimeout client 5000)
    (let [p (promise)]
      (fib/spawn (fn [] (deliver p (thrown #(.read (.getInputStream client))))))
      (Thread/sleep 200)
      (.close client)
      (check-eq "close wakes a fiber in a timed read" (deref p 3000 :hung)
                ["SocketException" "Socket closed"]))))

(let [server (java.net.ServerSocket. 0)
      p (promise)]
  (.setSoTimeout server 200)
  (fib/spawn (fn [] (deliver p (thrown #(.accept server)))))
  (check-eq "a fiber's accept times out" (deref p 5000 :hung)
            ["SocketTimeoutException" "Accept timed out"])
  (.close server))

;; connect(endpoint, timeout). A listener that never accepts, with a backlog of
;; one, stops completing handshakes once the queue is full, so a connect to it
;; hangs until its timeout — on the JVM as here. macOS stalls the second dial,
;; Linux the third; the loop takes whichever.
(defn dial-until-stalled [port ms]
  (loop [held [] i 0]
    (let [s (java.net.Socket.)
          [r el] (elapsed-ms #(thrown (fn [] (.connect s (java.net.InetSocketAddress. "127.0.0.1" port) ms))))]
      (if (and (= r :no-throw) (< i 16))
        (recur (conj held s) (inc i))
        {:held held :result r :ms el :closed? (.isClosed s)}))))

(let [server (java.net.ServerSocket. 0 1)
      {:keys [held result ms closed?]} (dial-until-stalled (.getLocalPort server) 300)]
  (check-eq "a connect that cannot complete times out" result
            ["SocketTimeoutException" "Connect timed out"])
  (check-eq "…after about the timeout" (<= 250 ms 2000) true)
  (check-eq "…and closes the socket" closed? true)
  (let [p (promise) port (.getLocalPort server)]
    (fib/spawn (fn [] (deliver p (thrown #(.connect (java.net.Socket.)
                                                    (java.net.InetSocketAddress. "127.0.0.1" port) 200)))))
    (check-eq "a fiber's connect times out" (deref p 5000 :hung)
              ["SocketTimeoutException" "Connect timed out"]))
  (let [s (java.net.Socket.) p (promise) port (.getLocalPort server)]
    (future (deliver p (thrown #(.connect s (java.net.InetSocketAddress. "127.0.0.1" port) 5000))))
    (Thread/sleep 200)
    (.close s)
    (check-eq "close wakes a timed connect" (deref p 3000 :hung)
              ["SocketException" "Socket closed"]))
  (doseq [s held] (.close s))
  (.close server))

(let [s (java.net.Socket.)]
  (check-eq "a negative connect timeout is refused"
            (thrown #(.connect s (java.net.InetSocketAddress. "127.0.0.1" 1) -1))
            ["IllegalArgumentException" "connect: timeout can't be negative"])
  (check-eq "…and leaves the socket open" (.isClosed s) false)
  (.close s))

(let [server (java.net.ServerSocket. 0)
      port (.getLocalPort server)
      s (java.net.Socket.)]
  (.close server)
  (check-eq "a refused connect is a ConnectException"
            (thrown #(.connect s (java.net.InetSocketAddress. "127.0.0.1" port) 1000))
            ["ConnectException" "Connection refused"])
  (check-eq "…and closes the socket" (.isClosed s) true))

(let [server (java.net.ServerSocket. 0)
      s (java.net.Socket.)]
  (.connect s (java.net.InetSocketAddress. "127.0.0.1" (.getLocalPort server)) 1000)
  (check-eq "a timed connect that completes is connected" (.isConnected s) true)
  (.close s) (.close server))

;; -- host identity: InetAddress statics + NetworkInterface --------------------
;; What a program asks about the machine it is on. The loopback interface is
;; found by the address it carries, not by name — it is lo0 on macOS and lo on
;; Linux, and a gate that hardcodes either is a gate that only runs on one.

(defn- dotted-quad? [s]
  (boolean (and (string? s) (re-matches #"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}" s))))

(def local-host (java.net.InetAddress/getLocalHost))

(check-eq "getLocalHost is an InetAddress" (instance? java.net.InetAddress local-host) true)
(check-eq "getLocalHost has a dotted-quad address" (dotted-quad? (.getHostAddress local-host)) true)
(check-eq "getLocalHost names the host" (pos? (count (.getHostName local-host))) true)
;; toString is "host/address", the JVM's shape.
(check-eq "getLocalHost toString joins host and address"
          (str local-host) (str (.getHostName local-host) "/" (.getHostAddress local-host)))
(check-eq "getCanonicalHostName answers a name"
          (pos? (count (.getCanonicalHostName local-host))) true)

;; getAllByName returns an ARRAY on the JVM, so alength and aget both hold.
(def all-loopback (java.net.InetAddress/getAllByName "localhost"))
(check-eq "getAllByName returns a non-empty array" (pos? (alength all-loopback)) true)
(check-eq "getAllByName resolves localhost to the loopback address"
          (boolean (some (fn [a] (= "127.0.0.1" (.getHostAddress a))) (seq all-loopback))) true)

(def interfaces (enumeration-seq (java.net.NetworkInterface/getNetworkInterfaces)))
(check-eq "getNetworkInterfaces enumerates at least one interface" (pos? (count interfaces)) true)
(check-eq "every interface has a name"
          (every? (fn [ni] (pos? (count (.getName ni)))) interfaces) true)
(check-eq "an interface is a NetworkInterface"
          (instance? java.net.NetworkInterface (first interfaces)) true)

(def loopback-ni
  (first (filter (fn [ni]
                   (some (fn [a] (= "127.0.0.1" (.getHostAddress a)))
                         (enumeration-seq (.getInetAddresses ni))))
                 interfaces)))

(check-eq "the loopback interface is enumerated" (some? loopback-ni) true)
;; An address read off an interface carries no hostname until asked — the JVM
;; prints it as "/127.0.0.1" — and .getHostName resolves once and caches.
(check-eq "an interface address is unresolved until asked"
          (str (first (filter (fn [a] (= "127.0.0.1" (.getHostAddress a)))
                              (enumeration-seq (.getInetAddresses loopback-ni)))))
          "/127.0.0.1")
(check-eq "getHostName resolves it and caches the name"
          (let [a (first (filter (fn [x] (= "127.0.0.1" (.getHostAddress x)))
                                 (enumeration-seq (.getInetAddresses loopback-ni))))]
            (.getHostName a)
            (str a))
          "localhost/127.0.0.1")
(check-eq "getByName finds the same interface"
          (.getName (java.net.NetworkInterface/getByName (.getName loopback-ni)))
          (.getName loopback-ni))
(check-eq "getByInetAddress finds the loopback interface"
          (.getName (java.net.NetworkInterface/getByInetAddress
                      (java.net.InetAddress/getByName "127.0.0.1")))
          (.getName loopback-ni))
;; No interface carries a routable public address of someone else's.
(check-eq "getByInetAddress is nil for an address no interface holds"
          (java.net.NetworkInterface/getByInetAddress
            (java.net.InetAddress/getByName "8.8.8.8"))
          nil)
(check-eq "getByName is nil for an interface that does not exist"
          (java.net.NetworkInterface/getByName "jolt-no-such-iface0") nil)
;; The loopback has no hardware address on the JVM; a physical one is 6 bytes.
(check-eq "loopback has no hardware address" (.getHardwareAddress loopback-ni) nil)
(check-eq "a hardware address, where present, is six bytes"
          (every? (fn [ni] (let [h (.getHardwareAddress ni)]
                             (or (nil? h) (= 6 (alength h)))))
                  interfaces)
          true)
(check-eq "toString names the interface"
          (str loopback-ni)
          (str "name:" (.getName loopback-ni) " (" (.getDisplayName loopback-ni) ")"))

;; -- System/getProperties is a java.util.Properties ---------------------------
;; It answers getProperty, not just map lookup: a JVM library reads system
;; properties through the Properties API (clj-uuid's node id digests six of them).
(def sys-props (System/getProperties))
(check-eq "getProperties answers getProperty"
          (.getProperty sys-props "os.name") (System/getProperty "os.name"))
(check-eq "getProperty falls back to its default"
          (.getProperty sys-props "jolt.no.such.property" "fallback") "fallback")
(check-eq "getProperties is still map-readable"
          (get sys-props "os.name") (System/getProperty "os.name"))
(check-eq "setProperty writes through"
          (do (.setProperty sys-props "jolt.socket.test.prop" "set")
              (System/getProperty "jolt.socket.test.prop"))
          "set")
(check-eq "stringPropertyNames includes a known key"
          (contains? (set (.stringPropertyNames sys-props)) "os.name") true)
(check-eq "getProperties is a Properties"
          (instance? java.util.Properties sys-props) true)
;; count, seq and get answer over the same key set — a value visible to one of
;; them and not the others is the half-map state this shape invites.
(check-eq "count and seq agree" (count sys-props) (count (seq sys-props)))
(check-eq "every key seq reports is readable"
          (every? (fn [k] (= (get sys-props k) (.getProperty sys-props k))) (keys sys-props))
          true)
(check-eq "into {} round-trips the whole view"
          (count (into {} sys-props)) (count sys-props))
(check-eq "setProperty through the object is what System/getProperty reports"
          (do (.setProperty sys-props "jolt.socket.test.wt" "through")
              (System/getProperty "jolt.socket.test.wt"))
          "through")
;; the computed values are recomputed per call, not frozen at the first one.
(check-eq "user.dir is current, not a frozen entry"
          (.getProperty (System/getProperties) "user.dir") (System/getProperty "user.dir"))

;; A Properties built by hand carries its own defaults. The JVM is precise about
;; which operations span that chain — getProperty and the two name enumerations
;; do, the inherited Hashtable surface does not — and these pin that split.
(def defaulted (java.util.Properties. {"only-default" "from-defaults"}))
(check-eq "getProperty spans the defaults"
          (.getProperty defaulted "only-default") "from-defaults")
(check-eq "propertyNames spans the defaults"
          (vec (enumeration-seq (.propertyNames defaulted))) ["only-default"])
(check-eq "stringPropertyNames spans the defaults"
          (vec (.stringPropertyNames defaulted)) ["only-default"])
(check-eq "containsKey does NOT span the defaults"
          (.containsKey defaulted "only-default") false)
(check-eq "keySet does NOT span the defaults" (vec (.keySet defaulted)) [])
(check-eq "isEmpty does NOT span the defaults" (.isEmpty defaulted) true)
(check-eq "an own value wins over the defaults"
          (let [p (java.util.Properties. {"k" "default"})]
            (.setProperty p "k" "own")
            (.getProperty p "k"))
          "own")
;; setProperty delegates to put on the JVM, so it reports THIS object's previous
;; value — nil when the key was only ever in the defaults, not the value it is
;; now shadowing.
(check-eq "setProperty reports the own previous value, not the shadowed default"
          (.setProperty (java.util.Properties. {"k" "default"}) "k" "own") nil)
;; the chain is walked recursively: a Properties whose defaults is a Properties.
(check-eq "nested defaults are searched through"
          (.getProperty (java.util.Properties. (java.util.Properties. {"deep" "found"})) "deep")
          "found")
(check-eq "propertyNames enumerates the whole chain"
          (vec (enumeration-seq
                 (.propertyNames (java.util.Properties. (java.util.Properties. {"deep" "found"})))))
          ["deep"])
(check-eq "removing an own value uncovers the default"
          (let [p (java.util.Properties. {"k" "default"})]
            (.setProperty p "k" "own")
            (.remove p "k")
            (.getProperty p "k"))
          "default")

(if (empty? @failures)
  (println "SOCKET-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "SOCKET-TEST FAILED:" (count @failures))))
