;; scheme-adapter-runtime.ss — the RUNTIME half of the portable-scheme-layer
;; adapter (PSL R3, epic jolt-867l).
;;
;; host/scheme-adapter/chez.ss is the gate-time half (assert-only, zero
;; definitions). THIS file is the part that actually runs: it owns the system-
;; tier FORBIDDEN names (blocklist tier "system") and exposes them to the rest
;; of the host only through named capability entry points. A non-Chez target
;; implements (or explicitly degrades) this one small surface instead of
;; chasing call sites; the portability gate's allowlist for this file IS the
;; sanctioned inventory of direct forbidden-name use.
;;
;; Every entry point is a transparent one-liner over the native — cp0 sees
;; through it within the flat runtime compilation unit, so there is zero
;; runtime cost and behavior is identical to the direct call. Each doc line
;; states the contract a target must meet and the degradation it may take
;; (derived from what the callers actually tolerate — see .dirge/specs/
;; psl-r3-system-tier.md for the per-site tolerance table).
;;
;; Loaded FIRST in bld-runtime-manifest (before rt.ss) so the sa-* names are
;; bound before rt.ss's own top level and the java/*.ss files it loads run —
;; rt.ss:51 and process.ss:338 are MACROS that resolve sa-os-family at
;; expansion time. PSL R5+R6 pinned this order; the R3 comment claiming
;; "second, after rt.ss" is obsolete.
;; NO (import (chezscheme)) here: this file is INLINED into the flat runtime
;; (bld-runtime-manifest, and again via rt.ss's own load) — a mid-program
;; import re-exposes Chez's error/warning bindings over rt.ss's %chez-error
;; shadowing and turned compile warnings fatal in standalone `jolt build`
;; (the bare-directory smoke caught it). Runtime files never import; the
;; top level already sees (chezscheme), including under chez --script.

;; (sa-run-process cmd transcoder) -> (values stdin stdout stderr pid)
;; Spawn CMD (a shell string) with block buffering and the given transcoder
;; (#f = binary), returning the four process ports and the pid. Contract: a
;; target must provide exactly this shape. Degradation: a target without
;; subprocess support must raise 'unsupported — every caller (jolt.host/
;; sh-out, java ProcessBuilder fallback, all-env-pairs) genuinely needs the
;; subprocess, so none of them may be silently degraded.
(define (sa-run-process cmd transcoder)
  (open-process-ports cmd (buffer-mode block) transcoder))

;; (sa-gc-collect) -> void
;; A full collection hint (every generation) — what the Runtime.gc /
;; System.gc callers mean: weak references clear and guardians fire.
;; Contract: perform a full collection. Degradation: may no-op (WASM) —
;; callers already guard the call and the JVM semantic is only a hint.
(define (sa-gc-collect)
  (collect (collect-maximum-generation)))

;; (sa-gc-max-generation) -> exact integer
;; The deepest collectable generation, for callers mapping JVM generations.
;; Contract: return the maximum generation argument sa-gc-collect accepts.
;; Degradation: a single-generation (non-generational) collector returns 0.
(define (sa-gc-max-generation)
  (collect-maximum-generation))

;; (sa-bytes-allocated) -> exact integer
;; Live-heap bytes — the "used" reading under current-memory-bytes that
;; Runtime.freeMemory is built from. Contract: bytes currently allocated and
;; live. Degradation: an approximation is acceptable; callers only subtract it
;; from total to compute free memory.
(define (sa-bytes-allocated)
  (bytes-allocated))

;; (sa-total-memory-bytes) -> exact integer
;; Total process heap bytes — what the collector has reserved from the OS
;; (the JVM's totalMemory; Runtime.freeMemory is the difference against
;; sa-bytes-allocated). Contract: total heap bytes. Degradation: an
;; approximation is fine — callers only display it or subtract
;; sa-bytes-allocated from it.
(define (sa-total-memory-bytes)
  (current-memory-bytes))

;; (sa-max-memory-bytes) -> exact integer
;; Upper bound on the heap the runtime may use — the JVM's maxMemory, which
;; jolt maps to Long/MAX_VALUE when the heap is unbounded. Contract: an upper
;; bound on heap bytes. Degradation: a large constant is acceptable — the JVM
;; arm already falls back to Long.MAX_VALUE semantics.
(define (sa-max-memory-bytes)
  (maximum-memory-bytes))

;; (sa-real-time-ms) -> exact integer
;; Wall-clock milliseconds, monotonic within a process — used for elapsed
;; deltas (build profiling) and unique temp-file stamps. Contract: an
;; exact-integer ms clock usable for both. Degradation: a target may use any
;; monotonic ms clock (JVM nanoTime/1000000 is fine); a no-op is NOT — the
;; stamps must differ between runs.
(define (sa-real-time-ms)
  (real-time))

;; ---- R5: io remainder (mtime) + the last GC hook -----------------------------

;; (sa-file-mtime-ms path) -> exact integer
;; Epoch milliseconds of PATH's last modification. Contract: a per-file mtime
;; usable for newer-than comparisons (build freshness, AOT cache keys, the
;; gate-boot staleness predicate). Degradation: none — stat is universal on
;; real targets; do not fake.
(define (sa-file-mtime-ms path)
  (let ((t (file-modification-time path)))
    (+ (* (time-second t) 1000) (div (time-nanosecond t) 1000000))))

;; (sa-gc-trip-bytes! n) -> void
;; Set the allocation threshold at which a trip collection triggers — the
;; dev-cache CLI's GC tuning knob (cli-devcache.ss). Contract: honor N as a
;; collection-trip hint. Degradation: may no-op — the call tunes a dev cache
;; only; collection still happens on its own schedule.
(define (sa-gc-trip-bytes! n)
  (collect-trip-bytes n))

;; ---- R6: introspection tier (capability: introspect) -------------------------

;; sa-introspect-enabled? — dynamic parameter, default #t. The degraded-
;; backtrace gate flips it to #f to prove that throw surfaces still carry
;; type+message while every introspect entry point returns empty/#f and the
;; backtrace renders without continuation frames.
(define sa-introspect-enabled? (make-parameter #t))

;; (sa-host-tag) -> string
;; The runtime's host tag (here Chez's machine type, e.g. "tarm64osx"). NAMING
;; ONLY: release/fasl directory names, image headers, telemetry strings, error
;; text. No logic may branch on it — logic branches use sa-os-family /
;; sa-arch / sa-endian. Contract: an opaque, per-build-stable host string.
;; Degradation: any identifier string the target names itself with.
(define (sa-host-tag)
  (symbol->string (machine-type)))

(define (sa-tag-contains? tag needle)
  (let ((n (string-length tag)) (m (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring tag i (+ i m)) needle) #t)
            (else (loop (+ i 1)))))))

;; (sa-os-family) -> 'macos | 'windows | 'linux
;; The OS family every host OS branch derives: SIGCHLD/SIG_BLOCK numerics
;; (process.ss, concurrency.ss), LC_TIME (tz-primitives.ss), struct-stat
;; offsets (nio-file.ss), the chmod and entropy fallbacks (io.ss, rt.ss),
;; os.name (host-static-methods.ss), link libraries (build.ss). Contract: one
;; of the three symbols. Degradation: none — the sites have no safe assumed
;; default; an unrecognized host falls back to 'linux, matching today's
;; else-branches.
(define (sa-os-family)
  (let ((m (sa-host-tag)))
    (cond ((or (sa-tag-contains? m "osx") (sa-tag-contains? m "macos")) 'macos)
          ((or (sa-tag-contains? m "nt") (sa-tag-contains? m "windows")) 'windows)
          (else 'linux))))

;; (sa-arch) -> 'x86-64 | 'arm64 | 'i386 | 'other
;; The machine architecture — the nio-file stat-layout guard keys on x86-64.
;; Contract: the architecture symbol. Degradation: 'other for an unrecognized
;; host; callers treat it as unverified.
(define (sa-arch)
  (let ((m (sa-host-tag)))
    (cond ((sa-tag-contains? m "arm64") 'arm64)
          ((sa-tag-contains? m "a6") 'x86-64)
          ((sa-tag-contains? m "i3") 'i386)
          (else 'other))))

;; (sa-endian) -> 'little | 'big | #f
;; Byte order of the host. Contract: the byte order. Degradation: #f for an
;; unrecognized suffix — the stat-layout guard treats that as unverified.
(define (sa-endian)
  (let* ((m (sa-host-tag)) (n (string-length m)))
    (if (>= n 2)
        (let ((suf (substring m (- n 2) n)))
          (cond ((string=? suf "le") 'little)
                ((string=? suf "be") 'big)
                (else #f)))
        #f)))

;; (sa-stats) -> #(cpu-nanos real-nanos gc-count gc-cpu-nanos gc-real-nanos
;;                gc-bytes)
;; One statistics snapshot as the six exact-integer fields rt.ss reads into
;; the jolt.host telemetry vars (time fields pre-converted to nanos). Contract:
;; the six fields in this order. Degradation: a zero vector — the OTel layer
;; maps zeros to absent metrics.
(define (sa-stats)
  (let ((s (statistics)))
    (vector (time->nanos (sstats-cpu s))
            (time->nanos (sstats-real s))
            (sstats-gc-count s)
            (time->nanos (sstats-gc-cpu s))
            (time->nanos (sstats-gc-real s))
            (sstats-gc-bytes s))))

;; (sa-continuation-frames k) -> list of frame inspectors | '()
;; The continuation's frames, innermost first, each an inspector object the
;; walker queries with the messages it already uses ('type 'code 'name
;; 'source-object 'link 'ref 'length). The 400-frame cap and the guard live
;; here, so a walker cannot crash the render. Contract: stepping a throw
;; continuation. Degradation: '() when sa-introspect-enabled? is #f or the
;; target has no inspector — the backtrace then renders from the compile-time
;; tables alone (jolt-backwalk) or reports no frames.
(define (sa-continuation-frames k)
  (guard (e (#t '()))
    (if (sa-introspect-enabled?)
        (let loop ((io (inspect/object k)) (n 0) (acc '()))
          (if (or (not io) (fx>=? n 400))
              (reverse acc)
              (loop (guard (e (#t #f)) (io 'link)) (fx+ n 1) (cons io acc))))
        '())))

;; (sa-procedure-info x) -> (name . ((free-name . value) ...)) | #f
;; A procedure's inspector name and live free-variable captures, in
;; registration order — what the image graph needs to serialize closures
;; (state-image.ss). Contract: name + captured values. Degradation: #f — the
;; image writer refuses the closure ('image-no), the same verdict as today's
;; no-inspector builds.
(define (sa-procedure-info x)
  (guard (e (#t #f))
    (if (sa-introspect-enabled?)
        (let* ((io (inspect/object x))
               (code (io 'code))
               (nm0 (and code (code 'name)))
               (nm (cond ((string? nm0) nm0)
                         ((symbol? nm0) (symbol->string nm0))
                         (else #f)))
               (n (io 'length)))
          (let loop ((i 0) (acc '()))
            (if (or (not n) (fx>=? i n))
                (cons nm (reverse acc))
                (let* ((vo (io 'ref i))
                       (vn0 (vo 'name))
                       (vn (if (symbol? vn0) (symbol->string vn0) vn0))
                       (v ((vo 'ref) 'value)))
                  (loop (fx+ i 1)
                        (if (string? vn) (cons (cons vn v) acc) acc))))))
        #f)))
