/* Foreign-thread callback witness for jolt.ffi (issue #973).
 *
 * The shape this reproduces is one native library serving a request/response
 * pair across two threads, which is what an embedded HTTP server looks like
 * from jolt:
 *
 *   svc_start(cb)   spawns a pthread the Scheme runtime has never seen, and
 *                   parks it on a condvar waiting for work. When work arrives
 *                   it calls `cb` — the FIRST entry into Scheme on that thread,
 *                   so the callable has to be :collect-safe or the process
 *                   takes a memory fault instead of an exception.
 *
 *   svc_call(path)  is the caller's half: hand the dispatch thread a request
 *                   and BLOCK until it answers, with a deadline. One foreign
 *                   call, start to finish — the wrapper shape of any native
 *                   client that connects and reads in one go.
 *
 * The whole gate is what happens between those two. svc_call parks the calling
 * thread inside C; whether that thread stays ACTIVE for the collector is
 * decided entirely by the jolt binding's :blocking option, and the callback on
 * the other side needs to allocate. See the .clj for the two rows.
 *
 * POSIX only (pthreads + condvars); the runner skips this gate elsewhere.
 * Mirrors the layout of the sibling FFI helpers: export macro, no tree
 * pollution, no dependency beyond libpthread. */

#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#define JOLT_FT_EXPORT __attribute__((visibility("default")))

/* The request the dispatch thread hands the callback: the callback reads the
 * path back out through req_path, the way a real handler reads a request
 * struct it was given a pointer to. */
typedef struct { char path[256]; } req_t;
typedef int (*handler_t)(void *);

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  to_server = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  to_client = PTHREAD_COND_INITIALIZER;

static handler_t handler;
static req_t     pending;
static int       have_request;   /* a request is queued, not yet taken */
static int       busy;           /* the dispatch thread is inside the callback */
static long      next_id;        /* the id of the request most recently queued */
static long      served_id;      /* the id of the request most recently answered */
static int       response;
static pthread_t dispatch_thread;

/* One absolute deadline for a whole svc_call, so a round that waits twice
 * (drain, then answer) cannot quietly get two full timeouts. */
static void deadline(struct timespec *ts, int ms) {
  struct timeval now;
  gettimeofday(&now, NULL);
  ts->tv_sec = now.tv_sec + ms / 1000;
  ts->tv_nsec = now.tv_usec * 1000L + (long)(ms % 1000) * 1000000L;
  if (ts->tv_nsec >= 1000000000L) { ts->tv_sec += 1; ts->tv_nsec -= 1000000000L; }
}

static void *dispatch(void *ignored) {
  (void)ignored;
  for (;;) {
    req_t req;
    long id;
    pthread_mutex_lock(&mu);
    while (!have_request) pthread_cond_wait(&to_server, &mu);
    req = pending;
    id = next_id;
    have_request = 0;
    busy = 1;
    pthread_mutex_unlock(&mu);

    /* Into Scheme, on a thread the runtime never started. */
    int status = handler(&req);

    pthread_mutex_lock(&mu);
    response = status;
    served_id = id;
    busy = 0;
    pthread_cond_broadcast(&to_client);
    pthread_mutex_unlock(&mu);
  }
  return NULL;
}

/* Register the callback and start the library's own thread. */
JOLT_FT_EXPORT
int svc_start(void *cb) {
  handler = (handler_t)cb;
  return pthread_create(&dispatch_thread, NULL, dispatch, NULL);
}

/* The caller's half: submit `path` and block for the answer. Returns the
 * callback's status; -1 if the dispatch thread did not answer within
 * timeout_ms (the failure the reporter saw as a socket read timeout), or -2 if
 * it was still inside a PREVIOUS callback for that long. Rounds are numbered so
 * a call can never read the answer to the round before it. */
JOLT_FT_EXPORT
int svc_call(const char *path, int timeout_ms) {
  struct timespec ts;
  long my_id;
  int answer;

  deadline(&ts, timeout_ms);
  pthread_mutex_lock(&mu);
  while (busy || have_request) {
    if (pthread_cond_timedwait(&to_client, &mu, &ts) == ETIMEDOUT) {
      pthread_mutex_unlock(&mu);
      return -2;
    }
  }
  memset(&pending, 0, sizeof pending);
  strncpy(pending.path, path ? path : "", sizeof pending.path - 1);
  my_id = ++next_id;
  have_request = 1;
  pthread_cond_signal(&to_server);

  while (served_id != my_id) {
    if (pthread_cond_timedwait(&to_client, &mu, &ts) == ETIMEDOUT) {
      pthread_mutex_unlock(&mu);
      return -1;
    }
  }
  answer = response;
  pthread_mutex_unlock(&mu);
  return answer;
}

/* Read the path out of the request the callback was handed. */
JOLT_FT_EXPORT
const char *req_path(void *p) { return ((req_t *)p)->path; }
