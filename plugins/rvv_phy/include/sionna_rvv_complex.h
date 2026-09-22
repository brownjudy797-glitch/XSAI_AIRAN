#ifndef SIONNA_RVV_COMPLEX_H
#define SIONNA_RVV_COMPLEX_H

#include <stddef.h>
#include <stdint.h>

/*
 * Keep this backend independent of OAI and SIMDe data types.  Callers only
 * provide interleaved signed Q15 arrays and receive eight signed 32-bit
 * complex products.  This makes the kernel reusable by later OAI/6G code.
 */
#if defined(__riscv_vector) && defined(__GNUC__) && (__GNUC__ >= 16) && !defined(SIONNA_RVV_COMPLEX_DISABLE)
  #include <riscv_vector.h>
  #define SIONNA_RVV_COMPLEX_AVAILABLE 1

static inline __attribute__((always_inline))
void sionna_rvv_cmul_q15x8(const int16_t a[16],
                           const int16_t b[16],
                           int32_t real[8],
                           int32_t imag[8])
{
  const size_t vl = __riscv_vsetvl_e16m1(8);
  const vint16m1x2_t av = __riscv_vlseg2e16_v_i16m1x2(a, vl);
  const vint16m1x2_t bv = __riscv_vlseg2e16_v_i16m1x2(b, vl);
  const vint16m1_t ar = __riscv_vget_v_i16m1x2_i16m1(av, 0);
  const vint16m1_t ai = __riscv_vget_v_i16m1x2_i16m1(av, 1);
  const vint16m1_t br = __riscv_vget_v_i16m1x2_i16m1(bv, 0);
  const vint16m1_t bi = __riscv_vget_v_i16m1x2_i16m1(bv, 1);
  const vint16m1_t neg_bi = __riscv_vneg_v_i16m1(bi, vl);

  vint32m2_t re = __riscv_vwmul_vv_i32m2(ar, br, vl);
  re = __riscv_vwmacc_vv_i32m2(re, ai, neg_bi, vl);
  vint32m2_t im = __riscv_vwmul_vv_i32m2(ar, bi, vl);
  im = __riscv_vwmacc_vv_i32m2(im, ai, br, vl);
  __riscv_vse32_v_i32m2(real, re, vl);
  __riscv_vse32_v_i32m2(imag, im, vl);
}

static inline __attribute__((always_inline))
void sionna_rvv_cmul_conj_q15x8(const int16_t a[16],
                                const int16_t b[16],
                                int32_t real[8],
                                int32_t imag[8])
{
  const size_t vl = __riscv_vsetvl_e16m1(8);
  const vint16m1x2_t av = __riscv_vlseg2e16_v_i16m1x2(a, vl);
  const vint16m1x2_t bv = __riscv_vlseg2e16_v_i16m1x2(b, vl);
  const vint16m1_t ar = __riscv_vget_v_i16m1x2_i16m1(av, 0);
  const vint16m1_t ai = __riscv_vget_v_i16m1x2_i16m1(av, 1);
  const vint16m1_t br = __riscv_vget_v_i16m1x2_i16m1(bv, 0);
  const vint16m1_t bi = __riscv_vget_v_i16m1x2_i16m1(bv, 1);
  const vint16m1_t neg_bi = __riscv_vneg_v_i16m1(bi, vl);

  vint32m2_t re = __riscv_vwmul_vv_i32m2(ar, br, vl);
  re = __riscv_vwmacc_vv_i32m2(re, ai, bi, vl);
  vint32m2_t im = __riscv_vwmul_vv_i32m2(ar, neg_bi, vl);
  im = __riscv_vwmacc_vv_i32m2(im, ai, br, vl);
  __riscv_vse32_v_i32m2(real, re, vl);
  __riscv_vse32_v_i32m2(imag, im, vl);
}

/* Match cpack_256 exactly: arithmetic shift each signed 32-bit component by
 * 15, saturate to signed Q15, then store eight interleaved complex values. */
static inline __attribute__((always_inline))
void sionna_rvv_cpack_q15x8(const int32_t real[8],
                            const int32_t imag[8],
                            int16_t out[16])
{
  const size_t vl = __riscv_vsetvl_e32m2(8);
  const vint32m2_t re32 = __riscv_vle32_v_i32m2(real, vl);
  const vint32m2_t im32 = __riscv_vle32_v_i32m2(imag, vl);
  /* VXRM=RDN (2) makes vnclip's discarded-bit behavior identical to srai. */
  const vint16m1_t re16 = __riscv_vnclip_wx_i16m1(re32, 15, 2, vl);
  const vint16m1_t im16 = __riscv_vnclip_wx_i16m1(im32, 15, 2, vl);
  vint16m1x2_t ri;
  ri = __riscv_vset_v_i16m1_i16m1x2(ri, 0, re16);
  ri = __riscv_vset_v_i16m1_i16m1x2(ri, 1, im16);
  __riscv_vsseg2e16_v_i16m1x2(out, ri, vl);
}

#else
  #define SIONNA_RVV_COMPLEX_AVAILABLE 0
#endif

#endif
