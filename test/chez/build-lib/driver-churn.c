/* driver-churn.c: load a jolt --library and call code_churn(4), which compiles
 * and drops code so that code chunks get freed and reused. Prints its answer
 * (1 when every compiled function computed the right thing).
 */
#include <stdio.h>
#include <dlfcn.h>

typedef int (*init_fn)(int, char**);
typedef void* (*lookup_fn)(const char*);
typedef int (*churn_fn)(int);

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: driver-churn <libpath>\n"); return 2; }
  void* h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
  init_fn init = (init_fn)dlsym(h, "jolt_library_init");
  lookup_fn lookup = (lookup_fn)dlsym(h, "jolt_lookup");
  if (!init || !lookup) { fprintf(stderr, "missing init/lookup: %s\n", dlerror()); return 1; }
  if (init(0, NULL) != 0) { fprintf(stderr, "jolt_library_init failed\n"); return 1; }
  churn_fn churn = (churn_fn)lookup("code_churn");
  if (!churn) { fprintf(stderr, "jolt_lookup(\"code_churn\") returned NULL\n"); return 1; }
  printf("%d\n", churn(4));
  return 0;
}
