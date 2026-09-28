#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { int16_t r, i; } c16_t;
typedef int32_t (*init_fn)(void);
typedef int (*compute_fn)(int32_t *, c16_t *, c16_t *, c16_t *, int16_t *,
                          uint32_t, uint8_t, uint8_t);
struct backend { void *handle; init_fn init, shutdown; compute_fn compute; };

static int load(struct backend *backend, const char *path) {
  backend->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!backend->handle) return -1;
  backend->init = (init_fn)dlsym(backend->handle, "demapper_init");
  backend->shutdown = (init_fn)dlsym(backend->handle, "demapper_shutdown");
  backend->compute = (compute_fn)dlsym(backend->handle, "demapper_compute_llr");
  return (!backend->init || !backend->shutdown || !backend->compute ||
          backend->init()) ? -1 : 0;
}

int main(int argc, char **argv) {
  if (argc != 4) return 2;
  struct backend reference = {0}, candidate = {0};
  if (load(&reference, argv[1]) || load(&candidate, argv[2])) return 3;
  FILE *stream = fopen(argv[3], "rb");
  if (!stream) return 4;
  unsigned long long calls = 0, llrs = 0, different = 0, over_one = 0;
  unsigned long long sign_flips = 0, abs_sum = 0;
  int max_abs = 0;
  uint32_t header[5];
  while (fread(header, 1, sizeof(header), stream) == sizeof(header)) {
    if (header[0] != 0x58444331 || !header[2] || header[4] != 4) return 5;
    const uint32_t n = header[2];
    int32_t *iq = malloc((size_t)n * sizeof(*iq));
    c16_t *mag = malloc((size_t)n * sizeof(*mag));
    int16_t *a = malloc((size_t)n * 4 * sizeof(*a));
    int16_t *b = malloc((size_t)n * 4 * sizeof(*b));
    if (!iq || !mag || !a || !b) return 6;
    if (fread(iq, sizeof(*iq), n, stream) != n ||
        fread(mag, sizeof(*mag), n, stream) != n ||
        fseek(stream, (long)n * 8, SEEK_CUR)) return 7;
    if (reference.compute(iq, mag, 0, 0, a, n, header[3], 4) != 1 ||
        candidate.compute(iq, mag, 0, 0, b, n, header[3], 4) != 1) return 8;
    for (uint32_t i = 0; i < 4 * n; ++i) {
      int delta = (int)b[i] - (int)a[i];
      if (delta < 0) delta = -delta;
      abs_sum += (unsigned)delta;
      if (delta) ++different;
      if (delta > 1) ++over_one;
      if (delta > max_abs) max_abs = delta;
      if (a[i] && b[i] && ((a[i] < 0) != (b[i] < 0))) ++sign_flips;
    }
    ++calls;
    llrs += (unsigned long long)n * 4;
    free(iq); free(mag); free(a); free(b);
  }
  if (!feof(stream) || !calls) return 9;
  fclose(stream);
  printf("REAL_CAPTURE_DIFF calls=%llu llrs=%llu different=%llu mean_abs=%.9f "
         "max_abs=%d over_one=%llu nonzero_sign_flips=%llu\n",
         calls, llrs, different, (double)abs_sum / llrs, max_abs, over_one,
         sign_flips);
  candidate.shutdown();
  reference.shutdown();
  return sign_flips ? 10 : 0;
}
