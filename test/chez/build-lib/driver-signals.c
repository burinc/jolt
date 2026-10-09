/* driver-signals.c — a host that handles its own memory faults loads a jolt
 * library, then faults in its own code (#1277).
 *
 * Runtimes such as .NET (Mono) and the JVM install a SIGSEGV/SIGBUS handler
 * and turn a null dereference in their own code into an exception. Chez
 * Scheme installs process-wide handlers for those signals at init and treats
 * every such fault as Scheme's, so without the library stub's fault chaining
 * a fault in host code after jolt_library_init reports "invalid memory
 * reference" and aborts the host.
 *
 * Checked here, each on the thread named:
 *   main, before load        the host's handler runs (the baseline)
 *   main, after init         a fault in Scheme code (the scheme_fault export)
 *                            is still jolt's: it answers 1
 *   main, after release      a host fault goes to the host's handler
 *   worker                   a thread the host started calls scheme_fault
 *                            (1), then alloc_work, then faults in host code:
 *                            the host's handler
 *   main, after shutdown     the host's handler: the signals are given back
 *   main, after reinit       the host's handler again
 *
 * Prints "before load: 11" (10 where a null dereference raises SIGBUS), then
 * "scheme fault: 1", "after load: 11", "worker: 1 11", "after shutdown: 11"
 * and "after reinit: 11", exit 0. alarm(30) turns a hang into a SIGALRM death.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static __thread sigjmp_buf recover;
static __thread volatile sig_atomic_t host_handled;

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

typedef int (*int_fn)(void);
typedef int (*work_fn)(int);
static int_fn scheme_fault;
static work_fn alloc_work;
static int worker_scheme, worker_host;

static void *worker(void *arg) {
  (void)arg;
  worker_scheme = scheme_fault();
  alloc_work(1);
  worker_host = fault_in_host();
  return NULL;
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
  void *(*lookup)(const char *) = (void *(*)(const char *))dlsym(h, "jolt_lookup");
  void (*release)(void) = (void (*)(void))dlsym(h, "jolt_library_release_thread");
  void (*shutdown)(void) = (void (*)(void))dlsym(h, "jolt_library_shutdown");
  if (!init || !lookup || !release || !shutdown) {
    fprintf(stderr, "missing init/lookup/release/shutdown\n"); return 1;
  }
  if (init(0, 0) != 0) { fprintf(stderr, "jolt_library_init failed\n"); return 1; }
  scheme_fault = (int_fn)lookup("scheme_fault");
  alloc_work = (work_fn)lookup("alloc_work");
  if (!scheme_fault || !alloc_work) { fprintf(stderr, "missing scheme_fault/alloc_work\n"); return 1; }
  printf("scheme fault: %d\n", scheme_fault());
  fflush(stdout);
  release();
  printf("after load: %d\n", fault_in_host());
  fflush(stdout);
  pthread_t t;
  if (pthread_create(&t, NULL, worker, NULL) != 0) { fprintf(stderr, "pthread_create failed\n"); return 1; }
  pthread_join(t, NULL);
  printf("worker: %d %d\n", worker_scheme, worker_host);
  fflush(stdout);
  shutdown();
  printf("after shutdown: %d\n", fault_in_host());
  fflush(stdout);
  if (init(0, 0) != 0) { fprintf(stderr, "second jolt_library_init failed\n"); return 1; }
  release();
  printf("after reinit: %d\n", fault_in_host());
  return 0;
}
