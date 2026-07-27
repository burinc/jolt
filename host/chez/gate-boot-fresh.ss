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
;; comparison is whole seconds: file-modification-time has sub-second resolution,
;; but rounding down can only make a borderline file look NEWER than the image
;; (stale, fall back), never older, so the error is on the safe side.

(define (gate-boot-image-fresh? so inputs)
  (and (file-exists? so) (file-exists? inputs)
       (let ((t (time-second (file-modification-time so))))
         (call-with-input-file inputs
           (lambda (p)
             (let loop ()
               (let ((line (get-line p)))
                 (cond ((eof-object? line) #t)
                       ((string=? line "") (loop))
                       ((not (file-exists? line)) #f)
                       ((> (time-second (file-modification-time line)) t) #f)
                       (else (loop))))))))))
