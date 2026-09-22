#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <x86/avx2.h>

__attribute__((noinline)) static simde__m256i run_madd(simde__m256i a, simde__m256i b) {
  return simde_mm256_madd_epi16(a, b);
}

static uint32_t state = 0x31415926u;
static uint32_t random32(void) {
  state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state;
}

int main(void) {
  for (int trial = 0; trial < 100000; ++trial) {
    int16_t a[16] __attribute__((aligned(32)));
    int16_t b[16] __attribute__((aligned(32)));
    int32_t expected[8], got[8] __attribute__((aligned(32)));
    for (int i = 0; i < 16; ++i) { a[i] = (int16_t)random32(); b[i] = (int16_t)random32(); }
    if (trial == 0) {
      const int16_t e[16] = {INT16_MIN, INT16_MIN, INT16_MAX, INT16_MAX,
        INT16_MIN, INT16_MAX, -1, 1, 0, INT16_MIN, 0, INT16_MAX,
        12345, -23456, -32767, 32766};
      memcpy(a, e, sizeof(a));
      for (int i = 0; i < 16; ++i) b[i] = e[15-i];
    }
    for (int i = 0; i < 8; ++i) {
      uint32_t p0 = (uint32_t)((int32_t)a[2*i] * (int32_t)b[2*i]);
      uint32_t p1 = (uint32_t)((int32_t)a[2*i+1] * (int32_t)b[2*i+1]);
      expected[i] = (int32_t)(p0 + p1);
    }
    simde__m256i av = simde_mm256_loadu_si256((const simde__m256i *)a);
    simde__m256i bv = simde_mm256_loadu_si256((const simde__m256i *)b);
    simde__m256i rv = run_madd(av, bv);
    simde_mm256_storeu_si256((simde__m256i *)got, rv);
    if (memcmp(got, expected, sizeof(got))) { fprintf(stderr, "FAIL trial %d\n", trial); return 1; }
  }
  puts("PASS: 100000 vectors including overflow/extreme cases");

  int16_t a[16] __attribute__((aligned(32))), b[16] __attribute__((aligned(32)));
  for (int i = 0; i < 16; ++i) { a[i] = (int16_t)(i * 997 - 7000); b[i] = (int16_t)(13000 - i * 733); }
  simde__m256i av = simde_mm256_loadu_si256((const simde__m256i *)a);
  simde__m256i bv = simde_mm256_loadu_si256((const simde__m256i *)b);
  simde__m256i (*volatile fnptr)(simde__m256i, simde__m256i) = run_madd;
  volatile int32_t sink = 0;
  const int iterations = 5000000;
  struct timespec begin, end;
  clock_gettime(CLOCK_MONOTONIC_RAW, &begin);
  for (int i = 0; i < iterations; ++i) {
    simde__m256i rv = fnptr(av, bv);
    sink ^= ((const int32_t *)&rv)[i & 7];
  }
  clock_gettime(CLOCK_MONOTONIC_RAW, &end);
  uint64_t elapsed = (uint64_t)(end.tv_sec-begin.tv_sec)*1000000000ull + (uint64_t)(end.tv_nsec-begin.tv_nsec);
  printf("BENCH %.3f ns/call sink=%d\n", (double)elapsed/iterations, sink);
  return 0;
}
