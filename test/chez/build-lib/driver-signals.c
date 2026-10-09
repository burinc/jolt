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
 * The host's handler is installed the way such runtimes install theirs: with
 * SA_ONSTACK on an alternate signal stack (a stack overflow can only be
 * handled there) and an sa_mask (SIGUSR1 here). Each fault reports the signal,
 * whether the handler ran on the alternate stack and whether SIGUSR1 was
 * blocked in it: "11 1 1" when the kernel delivered it to the host directly.
 *
 * Checked here, each on the thread named:
 *   child, one-shot          a host handler installed with SA_RESETHAND runs
 *                            once; the next fault takes the default action
 *                            and kills the process
 *   main, before load        the host's handler runs (the baseline)
 *   main, after init         a fault in Scheme code (the scheme_fault export)
 *                            is still jolt's: it answers 1. Run with the
 *                            thread's alternate stack disabled, so the macOS
 *                            limit under "worker" below stays in that row
 *   main, after release      a host fault goes to the host's handler, with
 *                            the host's stack and mask
 *   worker                   a thread the host started (on its own
 *                            alternate stack) faults in host code, calls
 *                            scheme_fault (1) and alloc_work, then faults in
 *                            host code again: the host's handler both times
 *   main, after shutdown     the host's handler: the signals are given back
 *   main, after reinit       the host's handler again
 *
 * The interactive signals are the host's too: its SIGINT and SIGQUIT handlers
 * stay in place while the library is loaded, and SIGPIPE, which the host left
 * at SIG_DFL, is ignored only while the library is (jolt's I/O answers EPIPE
 * rather than dying) and is SIG_DFL again after shutdown.
 *
 * Two rows differ on macOS, where the library cannot do what the kernel does:
 *   - sigaction does not report SA_RESETHAND back, so the stub cannot see a
 *     one-shot handler: "one-shot: 1 0", the child surviving its second fault;
 *   - Chez leaves its fault handler with _longjmp, which does not clear the
 *     kernel's per-thread "on the alternate stack" flag the way libc's
 *     longjmp and sigreturn do, so after a fault in Scheme code taken on the
 *     alternate stack, that thread's signals run on its normal stack: the
 *     worker's second fault reports "11 0 1". Linux decides by the stack
 *     pointer and has neither limit.
 *
 * Prints, with 10 for 11 where a null dereference raises SIGBUS:
 *   one-shot: 1 11
 *   before load: 11 1 1
 *   scheme fault: 1
 *   after load: 11 1 1
 *   signals after load: host host ign 1
 *   worker: 11 1 1, 1, 11 1 1
 *   after shutdown: 11 1 1
 *   signals after shutdown: host host dfl 1
 *   after reinit: 11 1 1
 *   signals after reinit: host host ign 1
 * and exits 0. alarm(30) turns a hang into a SIGALRM death.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static __thread sigjmp_buf recover;
static __thread volatile sig_atomic_t host_handled, host_onstack, host_masked;

static void host_handler(int sig, siginfo_t *si, void *ctx) {
  stack_t ss;
  sigset_t cur;
  (void)si; (void)ctx;
  host_handled = sig;
  /* where this frame is, not SS_ONSTACK: that is the kernel's bookkeeping, and
     a longjmp off the alternate stack (Chez's fault handler) can leave it stale */
  host_onstack = sigaltstack(NULL, &ss) == 0 && !(ss.ss_flags & SS_DISABLE)
    && (char *)&ss >= (char *)ss.ss_sp && (char *)&ss < (char *)ss.ss_sp + ss.ss_size;
  host_masked = pthread_sigmask(SIG_BLOCK, NULL, &cur) == 0 && sigismember(&cur, SIGUSR1) == 1;
  siglongjmp(recover, 1);
}

/* "sig onstack masked" of the host handler's run, "0 0 0" when it did not run */
static const char *fault_in_host(char *buf) {
  host_handled = host_onstack = host_masked = 0;
  if (sigsetjmp(recover, 1) == 0) {
    volatile int *p = (volatile int *)0;
    (void)*p;
  }
  sprintf(buf, "%d %d %d", (int)host_handled, (int)host_onstack, (int)host_masked);
  return buf;
}

static int use_altstack(void) {
  stack_t ss;
  ss.ss_size = 1 << 16;
  ss.ss_sp = malloc(ss.ss_size);
  ss.ss_flags = 0;
  return ss.ss_sp && sigaltstack(&ss, NULL) == 0;
}

/* SS_DISABLE the calling thread's alternate stack, or put the saved one back */
static int altstack_off(stack_t *saved) {
  stack_t off;
  if (sigaltstack(NULL, saved) != 0) return 0;
  off = *saved;  /* macOS checks ss_size even under SS_DISABLE */
  off.ss_flags = SS_DISABLE;
  return sigaltstack(&off, NULL) == 0;
}

static void install_host_faults(int extra_flags) {
  struct sigaction act;
  memset(&act, 0, sizeof act);
  act.sa_sigaction = host_handler;
  act.sa_flags = SA_SIGINFO | SA_ONSTACK | extra_flags;
  sigemptyset(&act.sa_mask);
  sigaddset(&act.sa_mask, SIGUSR1);
  sigaction(SIGSEGV, &act, 0);
  sigaction(SIGBUS, &act, 0);
}

static volatile sig_atomic_t host_ints;
static void host_int(int sig) { (void)sig; host_ints++; }
static void host_quit(int sig) { (void)sig; }

