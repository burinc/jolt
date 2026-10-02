;; make fiberspoll runs its suites under JOLT_IO_POLLER=poll to exercise the
;; Windows poller on POSIX. If the selection ever stopped taking (the getenv
;; read moved, a build froze the var), those suites would quietly test
;; kqueue/epoll and stay green; this is what notices.
(require 'jolt.io-poller)
(if @#'jolt.io-poller/poll-backend?
  (println "POLL-BACKEND ACTIVE")
  (do (println "POLL-BACKEND NOT ACTIVE: JOLT_IO_POLLER=poll did not select it")
      (System/exit 1)))
