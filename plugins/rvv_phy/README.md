# RVV PHY kernels

This directory contains header-only RISC-V Vector kernels owned by Sionna-RK,
not by the vendored OAI source tree.  The public interfaces use fixed-width C
arrays instead of OAI or SIMDe types so they can be reused by future OAI/6G
integrations.

The OAI adapter must always keep its existing SIMDe implementation as the
fallback.  Define `SIONNA_RVV_COMPLEX_DISABLE` to force that fallback for A/B
testing or when diagnosing a compiler regression.

The fast path currently requires GCC 16 or newer and `__riscv_vector`.  On all
other targets `SIONNA_RVV_COMPLEX_AVAILABLE` is zero.

## Integration contract

The kernels accept 8 interleaved complex Q15 values (`I0,Q0,...,I7,Q7`) and
produce separate signed 32-bit real and imaginary arrays.  They deliberately
do not expose OAI structs, generated DFT types, or SIMDe vector types.

The OAI adapter is carried by `patches/openairinterface5g.patch`.  When moving
to a later OAI or 6G tree, keep this directory unchanged and rebase only the
small include and butterfly call-site hunks in that patch.

Run the standalone equivalence test on a RISC-V Vector target with:

```sh
gcc-16 -O3 -Wall -Werror \
  -march=rv64gcv_zba_zbb_zbs -mabi=lp64d -mrvv-vector-bits=scalable \
  -Iplugins/rvv_phy/include plugins/rvv_phy/tests/test_rvv_complex.c \
  -o /tmp/test_rvv_complex
/tmp/test_rvv_complex
```
