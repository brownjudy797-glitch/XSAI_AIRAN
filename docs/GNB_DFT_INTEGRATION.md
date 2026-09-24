# Isolated gNB / DFT integration

## Verified result — 2026-09-24

All checks below passed on K3, without running the modem main or replacing the
live installation:

- Fresh gNB, DFT and libconfig-module build: exit 0, 1934.61 seconds (~32 minutes).
- Provenance audit: 12330 compile-database entries inspected, no live/legacy
  source references; extracted adapter/kernel dependency confirmed.
- Native OAI loader probe: loaded the isolated `libdfts.so`; DFT64 and IDFT64
  impulse checks passed against the actual gNB link dependencies.
- Fresh CMake DFT regression: 89/89 sizes, 712 cases, byte-identical outputs to
  the module covered by the independent FFT numerical audit.

Artifact SHA-256:

```text
nr-softmodem  8c3d34cfe549cee1f2790efbec9cc89947133d8c5212bf7e2864b36e78d51073
libdfts.so   9d8df237956c2a8b154618a3466ceffec424ddb90cb474d88de615eb2e3d0f02
```

The original live `oai_dfts.c` and `oai_dfts_rvv.h` remain unchanged. The new
executables are development artifacts, not a deployed replacement.

## Boundary

The gNB uses OAI's `load_dftslib()` and `load_module_shlib()` to load `libdfts.so`
and resolve `dft_implementation` / `idft_implementation`. A successful gNB link
alone therefore does not prove that the corrected DFT module is selected.

The integration check has three parts:

1. Configure and compile the prepared OAI snapshot in `.build/gnb-integration`.
   No old object directory or live `ext` source is used. GCC 16 and the K3 RVV
   flags are explicit. Build concurrency is four at nice level 15.
2. Audit the recorded compiler inputs and DFT header dependencies. Reject live
   `ext/openairinterface5g` or `_bak` references; verify the adapter and project
   kernel appear in the compiler dependency file, DFT entrypoints are exported,
   and the gNB's immediate dynamic dependencies resolve.
3. Link a dedicated test main with the actual gNB objects and libraries. A copied
   gNB main object has only its `main` symbol renamed. The new test does not call
   that function. It calls the native OAI DFT loader, verifies the absolute path
   of the function's shared library with `dladdr`, and checks DFT64/IDFT64 impulse
   outputs. No logging/config/DFT implementation stubs are used by this probe.

## Commands

On K3, from the publication checkout, use a prepared, isolated source tree:

```sh
bash scripts/configure-gnb-integration.sh /absolute/prepared/oai
python3 scripts/build-gnb-integration.py
python3 scripts/audit-gnb-integration.py
python3 scripts/check-gnb-dfts-loader.py
python3 scripts/check-gnb-dfts-regression.py
```

These commands do not install artifacts, invoke the gNB main program, discover
radio devices, change system libraries, restart services or update baseline hashes.
`OAI_SIMU` and RF-emulator support may be compiled as existing build features;
no simulation or RF experiment is run by these checks.

## Evidence

Build commands, return code, duration and output hashes are recorded in
`.build/gnb-integration/integration-build.json`, with the compiler log beside it.
The source/dependency audit is `integration-audit.json`. The native-loader probe
records its command list, log and result in `loader-probe/`.

Published evidence:

- `docs/validation/gnb-integration-build.json`
- `docs/validation/gnb-integration-audit.json`
- `docs/validation/gnb-dfts-loader-result.json`
- `docs/validation/gnb-dfts-regression-result.json`

The fresh-library regression uses the full-module runner produced in the earlier
DFT test setup, and compares against the checked-in correctness result hashes.
It is an additional bridge to the numeric audit, not a second independent oracle.

## Existing warnings and limitations

The full build emitted warnings in unchanged A code: SCTP `inet_pton` destination
buffer size, potentially uninitialized Viterbi metrics and RRC `ssbFrequency0`,
and misleading indentation in `nr-gnb.c` timing output. They did not fail the
build and are not silently fixed as part of this architecture step. They require
separate review before deployment; a successful build is not a safety certification.
The standalone materialized source has no Git metadata, so CMake's version
queries also emitted `not a git repository`; source hashes provide provenance.

Only completed results should be published under `docs/validation` and described
as passed. A build that is still running or has failed is not an integration pass.
This test is not RF/E2E validation, throughput benchmarking, a deployment, or
proof that every runtime-loaded radio plugin is available.
