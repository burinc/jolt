/* driver-signals.c — a host that handles its own memory faults loads a jolt
 * library, then faults in its own code.
 *
 * Runtimes such as .NET (Mono) and the JVM install a SIGSEGV/SIGBUS handler
 * and turn a null dereference in their own code into an exception. Chez
 * Scheme installs process-wide handlers for those signals at init, so after
 * jolt_library_init such a fault reaches Chez's handler, which reports
 * "invalid memory reference" and aborts the host. With a Chez that passes a
 * fault on a thread not running Scheme code to the handler installed before
 * it, the host's handler runs and the host carries on.
 *
 * The same holds after jolt_library_shutdown (Sscheme_deinit), when Chez no
 * longer owns the signals, and after a second jolt_library_init.
 *
 * Prints "before load: 11" (or 10, SIGBUS), then "after load", "after
 * shutdown" and "after reinit" with the same number, exit 0.
 */
#include <dlfcn.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static sigjmp_buf recover;
static volatile sig_atomic_t host_handled;

static void host_handler(int sig, siginfo_t *si, void *ctx) {
  (void)si; (void)ctx;
  host_handled = sig;
  siglongjmp(recover, 1);
}

static int fault_in_host(void) {
  host_handled = 0;
  if (sigsetjmp(recover, 1) == 0) {
    volatile int *p = (volatile int *)0;
    return *p;
  }
  return host_handled;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: driver-signals <libpath>\n"); return 2; }
  alarm(30);
  struct sigaction act;
  memset(&act, 0, sizeof act);
  act.sa_sigaction = host_handler;
  act.sa_flags = SA_SIGINFO;
  sigemptyset(&act.sa_mask);
  sigaction(SIGSEGV, &act, 0);
  sigaction(SIGBUS, &act, 0);
  printf("before load: %d\n", fault_in_host());
  fflush(stdout);
  void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
  int (*init)(int, char **) = (int (*)(int, char **))dlsym(h, "jolt_library_init");
  void (*release)(void) = (void (*)(void))dlsym(h, "jolt_library_release_thread");
  if (!init || init(0, 0) != 0) { fprintf(stderr, "jolt_library_init failed\n"); return 1; }
  if (release) release();
  printf("after load: %d\n", fault_in_host());
  fflush(stdout);
  void (*shutdown)(void) = (void (*)(void))dlsym(h, "jolt_library_shutdown");
  if (!shutdown) { fprintf(stderr, "missing jolt_library_shutdown\n"); return 1; }
  shutdown();
  printf("after shutdown: %d\n", fault_in_host());
  fflush(stdout);
  if (init(0, 0) != 0) { fprintf(stderr, "second jolt_library_init failed\n"); return 1; }
  if (release) release();
  printf("after reinit: %d\n", fault_in_host());
  return 0;
}
