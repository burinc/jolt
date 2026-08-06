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
;; Loaded second in bld-runtime-manifest (right after rt.ss) so every consumer
;; — rt.ss's java loads, loader.ss, the on-demand build.ss/emit-image.ss —
;; sees it; every reference from those files is inside a lambda, resolved at
;; call time, so no consumer depends on an earlier slot.
(import (chezscheme))

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
