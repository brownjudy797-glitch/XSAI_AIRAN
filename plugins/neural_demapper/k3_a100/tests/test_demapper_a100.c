#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
  int16_t r;
  int16_t i;
} c16_t;

typedef int32_t (*init_fn)(void);
typedef int (*compute_fn)(int32_t *, c16_t *, c16_t *, c16_t *, int16_t *,
                          uint32_t, uint8_t, uint8_t);

int main(int argc, char **argv)
{
  if (argc != 2)
    return 2;
  void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!handle) {
    fprintf(stderr, "%s\n", dlerror());
    return 3;
  }
  init_fn init = (init_fn)dlsym(handle, "demapper_init");
  init_fn init_thread = (init_fn)dlsym(handle, "demapper_init_thread");
  init_fn shutdown = (init_fn)dlsym(handle, "demapper_shutdown");
  compute_fn compute = (compute_fn)dlsym(handle, "demapper_compute_llr");
  if (!init || !init_thread || !shutdown || !compute)
    return 4;
  if (init() != 0 || init_thread() != 0)
    return 5;

  int32_t symbols[8] = {0};
  c16_t magnitudes[8] = {0};
  int16_t llr[32] = {0};
  for (int i = 0; i < 8; ++i) {
    ((int16_t *)symbols)[2 * i] = (int16_t)(64 + i);
    ((int16_t *)symbols)[2 * i + 1] = (int16_t)(-64 - i);
    magnitudes[i].r = 128;
    magnitudes[i].i = 128;
  }
  if (compute(symbols, magnitudes, NULL, NULL, llr, 8, 0, 2) != 0)
    return 6;
  if (compute(symbols, magnitudes, NULL, NULL, llr, 8, 0, 4) != 1)
    return 7;
  shutdown();
  dlclose(handle);
  puts("PASS: A100 neural demapper load, fallback and 16-QAM inference");
  return 0;
}
