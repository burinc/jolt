/* jolt_code_region.h: keep a --library build's code in one aligned region
 * (macOS arm64 only; an empty include everywhere else).
 *
 * Chez places each code chunk wherever mmap finds room. Inside a host process
 * whose address space is already fragmented (a game engine or an editor that
 * loads the library), the chunks can land gigabytes apart, and on Apple arm64
 * a hot call or return whose target lies in a different 1GB- or 4GB-aligned
 * region than the branch mispredicts far more often. Chez's returns, and most
 * of its calls, are indirect branches, so the same library ran up to 1.7x
 * slower for the life of such a process (jolt-lang/jolt#1246).
 *
 * The library stub includes this file, so these hidden mmap/munmap definitions
 * live in the same image as the statically linked Chez kernel, and the
 * kernel's calls bind to them instead of libSystem's. Anonymous MAP_JIT
 * mappings (code chunks) are carved from one region reserved PROT_NONE and
 * aligned to its own size, so it never straddles a boundary larger than
 * itself. Everything else, and anything once the region is full, goes to the
 * real calls. Being hidden, they change nothing for the host or other images.
 *
 * The same fix proposed for Chez itself is cisco/ChezScheme#1074. Once jolt
 * builds against a Chez that has it, this file can go.
 */
#if defined(__APPLE__) && defined(__aarch64__)
#include <TargetConditionals.h>
#if TARGET_OS_OSX

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>

#define JOLT_CODE_REGION_BYTES ((uintptr_t)512 << 20)
#define JOLT_CODE_PAGE ((size_t)0x4000)

typedef struct jolt_code_range { char *addr; size_t bytes; struct jolt_code_range *next; } jolt_code_range;

static void *(*jolt_real_mmap)(void *, size_t, int, int, int, off_t);
static int (*jolt_real_munmap)(void *, size_t);
static pthread_once_t jolt_code_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t jolt_code_lock = PTHREAD_MUTEX_INITIALIZER;
static char *jolt_code_region, *jolt_code_next, *jolt_code_end;
static int jolt_code_tried;
static jolt_code_range *jolt_code_free; /* sorted by address, coalesced */

static void jolt_code_resolve(void) {
  jolt_real_mmap = (void *(*)(void *, size_t, int, int, int, off_t))dlsym(RTLD_NEXT, "mmap");
  jolt_real_munmap = (int (*)(void *, size_t))dlsym(RTLD_NEXT, "munmap");
}

static void jolt_code_reserve(void) {
  uintptr_t size = JOLT_CODE_REGION_BYTES;
  char *p, *start;
  jolt_code_tried = 1;
  /* fixed flags, since a caller may add MAP_32BIT, which fails on arm64;
     over-reserve so that a window aligned to `size` fits, then trim */
  p = (char *)jolt_real_mmap(NULL, 2 * size, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
  if (p == (char *)MAP_FAILED) return;
  start = (char *)(((uintptr_t)p + size - 1) & ~(size - 1));
  if (start > p) jolt_real_munmap(p, start - p);
  if (start + size < p + 2 * size) jolt_real_munmap(start + size, (p + 2 * size) - (start + size));
  jolt_code_region = jolt_code_next = start;
  jolt_code_end = start + size;
}

static void *jolt_code_get(size_t bytes, int prot) {
  jolt_code_range **pr, *r;
  char *addr;
  if (!jolt_code_tried) jolt_code_reserve();
  if (jolt_code_region == NULL) return NULL;
  for (pr = &jolt_code_free; (r = *pr) != NULL; pr = &r->next) {
    if (r->bytes >= bytes) {
      addr = r->addr;
      if (r->bytes == bytes) { *pr = r->next; free(r); }
      else { r->addr += bytes; r->bytes -= bytes; }
      return addr;
    }
  }
  if ((size_t)(jolt_code_end - jolt_code_next) < bytes) return NULL;
  /* macOS refuses to change the protection of MAP_JIT memory once it has been
     executable, so only the never-used tail is made accessible here, and a
     freed range stays accessible on the free list */
  if (mprotect(jolt_code_next, bytes, prot) != 0) return NULL;
  addr = jolt_code_next;
  jolt_code_next += bytes;
  return addr;
}

static void jolt_code_put(char *addr, size_t bytes) {
  jolt_code_range *prev = NULL, *r = jolt_code_free, *n;
  madvise(addr, bytes, MADV_FREE);
  while (r != NULL && r->addr < addr) { prev = r; r = r->next; }
  if (prev != NULL && prev->addr + prev->bytes == addr) {
    prev->bytes += bytes;
    n = prev;
  } else {
    if ((n = (jolt_code_range *)malloc(sizeof(jolt_code_range))) == NULL) abort();
    n->addr = addr; n->bytes = bytes; n->next = r;
    if (prev != NULL) prev->next = n; else jolt_code_free = n;
  }
  if (r != NULL && n->addr + n->bytes == r->addr) {
    n->bytes += r->bytes; n->next = r->next; free(r);
  }
}

__attribute__((visibility("hidden")))
void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
  pthread_once(&jolt_code_once, jolt_code_resolve);
  if (addr == NULL && fd == -1 && (flags & MAP_JIT) && (flags & MAP_ANON) && !(flags & MAP_FIXED)) {
    void *p;
    pthread_mutex_lock(&jolt_code_lock);
    p = jolt_code_get((len + JOLT_CODE_PAGE - 1) & ~(JOLT_CODE_PAGE - 1), prot);
    pthread_mutex_unlock(&jolt_code_lock);
    if (p != NULL) return p;
  }
  return jolt_real_mmap(addr, len, prot, flags, fd, off);
}

__attribute__((visibility("hidden")))
int munmap(void *addr, size_t len) {
  pthread_once(&jolt_code_once, jolt_code_resolve);
  if ((char *)addr >= jolt_code_region && (char *)addr < jolt_code_end) {
    pthread_mutex_lock(&jolt_code_lock);
    jolt_code_put((char *)addr, (len + JOLT_CODE_PAGE - 1) & ~(JOLT_CODE_PAGE - 1));
    pthread_mutex_unlock(&jolt_code_lock);
    return 0;
  }
  return jolt_real_munmap(addr, len);
}

#endif /* TARGET_OS_OSX */
#endif /* __APPLE__ && __aarch64__ */
