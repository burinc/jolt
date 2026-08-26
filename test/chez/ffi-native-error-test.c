/* Native-error capture witnesses for jolt.ffi.
 *
 * Each function writes a known value into the calling thread's native error
 * slot (POSIX errno / Windows GetLastError) and returns through the platform's
 * default C ABI, so a capture-enabled jolt.ffi binding can observe the slot
 * value Chez reads in the foreign-call return path — before collect-safe
 * reactivation or any later Scheme/native work can overwrite it.
 *
 * The slot WRITTEN is selected by the build host's C library; the jolt binding
 * selects its READ convention from the compiler target machine. On every
 * supported native target the two agree, so the Scheme gate asserts the
 * captured value equals the code the helper wrote, without branching on the
 * host. An unrecognized target fails jolt-ffi-native-error-convention-case at
 * expansion time rather than guessing a nearby ABI; that path is not
 * exercisable from a compiled helper.
 *
 * Mirrors the layout of test/chez/ffi-widths-helper.c (export macro, no tree
 * pollution, exact-width-clean). */
#ifndef _WIN32
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 199309L
#endif
#endif

#include <stdint.h>
#include <stdarg.h>

#ifdef _WIN32
#include <windows.h>
#define JOLT_NE_EXPORT   __declspec(dllexport)
#define JOLT_NE_SET(code) SetLastError((DWORD)(code))
#else
#include <errno.h>
#include <time.h>
#define JOLT_NE_EXPORT   __attribute__((visibility("default")))
#define JOLT_NE_SET(code) (errno = (int)(code))
#endif

/* Failure path: write `code` to the error slot, return a failure sentinel.
 * A capture-enabled binding observes the pair [-1, code]. */
JOLT_NE_EXPORT int jolt_ne_fail(int code) {
  JOLT_NE_SET(code);
  return -1;
}

/* Success path: clear the slot and return a recognizable positive value, so a
 * capture-enabled binding has the deterministic pair [7, 0]. */
JOLT_NE_EXPORT int jolt_ne_ok(void) {
  JOLT_NE_SET(0);
  return 7;
}

/* Overwrite the same thread's error slot with a different code, return 0.
 * Called AFTER a captured call to prove the saved vector is immutable: a later
 * native call that mutates the slot must not change the value Chez already
 * captured into the result vector. */
JOLT_NE_EXPORT int jolt_ne_clobber(int code) {
  JOLT_NE_SET(code);
  return 0;
}

/* Variadic path: return the first variadic int while publishing `code` in the
 * native error slot. The binding must preserve (__varargs_after 1) as one Chez
 * calling-convention datum while composing it with __errno/GetLastError. */
JOLT_NE_EXPORT int jolt_ne_vararg_fail(int code, ...) {
  int value;
  va_list args;
  va_start(args, code);
  value = va_arg(args, int);
  va_end(args);
  JOLT_NE_SET(code);
  return value;
}

/* Stay in native code long enough for another Chez thread to force a
 * collection, then publish a deterministic failure pair. This is the portable
 * witness that capture and __collect_safe are present on the SAME binding. */
JOLT_NE_EXPORT int jolt_ne_block_fail(uint32_t millis, int code) {
#ifdef _WIN32
  Sleep((DWORD)millis);
#else
  struct timespec delay;
  delay.tv_sec = (time_t)(millis / 1000U);
  delay.tv_nsec = (long)(millis % 1000U) * 1000000L;
  while (nanosleep(&delay, &delay) == -1 && errno == EINTR) {
    /* Resume the remaining interval after a signal. */
  }
#endif
  JOLT_NE_SET(code);
  return -1;
}
