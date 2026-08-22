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
;; a Properties built by hand carries its own defaults, as the JVM's does.
(check-eq "an explicit defaults chain answers a miss"
          (.getProperty (java.util.Properties. {"fallback.key" "from-defaults"}) "fallback.key")
          "from-defaults")
(check-eq "an own value wins over the defaults"
          (let [p (java.util.Properties. {"k" "default"})]
            (.setProperty p "k" "own")
            (.getProperty p "k"))
          "own")

(if (empty? @failures)
  (println "SOCKET-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "SOCKET-TEST FAILED:" (count @failures))))
