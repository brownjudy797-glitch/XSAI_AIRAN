# A DFT correctness repairs — 2026-09-24

These are isolated development changes, not a replacement of the running gNB.
The original A source snapshot and previous regression report remain unchanged.
Follow-up independent FFT audit: see [DFTS_NUMERICS.md](DFTS_NUMERICS.md).

## Root causes and changes

1. Radix-5 passed alternating data/coefficient arguments to a helper expecting
   pairs of data followed by pairs of coefficients. This introduced coefficient
   products even for zero input. Corrected the call ordering in the project kernel.
2. DFT32768 consumed 64 vectors per iteration but iterated 256 times for a
   4096-vector input; changed the bound to 64. Its scaling loop processed only
   1024 of 4096 vectors; changed that bound from 64 to 256. DFT98304 calls this
   function and previously crashed.
3. DFT2304 passes four packed lanes to a single-transform DFT768. It previously
   left most intermediate output uninitialized. An explicit gather/transform/
   scatter helper now transforms all four lanes. This is a correctness-first
   adapter, not a performance optimization.
4. Follow-up numeric audit found incorrect IDFT65536 twiddle offsets in units of
   256-bit vectors. Corrected +4096/+8192 to +2048/+4096; the third old group
   read beyond the 6144-vector twiddle array.

## Verification

`docs/validation/dfts-correctness-result.json` records 89/89 specifications passing
three separate-process runs, each with both scale flags and zero, impulse,
small random and full-range random inputs: 2136 cases. Checks cover process
completion, output canaries, zero preservation and deterministic output hashes.
Unaffected specifications must retain the previous output hash. Expected changes
are restricted to previously zero-anomalous DFTs, DFT2304, DFT98304 and the
subsequently repaired IDFT65536.

`test_dfts_acc8.c` independently compares the Q15 accumulator against scalar
32-bit wrapping arithmetic, arithmetic shift and saturation, including vector tails.
This verifies the helper arithmetic, not the entire radix-5 caller or FFT accuracy.

The follow-up now provides an independent floating-point FFT audit for the
low-amplitude random test pattern. No exhaustive numerical certification,
sanitizer-based input-read bounds verification, performance benchmark, gNB
integration test or RF/E2E test is claimed.

## Reproduction on the current K3 development checkout

Prepare a new absolute directory with `scripts/prepare-oai-worktree.sh DIR
--dfts-adapter`; this now applies both extraction and correctness patches.
The original vendored OAI snapshot is not edited. Kernel modifications live in
`plugins/rvv_phy`; OAI layout fixes live in `patches/k3-A-dfts-correctness.patch`.

The build helper currently uses the recorded K3 paths and original CMake flags;
adjust its source path if preparing a differently named worktree. Run
`scripts/build-dfts-module.py`, then `scripts/check-dfts-correctness.py` with the
runner already produced by the initial full-module harness. The old
`check-dfts-module.py` is a historical equivalence test and is expected to fail
after correcting inherited bugs. `check-dfts-migration.sh` now checks only the
unchanged radix-2 helper; it no longer claims byte-identical complete kernels.

Before-fix binaries and raw outputs are retained on K3 under
`.build/dfts-before-correctness-20260924`; new raw output/logs are under
`.build/dfts-correctness`. No live source, binary, service or baseline hash was
updated as part of this repair.
