/* driver-release.c — the #1234 handoff: an embedder whose init thread goes off
 * to do host work while a thread it started calls into the library.
 *
 * The main thread calls jolt_library_init, then jolt_library_release_thread,
 * then parks in pthread_join (host code, no jolt call) while a worker makes
 * 20000 calls to the :collect-safe export alloc_work, which allocates on every
 * call. Without the release, the init thread stays an active jolt thread, the
 * worker's first collection waits for it to reach a safe point, and host code
 * never reaches one: the two wait for each other for good. Then it shuts the
 * library down from the released thread, which jolt_library_shutdown must
 * reactivate before it runs any Scheme.
 *
 * alarm(30) turns a hang into a SIGALRM death, so a regression fails the gate
 * rather than stalling it, with no dependence on a timeout(1) binary.
 * Prints "<last> <calls>" on success. POSIX only (pthreads).
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

typedef int (*init_fn)(int, char**);
typedef void* (*lookup_fn)(const char*);
typedef void (*void_fn)(void);
typedef int (*work_fn)(int);

#define CALLS 20000
static work_fn work;
static int last;

static void* worker(void* arg) {
  (void)arg;
  for (int i = 0; i < CALLS; i++) last = work(i);
  return NULL;
}

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: driver-release <libpath>\n"); return 2; }
  alarm(30);
  void* h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
  init_fn init = (init_fn)dlsym(h, "jolt_library_init");
  lookup_fn lookup = (lookup_fn)dlsym(h, "jolt_lookup");
  void_fn release = (void_fn)dlsym(h, "jolt_library_release_thread");
  void_fn shutdown = (void_fn)dlsym(h, "jolt_library_shutdown");
  if (!init || !lookup || !shutdown) { fprintf(stderr, "missing init/lookup/shutdown\n"); return 1; }
  if (!release) { fprintf(stderr, "missing jolt_library_release_thread\n"); return 1; }
  if (init(0, NULL) != 0) { fprintf(stderr, "jolt_library_init failed\n"); return 1; }
  work = (work_fn)lookup("alloc_work");
  if (!work) { fprintf(stderr, "jolt_lookup(\"alloc_work\") returned NULL\n"); return 1; }
  release();
  pthread_t t;
  if (pthread_create(&t, NULL, worker, NULL) != 0) { fprintf(stderr, "pthread_create failed\n"); return 1; }
  pthread_join(t, NULL);
  shutdown();
  printf("%d %d\n", last, CALLS);
  return 0;
}
