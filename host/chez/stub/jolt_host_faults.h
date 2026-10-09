/* jolt_host_faults.h: a --library build leaves a host's own fault handling
 * alone (POSIX only; an empty include on Windows).
 *
 * Sscheme_init installs process-wide handlers for SIGSEGV, SIGBUS, SIGFPE and
 * SIGILL and treats every such fault as Scheme's. A host that handles those
 * signals itself (.NET and the JVM do, to turn a null dereference in their own
 * code into an exception) then aborts with "invalid memory reference" on an
 * ordinary fault in its own code (jolt-lang/jolt#1277).
 *
 * The library stub saves the host's handlers before Sscheme_init, puts
 * jolt_fault in front of the ones Chez installs, and gives the host's back
 * after Sscheme_deinit. jolt_fault passes a fault to the host's handler when
 * the thread is not running Scheme code, and to Chez's otherwise:
 *
 *   - a thread with no Chez thread context never entered Scheme, or left it:
 *     a host thread that called a :collect-safe export has its context
 *     destroyed on the way out;
 *   - the thread that called jolt_library_release_thread is back in host
 *     code. Chez's context for it stays, deactivated, and only Chez can see
 *     that flag, so the stub keeps its own. A fault in Scheme code while that
 *     thread is inside an export therefore goes to the host too.
 *
 * With no host handler (SIG_DFL or SIG_IGN) a fault goes to Chez as before.
 * The fix proposed for Chez itself, which checks the context's active flag
 * directly, is cisco/ChezScheme#1076. Once jolt builds against a Chez that has
 * it, this file can go.
 */
#ifndef _WIN32

#include <pthread.h>
#include <signal.h>
#include <string.h>

/* Chez's thread-context key (c/globals.h): the kernel is linked into this
   image, and get_thread_context() is pthread_getspecific of it. */
extern pthread_key_t S_tc_key;

#define JOLT_FAULT_SIGNALS 4
static const int jolt_fault_sig[JOLT_FAULT_SIGNALS] = { SIGSEGV, SIGBUS, SIGFPE, SIGILL };
static struct sigaction jolt_host_fault_act[JOLT_FAULT_SIGNALS];
static struct sigaction jolt_chez_fault_act[JOLT_FAULT_SIGNALS];
static __thread int jolt_thread_released;

static void jolt_fault(int sig, siginfo_t *si, void *ctx);

static int jolt_fault_index(int sig) {
  int i;
  for (i = 0; i < JOLT_FAULT_SIGNALS; i++) if (jolt_fault_sig[i] == sig) return i;
  return -1;
}

static int jolt_is_fault_handler(const struct sigaction *a) {
  return (a->sa_flags & SA_SIGINFO) && a->sa_sigaction == jolt_fault;
}

/* Run the handler a describes; 0 when it is SIG_DFL or SIG_IGN, or jolt_fault
   itself, so there is nothing to run. */
static int jolt_run_fault_handler(const struct sigaction *a, int sig, siginfo_t *si, void *ctx) {
  if (jolt_is_fault_handler(a)) return 0;
  if (a->sa_flags & SA_SIGINFO) {
    if (a->sa_sigaction == NULL) return 0;
    a->sa_sigaction(sig, si, ctx);
  } else {
    if (a->sa_handler == SIG_DFL || a->sa_handler == SIG_IGN) return 0;
    a->sa_handler(sig);
  }
  return 1;
}

static void jolt_fault(int sig, siginfo_t *si, void *ctx) {
  int i = jolt_fault_index(sig);
  if (i >= 0) {
    if ((jolt_thread_released || pthread_getspecific(S_tc_key) == NULL)
        && jolt_run_fault_handler(&jolt_host_fault_act[i], sig, si, ctx))
      return;
    if (jolt_run_fault_handler(&jolt_chez_fault_act[i], sig, si, ctx)) return;
  }
  /* nobody to hand it to: the default action, when the faulting instruction
     runs again */
  signal(sig, SIG_DFL);
}

/* Before Sscheme_init. */
static void jolt_save_host_faults(void) {
  int i;
  for (i = 0; i < JOLT_FAULT_SIGNALS; i++) {
    struct sigaction a;
    if (sigaction(jolt_fault_sig[i], NULL, &a) == 0 && !jolt_is_fault_handler(&a))
      jolt_host_fault_act[i] = a;
  }
}

/* After Sbuild_heap, once Chez's handlers are in. */
static void jolt_chain_faults(void) {
  int i;
  jolt_thread_released = 0;
  for (i = 0; i < JOLT_FAULT_SIGNALS; i++) {
    struct sigaction a;
    if (sigaction(jolt_fault_sig[i], NULL, &a) != 0 || jolt_is_fault_handler(&a)) continue;
    jolt_chez_fault_act[i] = a;
    a.sa_sigaction = jolt_fault;
    a.sa_flags |= SA_SIGINFO;
    sigaction(jolt_fault_sig[i], &a, NULL);
  }
}

/* jolt_library_release_thread hands the calling thread back to host code;
   jolt_library_shutdown takes it back before Sscheme_deinit runs Scheme. */
static void jolt_faults_thread_released(int released) { jolt_thread_released = released; }

/* After Sscheme_deinit: the signals are the host's again. */
static void jolt_restore_host_faults(void) {
  int i;
  for (i = 0; i < JOLT_FAULT_SIGNALS; i++)
    sigaction(jolt_fault_sig[i], &jolt_host_fault_act[i], NULL);
}

#else
static void jolt_save_host_faults(void) {}
static void jolt_chain_faults(void) {}
static void jolt_faults_thread_released(int released) { (void)released; }
static void jolt_restore_host_faults(void) {}
#endif