static const char *disposition(int sig, void (*host)(int)) {
  struct sigaction a;
  if (sigaction(sig, NULL, &a) != 0) return "?";
  if (a.sa_flags & SA_SIGINFO) return "other";
  if (a.sa_handler == SIG_DFL) return "dfl";
  if (a.sa_handler == SIG_IGN) return "ign";
  if (a.sa_handler == host) return "host";
  return "other";
}

/* the three dispositions, then whether a raised SIGINT reached the host */
static void print_signals(const char *stage) {
  int before = host_ints;
  raise(SIGINT);
  printf("signals %s: %s %s %s %d\n", stage, disposition(SIGINT, host_int),
         disposition(SIGQUIT, host_quit), disposition(SIGPIPE, NULL),
         host_ints == before + 1);
  fflush(stdout);
}

typedef int (*init_fn)(int, char **);
typedef void (*void_fn)(void);

/* A child loads the library under a one-shot host handler and faults twice:
   the handler recovers the first (it writes 1 to the pipe), and the second
   must kill the child, as the kernel's SA_RESETHAND would. Prints
   "one-shot: <recovered> <signal the child died of, 0 for a normal exit>". */
static int one_shot(const char *lib) {
  int fds[2];
  if (pipe(fds) != 0) return 1;
  fflush(stdout);
  pid_t pid = fork();
  if (pid < 0) return 1;
  if (pid == 0) {
    struct rlimit nocore = { 0, 0 };
    char buf[32];
    setrlimit(RLIMIT_CORE, &nocore);
    close(fds[0]);
    use_altstack();
    install_host_faults(SA_RESETHAND);
    void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    init_fn init = h ? (init_fn)dlsym(h, "jolt_library_init") : NULL;
    void_fn release = h ? (void_fn)dlsym(h, "jolt_library_release_thread") : NULL;
    if (!init || !release || init(0, 0) != 0) _exit(3);
    release();
    char r = fault_in_host(buf)[0] != '0' ? '1' : '0';
    if (write(fds[1], &r, 1) != 1) _exit(4);
    fault_in_host(buf);
    _exit(0);
  }
  close(fds[1]);
  char r = '0';
  if (read(fds[0], &r, 1) != 1) r = '0';
  close(fds[0]);
  int status = 0;
  waitpid(pid, &status, 0);
  printf("one-shot: %c %d\n", r, WIFSIGNALED(status) ? WTERMSIG(status) : 0);
  fflush(stdout);
  return 0;
}

typedef int (*int_fn)(void);
typedef int (*work_fn)(int);
static int_fn scheme_fault;
static work_fn alloc_work;
static int worker_scheme;
static char worker_first[32], worker_after[32];

static void *worker(void *arg) {
  (void)arg;
  if (!use_altstack()) return NULL;
  fault_in_host(worker_first);
  worker_scheme = scheme_fault();
  alloc_work(1);
  fault_in_host(worker_after);
  return NULL;
}

int main(int argc, char **argv) {
  char buf[32];
  if (argc < 2) { fprintf(stderr, "usage: driver-signals <libpath>\n"); return 2; }
  alarm(30);
  if (one_shot(argv[1]) != 0) { fprintf(stderr, "one-shot child failed to start\n"); return 1; }
  if (!use_altstack()) { fprintf(stderr, "sigaltstack failed\n"); return 1; }
  install_host_faults(0);
  signal(SIGINT, host_int);
  signal(SIGQUIT, host_quit);
  signal(SIGPIPE, SIG_DFL);
  printf("before load: %s\n", fault_in_host(buf));
  fflush(stdout);
  void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
  init_fn init = (init_fn)dlsym(h, "jolt_library_init");
  void *(*lookup)(const char *) = (void *(*)(const char *))dlsym(h, "jolt_lookup");
  void_fn release = (void_fn)dlsym(h, "jolt_library_release_thread");
  void_fn shutdown = (void_fn)dlsym(h, "jolt_library_shutdown");
  if (!init || !lookup || !release || !shutdown) {
    fprintf(stderr, "missing init/lookup/release/shutdown\n"); return 1;
  }
  if (init(0, 0) != 0) { fprintf(stderr, "jolt_library_init failed\n"); return 1; }
  scheme_fault = (int_fn)lookup("scheme_fault");
  alloc_work = (work_fn)lookup("alloc_work");
  if (!scheme_fault || !alloc_work) { fprintf(stderr, "missing scheme_fault/alloc_work\n"); return 1; }
  /* off the alternate stack: see "worker" for a Scheme fault on one */
  stack_t main_alt;
  if (!altstack_off(&main_alt)) { fprintf(stderr, "sigaltstack off failed\n"); return 1; }
  printf("scheme fault: %d\n", scheme_fault());
  fflush(stdout);
  if (sigaltstack(&main_alt, NULL) != 0) { fprintf(stderr, "sigaltstack back failed\n"); return 1; }
  release();
  printf("after load: %s\n", fault_in_host(buf));
  fflush(stdout);
  print_signals("after load");
  pthread_t t;
  if (pthread_create(&t, NULL, worker, NULL) != 0) { fprintf(stderr, "pthread_create failed\n"); return 1; }
  pthread_join(t, NULL);
  printf("worker: %s, %d, %s\n", worker_first, worker_scheme, worker_after);
  fflush(stdout);
  shutdown();
  printf("after shutdown: %s\n", fault_in_host(buf));
  fflush(stdout);
  print_signals("after shutdown");
  if (init(0, 0) != 0) { fprintf(stderr, "second jolt_library_init failed\n"); return 1; }
  release();
  printf("after reinit: %s\n", fault_in_host(buf));
  fflush(stdout);
  print_signals("after reinit");
  return 0;
}
