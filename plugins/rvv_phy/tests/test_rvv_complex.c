#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <simde/x86/avx2.h>
#include "sionna_rvv_complex.h"

static const int16_t reflip[16] __attribute__((aligned(32))) = {
    1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1};
static const int8_t shuffle_mask[32] __attribute__((aligned(32))) = {
    2,  3,  0,  1,  6,  7,  4,  5, 10, 11,  8,  9, 14, 15, 12, 13,
   18, 19, 16, 17, 22, 23, 20, 21, 26, 27, 24, 25, 30, 31, 28, 29};

static void simde_cmul(const int16_t a[16], const int16_t b[16], int32_t re[8], int32_t im[8], int conjugate)
{
  const simde__m256i va = simde_mm256_load_si256((const simde__m256i *)a);
  const simde__m256i vb = simde_mm256_load_si256((const simde__m256i *)b);
  const simde__m256i signs = simde_mm256_load_si256((const simde__m256i *)reflip);
  const simde__m256i mask = simde_mm256_load_si256((const simde__m256i *)shuffle_mask);
  simde__m256i vr;
  simde__m256i vi;
  if (conjugate) {
    vr = simde_mm256_madd_epi16(va, vb);
    vi = simde_mm256_madd_epi16(va, simde_mm256_shuffle_epi8(simde_mm256_sign_epi16(vb, signs), mask));
  } else {
    vr = simde_mm256_madd_epi16(va, simde_mm256_sign_epi16(vb, signs));
    vi = simde_mm256_madd_epi16(va, simde_mm256_shuffle_epi8(vb, mask));
  }
  simde_mm256_store_si256((simde__m256i *)re, vr);
  simde_mm256_store_si256((simde__m256i *)im, vi);
}

static uint32_t rng_state = 0x6d2b79f5u;
static int16_t next_i16(void)
{
  rng_state ^= rng_state << 13;
  rng_state ^= rng_state >> 17;
  rng_state ^= rng_state << 5;
  return (int16_t)rng_state;
}

static int check_case(const int16_t a[16], const int16_t b[16], int conjugate)
{
  int32_t expected_re[8] __attribute__((aligned(32)));
  int32_t expected_im[8] __attribute__((aligned(32)));
  int32_t actual_re[8] __attribute__((aligned(32)));
  int32_t actual_im[8] __attribute__((aligned(32)));
  simde_cmul(a, b, expected_re, expected_im, conjugate);
  if (conjugate)
    sionna_rvv_cmul_conj_q15x8(a, b, actual_re, actual_im);
  else
    sionna_rvv_cmul_q15x8(a, b, actual_re, actual_im);
  for (int lane = 0; lane < 8; ++lane) {
    if (actual_re[lane] != expected_re[lane] || actual_im[lane] != expected_im[lane]) {
      fprintf(stderr,
              "mismatch conj=%d lane=%d expected=(%d,%d) actual=(%d,%d)\n",
              conjugate,
              lane,
              expected_re[lane],
              expected_im[lane],
              actual_re[lane],
              actual_im[lane]);
      return 1;
    }
  }
  return 0;
}

int main(void)
{
#if !SIONNA_RVV_COMPLEX_AVAILABLE
  fputs("RVV complex backend is unavailable\n", stderr);
  return 77;
#else
  int16_t a[16] __attribute__((aligned(32)));
  int16_t b[16] __attribute__((aligned(32)));
  const int16_t edge[] = {INT16_MIN, INT16_MAX, -1, 0, 1, 2, -2, 16384};
  for (int i = 0; i < 16; ++i) {
    a[i] = edge[i % 8];
    b[i] = edge[(i * 3 + 1) % 8];
  }
  if (check_case(a, b, 0) || check_case(a, b, 1))
    return 1;
  for (int test = 0; test < 100000; ++test) {
    for (int i = 0; i < 16; ++i) {
      a[i] = next_i16();
      b[i] = next_i16();
    }
    if (check_case(a, b, 0) || check_case(a, b, 1))
      return 1;
  }
  puts("PASS: RVV and SIMDe complex products are bit-identical");
  return 0;
#endif
}
