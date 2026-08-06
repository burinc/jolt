;; gate-boot-fresh.ss — the staleness predicate for the gate boot image.
;;
;; Split out of gate-boot.ss (which loads it, then acts on it) so it can be
;; loaded and exercised on its own, without booting a runtime: this predicate
;; deciding "fresh" when it isn't would mean a gate silently testing code that is
;; no longer on disk, the one genuinely dangerous failure mode of the boot cache.
;; test/chez/gateboot-smoke.sh drives it over synthetic input lists.
;;
;; SO is fresh when it exists and is at least as new as every path listed one per
;; line in INPUTS. Anything unclear — no image, no list, a listed file that has
;; since been deleted — is NOT fresh, so the caller falls back to source. The
;; comparison is exact milliseconds (sa-file-mtime-ms): a file touched in the
;; same millisecond as the image counts as fresh; anything newer falls back to
;; source. No rounding, so a borderline file never looks older than it is — the
;; error is on the safe side (rebuild).
;; Standalone script: self-load the runtime adapter for sa-file-mtime-ms. A
;; second load by gate-boot.ss is a harmless redefinition.
(load "host/chez/scheme-adapter-runtime.ss")

(define (gate-boot-image-fresh? so inputs)
  (and (file-exists? so) (file-exists? inputs)
       (let ((t (sa-file-mtime-ms so)))
         (call-with-input-file inputs
           (lambda (p)
             (let loop ()
               (let ((line (get-line p)))
                 (cond ((eof-object? line) #t)
                       ((string=? line "") (loop))
                       ((not (file-exists? line)) #f)
                       ((> (sa-file-mtime-ms line) t) #f)
                       (else (loop))))))))))
