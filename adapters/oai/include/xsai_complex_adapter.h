#ifndef XSAI_COMPLEX_ADAPTER_H
#define XSAI_COMPLEX_ADAPTER_H
#include <stdbool.h>
#include "sionna_rvv_complex.h"
/* OAI-side adapter boundary. Caller retains the existing SIMDe path if false.
 * Eight interleaved Q15 complex inputs, separate int32 outputs; no allocation.
 * Input/output arrays must not overlap. Integer behavior matches the existing
 * SIMDe sign_epi16 + madd_epi16 operation, including INT16_MIN wraparound.
 * Build-time selection only: no claim of a runtime DFT plugin or stable ABI.
 */
static inline bool xsai_oai_try_cmul_q15x8(const int16_t a[16], const int16_t b[16],
                                         int32_t re[8], int32_t im[8], bool conjugate)
{
#if SIONNA_RVV_COMPLEX_AVAILABLE
  if (conjugate) sionna_rvv_cmul_conj_q15x8(a, b, re, im);
  else sionna_rvv_cmul_q15x8(a, b, re, im);
  return true;
#else
  (void)a; (void)b; (void)re; (void)im; (void)conjugate;
  return false;
#endif
}
#endif
