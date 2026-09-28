#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

typedef struct {
  int16_t r;
  int16_t i;
} c16_t;

typedef int32_t (*init_fn)(void);
typedef int (*compute_fn)(int32_t *, c16_t *, c16_t *, c16_t *, int16_t *,
                          uint32_t, uint8_t, uint8_t);

static uint64_t ns(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int compare_u64(const void *lhs, const void *rhs)
{
  const uint64_t a = *(const uint64_t *)lhs;
  const uint64_t b = *(const uint64_t *)rhs;
  return (a > b) - (a < b);
}

int main(int argc, char **argv)
{
  if (argc < 2 || argc > 4) {
    fprintf(stderr, "usage: %s LIB [NB_RE=288] [ITERATIONS=1000]\n", argv[0]);
    return 2;
  }
  uint32_t nb_re = argc >= 3 ? (uint32_t)strtoul(argv[2], NULL, 10) : 288;
  uint32_t iterations = argc >= 4 ? (uint32_t)strtoul(argv[3], NULL, 10) : 1000;
  if (!nb_re || !iterations)
    return 2;

  void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!handle) {
    fprintf(stderr, "%s\n", dlerror());
    return 3;
  }
  init_fn init = (init_fn)dlsym(handle, "demapper_init");
  init_fn shutdown = (init_fn)dlsym(handle, "demapper_shutdown");
  compute_fn compute = (compute_fn)dlsym(handle, "demapper_compute_llr");
  if (!init || !shutdown || !compute || init() != 0)
    return 4;

  int32_t *symbols = calloc(nb_re, sizeof(*symbols));
  c16_t *magnitudes = calloc(nb_re, sizeof(*magnitudes));
  int16_t *llr = calloc((size_t)nb_re * 4, sizeof(*llr));
  uint64_t *samples = calloc(iterations, sizeof(*samples));
  if (!symbols || !magnitudes || !llr || !samples)
    return 5;
  for (uint32_t i = 0; i < nb_re; ++i) {
    ((int16_t *)symbols)[2 * i] = (int16_t)(64 + i % 32);
    ((int16_t *)symbols)[2 * i + 1] = (int16_t)(-64 - i % 32);
    magnitudes[i].r = 128;
    magnitudes[i].i = 128;
  }

  for (int i = 0; i < 20; ++i)
    if (compute(symbols, magnitudes, NULL, NULL, llr, nb_re, 0, 4) != 1)
      return 6;
  uint64_t elapsed = 0;
  for (uint32_t i = 0; i < iterations; ++i) {
    uint64_t begin = ns();
    if (compute(symbols, magnitudes, NULL, NULL, llr, nb_re, 0, 4) != 1)
      return 7;
    samples[i] = ns() - begin;
    elapsed += samples[i];
  }
  qsort(samples, iterations, sizeof(*samples), compare_u64);
  const uint32_t p50 = (iterations - 1) * 50 / 100;
  const uint32_t p95 = (iterations - 1) * 95 / 100;
  const uint32_t p99 = (iterations - 1) * 99 / 100;

  printf("A100_DEMAPPER nb_re=%u iterations=%u avg_us=%.3f p50_us=%.3f "
         "p95_us=%.3f p99_us=%.3f max_us=%.3f\n",
         nb_re, iterations, elapsed / 1e3 / iterations,
         samples[p50] / 1e3, samples[p95] / 1e3, samples[p99] / 1e3,
         samples[iterations - 1] / 1e3);
  shutdown();
  free(symbols);
  free(magnitudes);
  free(llr);
  free(samples);
  dlclose(handle);
  return 0;
}
