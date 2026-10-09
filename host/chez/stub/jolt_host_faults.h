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
 * The host's handler runs the way the kernel would have run it: on the host's
 * alternate signal stack when it asked for SA_ONSTACK (jolt_fault is installed
 * with that flag then; a stack overflow can only be handled there), under its
 * sa_mask and SA_NODEFER, and only once under SA_RESETHAND. A host fault with
 * no host handler to run (SIG_DFL, SIG_IGN, or a one-shot handler already
 * used) takes the default action and kills the process, as it would have
 * without the library.
 *
 * macOS limits both: its sigaction does not report SA_RESETHAND back, so a
 * one-shot handler cannot be seen and runs every time; and Chez leaves its
 * fault handler with _longjmp, which does not clear the kernel's per-thread
 * "on the alternate stack" flag (libc's longjmp and sigreturn do, through a
 * private call), so after a fault in Scheme code taken on a thread's
 * alternate stack, that thread's signals run on its normal stack. Linux tracks
 * neither that way.
 *
 * Sscheme_init also takes SIGINT and SIGQUIT (for Chez's keyboard interrupt,
 * which in a library would leave the host's ^C pending in Scheme, and exit the
 * host from Sscheme_deinit) and ignores SIGPIPE. SIGINT and SIGQUIT go back to
 * the host right after init. SIGPIPE stays ignored while the library is
 * loaded when the host left it at SIG_DFL, since jolt's I/O expects EPIPE from
 * a write to a closed pipe or socket rather than the process dying; a host
 * that set SIGPIPE itself keeps its setting. All three are the host's again
 * after Sscheme_deinit.
 *
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
/* set when a host handler installed with SA_RESETHAND has run: the kernel
   would have reset the disposition to SIG_DFL */
static volatile sig_atomic_t jolt_host_fault_reset[JOLT_FAULT_SIGNALS];

#define JOLT_HOST_SIGNALS 3
static const int jolt_host_sig[JOLT_HOST_SIGNALS] = { SIGINT, SIGQUIT, SIGPIPE };
static struct sigaction jolt_host_sig_act[JOLT_HOST_SIGNALS];
/* The released init thread, kept as a global rather than a __thread: a
   dlopen'd library's TLS can go through __tls_get_addr, which on older glibc
   allocates on a thread's first access, and that first access would be in
   the signal handler. */
static pthread_t jolt_released_thread;
static volatile sig_atomic_t jolt_have_released;

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

/* The default action. sig stays blocked until this handler returns, so the
   raised one is delivered then, under SIG_DFL; that also covers a fault a
   host raised itself, which returning would not repeat. */
static void jolt_fault_default(int sig) {
  signal(sig, SIG_DFL);
  raise(sig);
}

/* Run the host's handler for fault signal i as the kernel would have: its
   sa_mask added to the mask (and sig unblocked under SA_NODEFER) for the length
   of the call, and the disposition spent first under SA_RESETHAND. jolt_fault
   itself was installed with SA_ONSTACK when the host's handler had it, so the
   stack is already the right one. */
static void jolt_run_host_fault(int i, int sig, siginfo_t *si, void *ctx) {
  const struct sigaction *a = &jolt_host_fault_act[i];
  sigset_t old, nodefer;
  if (jolt_host_fault_reset[i]
      || ((a->sa_flags & SA_SIGINFO) ? a->sa_sigaction == NULL
                                     : (a->sa_handler == SIG_DFL || a->sa_handler == SIG_IGN))) {
    jolt_fault_default(sig);
    return;
  }
  if (a->sa_flags & SA_RESETHAND) jolt_host_fault_reset[i] = 1;
  pthread_sigmask(SIG_BLOCK, &a->sa_mask, &old);
  if (a->sa_flags & SA_NODEFER) {
    sigemptyset(&nodefer);
    sigaddset(&nodefer, sig);
    pthread_sigmask(SIG_UNBLOCK, &nodefer, NULL);
  }
  jolt_run_fault_handler(a, sig, si, ctx);
  pthread_sigmask(SIG_SETMASK, &old, NULL);
}

static void jolt_fault(int sig, siginfo_t *si, void *ctx) {
  int i = jolt_fault_index(sig);
  if (i >= 0) {
    if (pthread_getspecific(S_tc_key) == NULL
        || (jolt_have_released && pthread_equal(pthread_self(), jolt_released_thread))) {
      jolt_run_host_fault(i, sig, si, ctx);
      return;
    }
    if (jolt_run_fault_handler(&jolt_chez_fault_act[i], sig, si, ctx)) return;
  }
  /* nobody to hand it to */
  jolt_fault_default(sig);
}

/* Before Sscheme_init. */
static void jolt_save_host_faults(void) {
  int i;
  for (i = 0; i < JOLT_FAULT_SIGNALS; i++) {
    struct sigaction a;
    if (sigaction(jolt_fault_sig[i], NULL, &a) == 0 && !jolt_is_fault_handler(&a)) {
      jolt_host_fault_act[i] = a;
      jolt_host_fault_reset[i] = 0;
    }
  }
  for (i = 0; i < JOLT_HOST_SIGNALS; i++)
    sigaction(jolt_host_sig[i], NULL, &jolt_host_sig_act[i]);
}

static int jolt_is_default(const struct sigaction *a) {
  return !(a->sa_flags & SA_SIGINFO) && a->sa_handler == SIG_DFL;
}

/* After Sbuild_heap, once Chez's handlers are in. */
static void jolt_chain_faults(void) {
  int i;
  jolt_have_released = 0;
  for (i = 0; i < JOLT_FAULT_SIGNALS; i++) {
    struct sigaction a;
    if (sigaction(jolt_fault_sig[i], NULL, &a) != 0 || jolt_is_fault_handler(&a)) continue;
    jolt_chez_fault_act[i] = a;
    a.sa_sigaction = jolt_fault;
    a.sa_flags |= SA_SIGINFO;
    if (jolt_host_fault_act[i].sa_flags & SA_ONSTACK) a.sa_flags |= SA_ONSTACK;
    sigaction(jolt_fault_sig[i], &a, NULL);
  }
  /* SIGINT and SIGQUIT are the host's; SIGPIPE keeps Chez's SIG_IGN only in
     place of SIG_DFL */
  for (i = 0; i < JOLT_HOST_SIGNALS; i++)
    if (jolt_host_sig[i] != SIGPIPE || !jolt_is_default(&jolt_host_sig_act[i]))
      sigaction(jolt_host_sig[i], &jolt_host_sig_act[i], NULL);
}

/* jolt_library_release_thread hands the calling thread back to host code;
   jolt_library_shutdown takes it back before Sscheme_deinit runs Scheme. */
static void jolt_faults_thread_released(int released) {
  if (released) jolt_released_thread = pthread_self();
  jolt_have_released = released;
}

/* After Sscheme_deinit: the signals are the host's again, SIG_DFL for one
   whose one-shot handler has run. */
static void jolt_restore_host_faults(void) {
  int i;
  for (i = 0; i < JOLT_FAULT_SIGNALS; i++) {
    if (jolt_host_fault_reset[i]) signal(jolt_fault_sig[i], SIG_DFL);
    else sigaction(jolt_fault_sig[i], &jolt_host_fault_act[i], NULL);
  }
  for (i = 0; i < JOLT_HOST_SIGNALS; i++)
    sigaction(jolt_host_sig[i], &jolt_host_sig_act[i], NULL);
}

#else
static void jolt_save_host_faults(void) {}
static void jolt_chain_faults(void) {}
static void jolt_faults_thread_released(int released) { (void)released; }
static void jolt_restore_host_faults(void) {}
#endif
