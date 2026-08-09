;; jolt.io-poller — one readiness poller per process (kqueue on macOS, epoll on
;; Linux) behind one internal interface, plus the fd-level syscall helpers the
;; socket layer needs (fibers R8, epic jolt-nvpr.8 — sockets + poller half).
;;
;; Why this exists: a blocking call on a fiber PINTS its carrier, and since
;; continuations cannot migrate (R0(d)), the fibers queued behind it are
;; stranded. So the socket layer sets O_NONBLOCK, and on EAGAIN asks this module
;; to wait for readiness — parking the fiber (via the jolt.host seams installed
;; in host/chez/java/fibers-async.ss) when there is a current fiber, and doing a
;; plain blocking kevent/epoll_wait on this thread when there is not. Same
;; user-facing code either way.
;;
;; The poller thread blocks in kevent/epoll_wait with the :blocking marker
;; (__collect_safe). That is measured, not theoretical: a thread inside a
;; foreign call that is not collect-safe stays ACTIVE for Chez's stop-the-world
;; collector, and a collection from another thread then fails outright with
;; "cannot collect when multiple threads are active" — a poller that is not
;; collect-safe stops the whole process from collecting for as long as it waits,
;; which is nearly always. The R8 gate asserts a full collect succeeds while the
;; poller is blocked.
;;
;; Registration races (a fiber registering while the poller is already inside
;; kevent/epoll_wait) are closed with a control pipe, the textbook shape: the
;; pipe read end is always in the poller's set, a registration writes a byte to
;; the write end, and the poller drains pending registrations into its kq/epoll
;; on every wake. Never a timed poll, never a sleep in the wait path.
;;
;; Locking: the table (fds, pending, pipe) is mutated under ONE monitor (pm).
;; The fiber's commit-to-park (jolt.host/fiber-park-commit!) runs under pm, and
;; the poller's wake collects woken fibers under pm and resumes them AFTER
;; releasing it — the R3 deliver-vs-park race, closed the same way alt-deliver!
;; closes it (both the commit and the wake's state read are serialized by the
;; caller's lock; pm is a new leaf in the lock chain: nothing the park path does
;; takes the run-queue mutex, and the wake resumes outside pm).

(ns jolt.io-poller
  (:require [jolt.ffi :as ffi]
            [clojure.string :as str]))

(ffi/load-library)

;; -- platform constants --------------------------------------------------------
;; EAGAIN/EWOULDBLOCK share one value on both platforms; O_NONBLOCK, the socket
;; error option and the connect-in-progress errno do not.
(def ^:private macos?
  (str/includes? (str/lower-case (or (System/getProperty "os.name") "")) "mac"))

(def ^:private F-GETFL 3)
(def ^:private F-SETFL 4)
(def ^:private O-NONBLOCK (if macos? 0x4 0x800))
(def ^:private EAGAIN (if macos? 35 11))
(def ^:private EINTR 4)
(def ^:private EINPROGRESS (if macos? 36 115))
(def ^:private EALREADY (if macos? 37 114))
(def ^:private SOL-SOCKET (if macos? 0xffff 1))
(def ^:private SO-ERROR (if macos? 0x1007 4))

;; -- syscalls -----------------------------------------------------------------
(ffi/defcfn c-fcntl "fcntl" [:int :int :varargs :int] :int)
;; macOS exposes the errno slot via __error, Linux via __errno_location. The
;; foreign-procedure form is created lazily on first call (emit-ffi-fn), so
;; declaring both is safe; errno picks the live one per platform.
(ffi/defcfn c-errno-loc "__errno_location" [] :pointer)
(ffi/defcfn c-error-loc "__error" [] :pointer)
(ffi/defcfn c-close "close" [:int] :int)
(ffi/defcfn c-pipe "pipe" [:pointer] :int)
(ffi/defcfn c-write "write" [:int :pointer :size_t] :ssize_t)
(ffi/defcfn c-read "read" [:int :pointer :size_t] :ssize_t)
(ffi/defcfn c-getsockopt "getsockopt" [:int :int :int :pointer :pointer] :int)
;; macOS: kqueue/kevent. kevent's timeout is a NULL-able pointer; NULL (via
;; ffi/null means wait forever. :blocking => __collect_safe.
(ffi/defcfn c-kqueue "kqueue" [] :int)
(ffi/defcfn c-kevent "kevent" [:int :pointer :int :pointer :int :pointer] :int :blocking)
;; Linux: epoll. epoll_wait's timeout is milliseconds; -1 means forever.
(ffi/defcfn c-epoll-create1 "epoll_create1" [:int] :int)
(ffi/defcfn c-epoll-ctl "epoll_ctl" [:int :int :int :pointer] :int)
(ffi/defcfn c-epoll-wait "epoll_wait" [:int :pointer :int :int] :int :blocking)

