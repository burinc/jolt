;; jolt.socket gate — the java.net.Socket/ServerSocket surface over real
;; loopback TCP. Run: bin/jolt run test/chez/socket-test.clj (smoke.sh greps
;; for "SOCKET-TEST OK"). Every server binds port 0 (kernel-assigned), so
;; parallel gates never collide on a port.
(ns socket-test
  (:require [clojure.string :as str]))

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

;; available() is a real byte count. It answered 0 always, which java.io permits
;; ("an estimate") but which leaves (pos? (.available in)) false forever. The
;; JVM asks ioctl(FIONREAD); ioctl is variadic and an FFI cannot express that, so
;; this peeks with MSG_PEEK instead — same answer, consumes nothing, and never
;; waits because every fd here is O_NONBLOCK. The JVM prints [0 14 9 0] for this.
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

;; the peek window caps the answer — 4096, the same bound the byte streams over
;; Chez ports report. The JVM says 20000 here (known-divergences).
(with-pair
  (fn [server client conn]
    (let [in (.getInputStream conn)]
      (.write (.getOutputStream client) (byte-array 20000) 0 20000)
      (loop [tries 0]
        (when (and (< (.available in) 4096) (< tries 100))
          (Thread/sleep 10)
          (recur (inc tries))))
      (check-eq "available caps at the peek window" (.available in) 4096))))

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

;; and a CLOSED socket raises, as Java's SocketException does. Peeking a closed
;; fd would be worse than wrong: the number is free to be reused by the next
;; socket, so the count would be somebody else's.
(with-pair
  (fn [server client conn]
    (let [in (.getInputStream conn)]
      (.close conn)
      (check-eq "available on a closed socket"
                (try (.available in) (catch java.io.IOException e (.getMessage e)))
                "Socket closed"))))

(if (empty? @failures)
  (println "SOCKET-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "SOCKET-TEST FAILED:" (count @failures))))