;; -- fd helpers (the socket layer's syscall surface) ---------------------------
(defn errno [] (ffi/read (if macos? (c-error-loc) (c-errno-loc)) :int 0))
(defn eagain? [] (= EAGAIN (errno)))
(defn eintr? [] (= EINTR (errno)))
(defn connect-pending? [e] (or (= EINPROGRESS e) (= EALREADY e)))
(defn nonblock! [fd]
  (let [f (c-fcntl fd F-GETFL 0)]
    (c-fcntl fd F-SETFL (bit-or f O-NONBLOCK))))
(defn so-error [fd]
  (let [v (ffi/alloc 4) lenp (ffi/alloc 4)]
    (try
      (ffi/write lenp :int 0 4)
      (if (neg? (c-getsockopt fd SOL-SOCKET SO-ERROR v lenp)) -1 (ffi/read v :int 0))
      (finally (ffi/free v) (ffi/free lenp)))))

;; -- kqueue / epoll behind one interface ---------------------------------------
(def ^:private EVFILT-READ -1)
(def ^:private EVFILT-WRITE -2)
(def ^:private EV-ADD 1)
(def ^:private EV-DELETE 2)
(def ^:private KEVENT-SIZE 32)      ; struct kevent: uptr ident @0, i16 filter @8, u16 flags @10, u32 fflags @12, iptr data @16, ptr udata @24
(def ^:private EPOLLIN 0x1)
(def ^:private EPOLLOUT 0x4)
(def ^:private EPOLL-ADD 1)
(def ^:private EPOLL-DEL 2)
(def ^:private EPOLL-EVENT-SIZE 12) ; struct epoll_event is EPOLL_PACKED in the kernel UAPI: u32 events @0, epoll_data_t (u64) @4

(defn- ev-fd [buf i]
  (if macos?
    (ffi/read buf :uptr (* i KEVENT-SIZE))
    (ffi/read buf :uint (+ (* i EPOLL-EVENT-SIZE) 4))))

(defn- kevent-put! [buf i fd filt flags]
  (let [o (* i KEVENT-SIZE)]
    (ffi/write buf :uptr o fd)
    (ffi/write buf :int (+ o 8) (bit-or (bit-and filt 0xffff) (bit-shift-left flags 16)))
    (ffi/write buf :uint (+ o 12) 0)
    (ffi/write buf :int64 (+ o 16) 0)
    (ffi/write buf :uptr (+ o 24) 0)))

(defn- ep-ctl! [ep op fd filt]
  (let [ev (ffi/alloc EPOLL-EVENT-SIZE)]
    (try
      (ffi/write ev :uint 0 (if (= filt :read) EPOLLIN EPOLLOUT))
      (ffi/write ev :uint 4 fd)            ; epoll_data_t.fd — u64 low half
      (ffi/write ev :uint 8 0)
      (c-epoll-ctl ep op fd ev)
      (finally (ffi/free ev)))))

;; -- the poller table ----------------------------------------------------------
;; One monitor serializes everything a fiber and the poller thread share:
;;   :fds      {fd {:waiters [fiber ...] :ready bool :filt :read|:write}}
;;   :pending  {fd filt}   ; registered by a fiber, not yet in the poller's set
;;   :pipe     [r w]       ; control pipe — registration wake
;;   :kq       n           ; the poller's kqueue / epoll fd
;; The pending EV_DELETE/EPOLL_CTL_DEL set is NOT here: process-events! hands it
;; straight to poller-loop, which carries it in a loop variable to the next
;; poller-round. It used to be mirrored into this atom as :to-delete, written on
;; every round and read by nobody, which made the round's critical section look
;; like it was protecting something it was not.
(def ^:private pm (Object.))
(def ^:private state (atom {:fds {} :pending {} :pipe nil :kq nil :started? false}))

;; how many times the poller entered its blocking wait — the R8 gate-3 handle
(def waits (atom 0))

(defn- pipe-read! [] (first (:pipe @state)))
(defn- pipe-write! []
  (let [w (second (:pipe @state))]
    (when w
      (let [b (ffi/alloc 1)]
        (try (ffi/write b :uint8 0 1)
             (c-write w b 1)
             (finally (ffi/free b)))))))

(defn- drain-pipe! []
  (let [r (pipe-read!) b (ffi/alloc 64)]
    (try
      (loop [] (when-not (neg? (c-read r b 64)) (recur)))
      (finally (ffi/free b)))))

;; One loop iteration of the poller thread. Under pm, drains the pending
;; registrations; builds a kevent changelist (or epoll_ctl calls) carrying those
;; ADDs and last round's DELETEs, then blocks in the ONE collect-safe wait with
;; that changelist applied atomically. Returns the fds whose events fired.
(defn- poller-round [kq to-delete]
  ;; Read AND clear :pending in ONE critical section. As two — read, then clear —
  ;; a registration landing in between was erased without ever being applied to
  ;; the kqueue/epoll set, so that fd's readiness was never reported and the fiber
  ;; waiting on it never resumed. The window is microseconds, which is why it
  ;; showed up as one fiber of eight failing to finish, once, and never again in
  ;; isolation; a stress that keeps registrations landing loses ~11% of them.
  (let [adds (locking pm
               (let [a (:pending @state)]
                 (swap! state assoc :pending {})
                 a))]
    ;; The changelist is sized to nch, not to a fixed 256. :pending holds one
    ;; entry per fd and nothing caps it, so a round that drains more than 256
    ;; registrations wrote past the end of the buffer and then told the kernel to
    ;; read that many entries — heap corruption, not a dropped registration. The
    ;; event buffer below is a different thing: 256 is the count passed to
    ;; kevent/epoll_wait as the most events to report, so it bounds itself.
    (let [nch (+ (count adds) (count to-delete))
          chbuf (when (and macos? (pos? nch)) (ffi/alloc (* nch KEVENT-SIZE)))]
      (try
        (when chbuf
          (let [i (atom 0)]
            (doseq [fd to-delete] (kevent-put! chbuf @i fd EVFILT-READ EV-DELETE) (swap! i inc))
            (doseq [[fd filt] adds]
              (kevent-put! chbuf @i fd (if (= filt :read) EVFILT-READ EVFILT-WRITE) EV-ADD)
              (swap! i inc))))
        (when (and (not macos?) (or (seq adds) (seq to-delete)))
          (doseq [fd to-delete] (c-epoll-ctl kq EPOLL-DEL fd ffi/null))
          (doseq [[fd filt] adds] (ep-ctl! kq EPOLL-ADD fd filt)))
        (swap! waits inc)
        (let [evbuf (ffi/alloc (if macos? (* 256 KEVENT-SIZE) (* 256 EPOLL-EVENT-SIZE)))]
          (try
            (let [n (if macos? (c-kevent kq (or chbuf ffi/null) nch evbuf 256 ffi/null)
                                (c-epoll-wait kq evbuf 256 -1))]
              (if (neg? n) []
                  (loop [i 0 acc []]
                    (if (< i n) (recur (inc i) (conj acc (ev-fd evbuf i))) acc))))
            (finally (ffi/free evbuf))))
        (finally (when chbuf (ffi/free chbuf)))))))

(defn- process-events! [fds]
  ;; under pm: mark each fd ready, collect + clear its waiters, schedule its
  ;; EV_DELETE; the control pipe just gets drained. Returns [woken new-deletes].
  (locking pm
    (loop [fds fds dels #{} woken []]
      (if (empty? fds)
        [woken dels]
        (let [fd (first fds)]
          (if (= fd (pipe-read!))
            (do (drain-pipe!) (recur (rest fds) dels woken))
            (let [e (get-in @state [:fds fd])]
              (if (nil? e)
                (recur (rest fds) dels woken)
                (do (swap! state assoc-in [:fds fd :ready] true)
                    (swap! state assoc-in [:fds fd :waiters] [])
                    (recur (rest fds) (conj dels fd) (into woken (:waiters e))))))))))))

(defn- poller-loop [kq]
  (loop [to-delete #{}]
    (let [fds (poller-round kq to-delete)]
      (if (seq fds)
        (let [[woken new-del] (process-events! fds)]
          (doseq [f woken] (jolt.host/fiber-resume f))
          (recur new-del))
        (recur #{})))))

(defn- ensure-started! []
  ;; under pm. One poller thread per process, started on the first fiber wait.
  (when-not (:started? @state)
    (let [pfds (ffi/alloc 8)]
      (try
        (when (neg? (c-pipe pfds))
          (throw (Exception. "jolt.io-poller: pipe() failed")))
        (let [r (ffi/read pfds :int 0) w (ffi/read pfds :int 4)]
          (nonblock! r) (nonblock! w)
          (let [kq (if macos? (c-kqueue) (c-epoll-create1 0))]
            (swap! state assoc :pipe [r w] :kq kq :started? true)
            (if macos?
              (let [ch (ffi/alloc KEVENT-SIZE)]
                (try
                  (kevent-put! ch 0 r EVFILT-READ EV-ADD)
                  (c-kevent kq ch 1 ffi/null 0 ffi/null)
                  (finally (ffi/free ch))))
              (ep-ctl! kq EPOLL-ADD r :read))
            (future (poller-loop kq))))
        (finally (ffi/free pfds))))))

;; -- the wait API --------------------------------------------------------------
;; (wait-ready fd :read|:write) -> void. Fiber-aware: parks the current fiber on
;; readiness and returns when the poller wakes it; on a plain thread, blocks in
;; a private kevent/epoll_wait (level-triggered, so a readiness that raced the
;; registration fires immediately — no missed wakeup).
(defn wait-fiber [fd filt]
  (let [park? (locking pm
                (ensure-started!)
                (let [e (get-in @state [:fds fd])]
                  (if (and e (:ready e))
                    (do (swap! state assoc-in [:fds fd :ready] false) false)
                    (do (swap! state assoc-in [:fds fd]
                               {:waiters (conj (or (:waiters e) []) (jolt.host/current-fiber))
                                :ready false :filt filt})
                        (when-not (contains? (:pending @state) fd)
                          (swap! state assoc-in [:pending fd] filt)
                          (pipe-write!))
                        (jolt.host/fiber-park-commit!)
                        true))))]
    (when park?
      (jolt.host/fiber-to-scheduler!))))

(defn wait-thread [fd filt]
  (if macos?
    (let [kq (c-kqueue) ch (ffi/alloc KEVENT-SIZE) ev (ffi/alloc KEVENT-SIZE)]
      (try
        (kevent-put! ch 0 fd (if (= filt :read) EVFILT-READ EVFILT-WRITE) EV-ADD)
        (loop []
          (when (neg? (c-kevent kq ch 1 ev 1 ffi/null)) (recur)))
        (finally (ffi/free ch) (ffi/free ev) (c-close kq))))
    (let [ep (c-epoll-create1 0) ev (ffi/alloc EPOLL-EVENT-SIZE)]
      (try
        (ffi/write ev :uint 0 (if (= filt :read) EPOLLIN EPOLLOUT))
        (ffi/write ev :uint 4 fd)
        (ffi/write ev :uint 8 0)
        (c-epoll-ctl ep EPOLL-ADD fd ev)
        (loop []
          (when (neg? (c-epoll-wait ep ev 1 -1)) (recur)))
        (finally (ffi/free ev) (c-close ep))))))

(defn wait-ready [fd filt]
  (if (jolt.host/fiber?)
    (wait-fiber fd filt)
    (wait-thread fd filt)))
