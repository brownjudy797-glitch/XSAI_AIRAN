# K3 B210/OAI Optimization Log

## Baseline — 2026-09-03

- Kernel: `6.18.3-k3-sctp+`; `CONFIG_IP_SCTP=m`; SCTP socket verified.
- OAI configuration: NR band 78, SCS 30 kHz, 24 PRB, 7.68 Msps, SISO.
- CPU: 16 cores. CPU 0–7 at 2.15 GHz (A100), CPU 8–15 at 1.8 GHz (X100); userspace governor already holds maximum frequency.
- B210: serial `31EC606`, USB 3.0 at 5 Gbit/s through bus 6.
- UHD baseline: 7.68 Msps RX for 15 seconds, 115,198,319 samples, zero drops, overruns, sequence errors, or timeouts.
- OAI baseline: repeated `ERROR_CODE_OVERFLOW`; requested 7,680 samples and received 5,615. The standalone UHD result isolates the fault to OAI scheduling/processing rather than USB transport.
- Original affinity: L1 RX CPU1, L1 TX CPU2, RU pool CPUs 3–4, RU main CPU5, eight unbound general workers. The B210 xHCI interrupt was also on CPU2, conflicting with L1 TX.
- Network: AMF `192.168.71.132` is reached through Tailscale/DERP; observed RTT roughly 0.4–1.8 seconds. This is unsuitable for final real-time N2/N3 operation and is tracked separately.

## Trial 1 — deterministic CPU/IRQ placement

Changes:

- L1 RX → CPU0; L1 TX → CPU1.
- RU front-end pool → CPUs 2–6 (increased from two workers to five).
- RU main thread → CPU7.
- General OAI worker pool → CPUs 8–15.
- B210 xHCI IRQ → CPU15, away from all L1/RU performance cores.
- `kernel.sched_rt_runtime_us=-1` while starting the gNB.
- Transient service limits: unlimited locked memory, nice -20, unlimited task count.

Rollback:

- Restore the `.pre-k3-opt-*` backups beside each changed project file.
- Restore RT throttling with `sudo sysctl -w kernel.sched_rt_runtime_us=950000`.
- Restore IRQ balancing manually or reboot.

Result:

- The combination of unrestricted RT execution (`sched_rt_runtime_us=-1`) and
  OAI FIFO threads starved Tailscale/SSH. The K3 stopped answering management
  traffic and required local intervention.
- The gNB was stopped locally and `kernel.sched_rt_runtime_us` was restored to
  `950000`. This part of Trial 1 is rejected.
- Tailscale subsequently remained logged out because DNS preferred an unusable
  IPv6 control-plane path. IPv4 `curl` returned HTTP 200. IPv6 was temporarily
  disabled and Tailscale re-authenticated successfully at the original address
  `100.107.188.80`.
- Journal counters from the transient unit were unavailable after recovery, so
  no valid RF overflow comparison is claimed for Trial 1.

## Trial 2 — safe affinity test

Changes retained from Trial 1:

- L1/RU performance-core placement, general worker placement, and xHCI IRQ
  placement.
- RT safety budget explicitly retained at `950000`.
- Every gNB test service now has `RuntimeMaxSec=45` and `TimeoutStopSec=10` so
  it stops automatically even if SSH/Tailscale becomes unavailable.

Observed result (invocation `da1ffdf131224100be2554349df6199a`):

- 283 receive overflows/7,680-sample short reads in the protected 45-second run.
- This is 97% more than Trial 6's 144 events. The X100 service cpuset is
  rejected; `K3_GNB_ALLOWED_CPUS=8-15` is restored.

## Trial 8 — make the intended B200 RX `spp` effective

Source finding:

- `radio/USRP/usrp_lib.cpp` called `get_rx_stream(stream_args_rx)` before
  assigning `stream_args_rx.args["spp"]`. UHD therefore never received OAI's
  intended 100µs packetization setting.
- For 15.36 Msps, the intended value is 1,536 samples per packet.

Change:

- For B200/B210 only, assign `spp=sample_rate/10000` before constructing the RX
  streamer. Other USRP families retain their existing behavior.
- Rebuild only the UHD device backend in the separate RVV build. The original
  source and original OAI build remain available for rollback.

Observed result (invocation `fe68c57fa260493fb5681b4595923a9c`):

- Runtime logging confirmed both requested and effective RX packet size were
  1,536 samples.
- 174 overflows occurred, 21% more than Trial 6's 144. Smaller packets increase
  processing/interrupt overhead on this K3, so the change is rejected and the
  backed-up original source is restored.

## Trial 9 — OAI dedicated USRP TX thread

- Restore CPU8-15 and the original UHD streamer construction.
- Add supported option `--usrp-tx-thread-config 1`, leaving all other settings
  unchanged, to test whether TX/RX separation improves RX scheduling.

Observed result (invocation `f287751e1dce44789a9bc4f8f3e53fdd`):

- OAI created `trx_usrp_write_thread` on CPU15 with priority 97, confirming the
  option was active.
- 152 overflows occurred, 5.6% more than Trial 6. The option is rejected and
  disabled.

## Trial 10 — include the xHCI IRQ CPU in the service cpuset

- USB topology confirms the B210 is at `6-1.2`, 5,000 Mb/s (USB 3), not on the
  Bus 005 USB2 companion.
- IRQ47 is hardware-constrained to CPU0-7 while the best service placement so
  far is CPU8-15. Test `AllowedCPUs=7-15` so CPU7 can handle both xHCI IRQ and
  immediate OAI wakeups, potentially reducing cross-cluster latency.
- Dedicated TX thread remains disabled; all other Trial 6 settings remain.

Result: pending.

Observed result:

- The service cgroup reported `AllowedCPUs=0-15`, but OAI still aborted when
  `pthread_setaffinity_np()` targeted CPU8. The platform permits cgroup-level
  placement on CPUs 8-15 but rejects per-thread `sched_setaffinity()` there.
- No RF streaming or overflow comparison occurred.

## Trial 5 — whole-service A100 cpuset, floating OAI threads

- Place the entire transient service in `AllowedCPUs=8-15`.
- Set L1 RX/TX, RU main, five RU workers, and eight general workers to affinity
  `-1`, preventing OAI from calling the unsupported per-thread affinity API.
- xHCI IRQ and management traffic remain on CPUs 0-7.
- RT budget and 45-second automatic stop remain enabled.

Result: pending.

Observed result:

- OAI ran for the protected 45-second window and stopped cleanly on SIGTERM.
- 146 UHD receive overflows/short reads occurred. Typical half-slot request was
  7,680 samples with only about 5,300-5,630 returned.
- This is about 52% fewer than Trial 3's 302 events, but is still insufficient
  for reliable operation at the configured 15.36 Msps.

## Trial 3 — valid 8-core partition

- L1 RX/TX: CPUs 0 and 1.
- RU front-end pool: CPUs 2, 3, and 4 with `num_tp_cores=3` explicitly set.
- RU main thread: CPU5.
- General worker pool: CPUs 6 and 7.
- B210 xHCI IRQ: CPU7. An earlier request for CPU15 was constrained by the
  platform to CPU7; requested and effective affinity are now made explicit.
- RT budget remains `950000`; 45-second automatic stop remains enabled.

Observed result:

- OAI ran for the protected 45-second window and stopped automatically.
- 302 UHD receive overflows/short reads occurred. This is the comparison
  baseline for Trial 5.

## Trial 4 — opt OAI into all 16 online CPUs

- A transient systemd service could run on CPU8, so the service was allowed on
  CPUs 0-15 and OAI worker threads were explicitly assigned across that range.
- The process aborted safely before RF streaming: OAI's per-thread affinity call
  for CPU8 returned EINVAL even though systemd cgroup placement on CPU8 works.
- Explicit OAI pinning to CPUs 8-15 is rejected; no overflow result is claimed.

## Trial 6 — GCC 15 Release/O3 plus common RVV ISA

Build configuration:

- Separate build directory: `cmake_targets/ran_build_rvv`; the original
  `cmake_targets/ran_build` is retained unchanged for rollback.
- `CFLAGS` and `CXXFLAGS`:
  `-march=rv64gcv_zba_zbb_zbs -mabi=lp64d`.
- OAI Release build (`-O3`), UHD enabled, CUDA/DGX/AVX2/AVX512 disabled.
- Explicit common ISA is used because GCC rejects `-march=native` on this
  heterogeneous K3 CPU topology.

Build result:

- Successful: `nr-softmodem`, `nr-uesoftmodem`, LDPC modules, PHY and RF
  backends all linked. The LDPC translation unit required over 30 minutes at
  `-O3`; GCC variable-tracking messages were informational, not errors.
- Launcher accepts `K3_GNB_BUILD`. Setting it to the RVV directory selects the
  optimized binary; commenting it out immediately restores the original build.
- Runtime verification (flags, linked UHD backend, RVV disassembly and
  protected 45-second overflow count): pending because the K3 Tailscale path
  became unreachable after the build completed.

Runtime verification update (2026-09-04):

- Build flags contain `-O3 -march=rv64gcv_zba_zbb_zbs -mabi=lp64d` and
  disassembly of `libPHY_NR.a` contains RVV instructions including `vsetivli`,
  `vle8.v`, and `vse8.v`. `liboai_device.so` resolves to the UHD backend
  `liboai_usrpdevif.so`.
- The first post-build launch at 10:34 used the original build and is excluded
  from Trial 6: the launcher expanded `K3_GNB_BUILD` before sourcing `.env`.
  The launcher was corrected to resolve the selected build after `load_env`.

Protected runtime result (2026-09-04, invocation
`38054b9166e2445cba5329628a142641`):

- The corrected launcher selected `ran_build_rvv/build`; the gNB initialized at
  15.36 Msps on CPUs 8-15 and ran until the 45-second safety limit.
- 144 `ERROR_CODE_OVERFLOW` events and 144 corresponding 7,680-sample short
  receives occurred. Trial 5 produced 146 events under the same placement.
- The two-event reduction (about 1.4%) is too small to claim a material runtime
  improvement. RVV/O3 is valid and retained as an optional build, but does not
  solve the B210 real-time receive deadline by itself.
- A raw `journalctl -u k3-b200-gnb.service` count includes older invocations and
  must not be used for comparisons; counts are filtered by
  `_SYSTEMD_INVOCATION_ID`.

## Trial 7 — X100 service cpuset with IRQ isolation

- Keep the validated RVV/O3 build, floating OAI thread affinities, RT safety
  budget and 45-second limit unchanged.
- Run the complete gNB service on the higher-frequency X100 CPUs 0-6.
- Keep B210 xHCI IRQ47 on CPU7, outside the service cpuset.
- The launcher now accepts `K3_GNB_ALLOWED_CPUS`; `8-15` restores the Trial 6
  placement without editing the script.

Result: pending.
## GCC 16 and updated system SIMDe rebuild (2026-09-11)

- Installed native RISC-V GCC/G++ 16.0.1 packages while retaining GCC 15 as the system default.
- Rebuilt OAI gNB and nrUE in `cmake_targets/ran_build_rvv/build` with `/usr/bin/gcc-16`, `/usr/bin/g++-16`, and `-march=rv64gcv_zba_zbb_zbs -mabi=lp64d`.
- The build uses the updated headers under `/usr/include/simde`; the generated build tree contains no `simde_bak` reference.
- Verified `nr-softmodem` and `nr-uesoftmodem` were produced successfully.
- Existing launchers still resolve `cmake_targets/ran_build/build`, so that path is now a compatibility symlink to `../ran_build_rvv/build`. This preserves all existing experiment and CN5G launcher paths while selecting the GCC 16 build.

## SIMDe RVV signed pack optimization (2026-09-16)

- Added an RVV-native branch for `simde_mm256_packs_epi32` in the K3 system SIMDe header. OAI algorithm code and interfaces were not changed.
- The implementation uses four `vnclip.wi` operations and preserves AVX2's two independent 128-bit packing lanes.
- Correctness: 100,000 intrinsic-level boundary/random vectors passed; DFT512, IDFT512, DFT2048 and IDFT2048 each passed 100 bit-exact A/B inputs.
- Stable DFT microbenchmark reductions: DFT512 14.66%, IDFT512 15.86%, DFT2048 17.29%, IDFT2048 17.53%.
- RFsim ideal result with delay reuse enabled: RX symbol DFT 243.377 to 200.211 us; TX symbol IDFT 225.557 to 184.954 us; RX FEP 1692.401 to 1405.591 us; TX OFDM 1548.764 to 1270.927 us.
- Reusable patch saved at `/home/ubuntu/sionna-rk/plugins/rvv_phy/patches/simde-avx2-rvv-packs-epi32.patch`; pre-change header, library and object backups are stored under `/tmp` with suffix `before-20260916-packs-rvv`.
- Fixed-VLEN=256 compilation was separately rejected because it produced non-bit-exact DFT512 output. The production build remains `-mrvv-vector-bits=scalable`.
- Full procedure, rollback commands and evidence are recorded in `k3-rfsim-repro/SIMDE_RVV_PACKS_EPI32_OPTIMIZATION_2026-09-16.md`.

### Follow-up: SIMDe RVV `madd_epi16`

- Added a bit-exact RVV `simde_mm256_madd_epi16` implementation on top of the retained `packs_epi32` optimization.
- Intrinsic microbenchmark improved from about 67–69 ns to 49–51 ns per call.
- Additional stable DFT gains over the packs-only build: DFT512 8.52%, IDFT512 6.59%, DFT2048 7.28%, IDFT2048 5.90%.
- RFsim ideal results: RX symbol DFT 186.964 us, TX symbol IDFT 173.844 us, RX FEP 1308.669 us and TX OFDM 1190.682 us. Relative to the pre-packs baseline, the main DFT/FEP figures have improved by about 23% cumulatively.
- Detailed evidence and rollback locations were appended to `k3-rfsim-repro/SIMDE_RVV_PACKS_EPI32_OPTIMIZATION_2026-09-16.md`.

### RU thread-pool off comparison

- Commenting `num_tp_cores=4` and `tp_cores=[0,1,2,3]` selected OAI's default two-worker RU pool (`-1,-1`), not a single-threaded RU.
- Symbol DFT/IDFT and half-slot compute time remained effectively unchanged, confirming the SIMDe gains are computational rather than a thread-count artifact.
- Scheduling totals worsened: RX FEP 1308.669 to 2028.918 us, TX FEP total 1251.015 to 1573.900 us, and L1 TX 1304.168 to 1558.475 us.
- User-selected baseline override: keep the explicit RU settings commented and use OAI's default two-worker unbound RU pool for all subsequent comparisons. The four-worker data remains a historical scheduling comparison only.
- Baseline directory: `/home/ubuntu/sionna-rk/results-no-ru-tp-packs-madd-20260916`. Key baselines are RX symbol DFT 186.795 us, TX symbol IDFT 174.061 us, RX FEP total 2028.918 us, TX FEP total 1573.900 us, and PUSCH channel estimation 415.362 us.

### Rejected generic rearrangement candidates

- Explicit RVV `simde_mm256_shuffle_epi8` was bit-exact over 100,000 arbitrary masks but slowed from 42.307 to 44.815 ns per call; it was not installed.
- Explicit RVV `simde_mm256_unpacklo/hi_epi32` was bit-exact over 100,000 vectors but slowed from 49.128 to 73.238 ns per pair; it was not installed.
- The next optimization boundary is a fused Q15 complex pack operation (`unpack + shift + signed pack`) in the upgrade-safe RVV plugin, not further one-intrinsic rearrangement replacements.

## LDPC CN-processing loop fusion (2026-09-16)

- `perf` on deterministic BG1 R13 decoding identified `nrLDPC_cnProc_BG1_R13_128` as 21.01% of test CPU cycles. Its largest inlined components were `simde_mm_sign_epi8` (7.62%), `simde_mm_abs_epi8` (3.98%) and `simde_mm_min_epu8` (3.77%).
- Selecting OAI's existing 256-bit CN path on RVV was rejected: at four identical decoder iterations it increased mean decoding time from about 2.93 ms to 3.36–3.46 ms (15–18% slower). The production selector and library were restored bit-for-bit.
- The retained optimization changes the BG1 128-bit CN generator rather than generated headers. For degree-5, degree-6 and degree-7 check-node groups, all outgoing edges are emitted in one loop so input vectors and their absolute values are loaded/computed once and reused. Reduction and sign order for each output remains unchanged.
- Deterministic validation used 1,000 identical BG1 R13 vectors: baseline and optimized builds both reported BLER 0/1000, uncoded BER 0.116370 and exactly four mean iterations.
- Mean decode time progressed from 2895.56 us (baseline), to 2768.53 us (degree-5 fused), to 2588.19 us (degree-5/6/7 fused): 10.6% cumulative reduction.
- Source: `/home/ubuntu/sionna-rk/ext/openairinterface5g/openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_tools/generator_cnProc/cnProc_gen_BG1_128.c`.
- Rollback sources: `.pre-fused-g5-20260916` restores the original generator; `.fused-g5` keeps only the first retained stage. Rollback libraries are `libldpc_baseline128.so` and `libldpc_fused-g5-generator.so`; the installed optimized library is also saved as `libldpc_fused-g567.so`.
- The optimized library hash is `2dbf3083e59d41511adecbef175ce00cb20a45d426b822cf097744752b4a5972`.
- Real-B210 restart could not be completed because the device disappeared from K3 USB enumeration (`lsusb` showed no Ettus device and UHD reported `No UHD Devices Found`). This is an external hardware state, not an LDPC validation failure.

## DFT static-mask hoisting (2026-09-16)

- End-to-end RFsim `perf` after the LDPC change showed that DFT/IDFT had become the dominant gNB hotspot: the two worker entries for `idft64` totalled about 25.2%, followed by `idft1024` (11.7%), `idft256` (11.3%), `dft64` (9.8%) and `idft2048` (7.8%). The optimized LDPC CN function was only about 2.4% in this workload.
- `oai_dfts.c` repeatedly constructed identical 256-bit byte-shuffle and 32-bit permutation constants inside hot DFT helpers. These `simde_mm256_set_epi8/set_epi32` expressions were replaced with aligned, file-scope read-only masks loaded through SIMDe. The algorithm, public interfaces and scalable-VLEN build remain unchanged.
- A standalone dual-library harness compared the pre-change and optimized libraries for DFT/IDFT sizes 64, 256, 1024 and 2048. Every output was byte-for-byte identical. Forward and reversed benchmark order produced consistent results.
- Representative single-core improvements: DFT64 13.6%, IDFT64 11.3%; DFT256 12.7%, IDFT256 9.4%; DFT1024 10.4%, IDFT1024 6.9%; DFT2048 8.4%, IDFT2048 5.7%.
- Optimized library: `/home/ubuntu/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build/libdfts.so`, SHA-256 `649c4cf94ebeb351b83c8806d72f52acf0ae48dfa0c98c3b8b26a244d034a981`.
- Rollback library: `libdfts.pre-static-mask-20260916.so`, SHA-256 `da6d0b6a92eb5d75fefebf46f67a8e7441ca40b8c4095e6fea4095c29e4aa25d`.
- RFsim regression passed with CPUs 0-7 and explicit four-core RU settings still disabled: nrUE synchronized, both processes remained alive, gNB continuously reported the UE `in-sync`, and no assertion/fatal/segmentation marker appeared. Evidence: `/home/ubuntu/sionna-rk/results-rfsim-dft-static-mask-20260916/manual-run1`.

## Fused RVV Q15 complex packing and fixed RFsim launcher contract (2026-09-16)

- Added `sionna_rvv_cpack_q15x8` to the upgrade-isolated RVV helper header and routed `cpack_256` through it only when `SIONNA_RVV_COMPLEX_AVAILABLE` is true. Other architectures retain the original SIMDe sequence.
- The fused kernel replaces two 32-bit unpacks, two arithmetic shifts, signed saturation/packing and final interleaving with two RVV loads, two `vnclip` operations using VXRM=RDN and one segmented store.
- Dual-library tests compared the static-mask library with the fused candidate for DFT/IDFT sizes 64, 256, 1024 and 2048. Every output was byte-for-byte identical. Candidate microbenchmark gains over static-mask were 6.8%/8.8% (DFT/IDFT64), 6.6%/10.0% (256), 8.1%/11.4% (1024), and 6.7%/8.5% (2048).
- Standard RFsim runs 1 and 2 accidentally omitted `SIONNA_PUSCH_DELAY_REUSE`; they are valid for DFT/FEP stability but not for comparison of PUSCH channel estimation. This changed delay-search IDFT from once to three times per PUSCH and raised channel estimation to about 695 us.
- Both hotspot launchers now pass `SIONNA_PUSCH_DELAY_REUSE=1` explicitly to the transient gNB service and record `pusch_delay_reuse=enabled` in metadata. The experiment no longer depends on a login-shell environment variable.
- Corrected standard run 3 (120-second difference window, CPUs 0-7, default two-worker RU pool) produced: RX FEP 1699.309 us, RX symbol DFT 159.557 us, TX FEP 1325.917 us, TX symbol IDFT 149.258 us, PUSCH inner receiver 544.674 us, PUSCH channel estimation 393.241 us, UL segments decoding 747.566 us, and UE DLSCH decoding 1207.601 us.
- Relative to `/home/ubuntu/sionna-rk/results-no-ru-tp-packs-madd-20260916`, corrected run 3 improved RX FEP by 15.3%, TX FEP by 16.0%, RX DFT by 14.4%, TX IDFT by 14.1%, PUSCH inner receiver by 11.6%, PUSCH channel estimation by 6.1%, and UE DLSCH decoding by 9.6%.
- Evidence directory: `/home/ubuntu/sionna-rk/results-rfsim-cpack-fused-20260916`; the authoritative corrected result is `ideal-run3-window-stats.csv`. Runs 1 and 2 must not be used for PUSCH comparisons.
- Static-mask rollback library: `/home/ubuntu/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build/libdfts.static-mask-20260916.so` (SHA-256 `649c4cf94ebeb351b83c8806d72f52acf0ae48dfa0c98c3b8b26a244d034a981`). Pre-static-mask rollback remains `libdfts.pre-static-mask-20260916.so`.
- Final fused library is also frozen as `libdfts_fused-cpack-final.so`; it is identical to installed `libdfts.so` (SHA-256 `755e62abd55280a0f196b3512a4b7e51e1af792125f88d0cf4437c176efa7550`). Final source snapshots are `oai_dfts.c.fused-cpack-final` and `plugins/rvv_phy/include/sionna_rvv_complex.h.fused-cpack-final`.

### Fixed optimization order and acceptance rule

1. gNB RX FEP.
2. gNB L1 TX/OFDM.
3. nrUE DLSCH decoding.
4. gNB PUSCH inner receiver.
5. gNB UL segments decoding.

For every retained change: locate its child hotspot, prove bit-level or functional correctness, run the same 120-second ideal-RFsim snapshot-difference experiment, and compare against the fixed default-two-worker baseline. `perf` is diagnostic evidence only and never replaces the module-level experiment.

## Final BG1 128-bit CN fusion and Top-5 validation (2026-09-16)

- UE process profiling showed `nrLDPC_cnProc_BG1_R13_128` spread across eight decoder workers (about 7.3% aggregate CPU samples) and `bnProcPc` at about 3%. The retained generator already fused degree 5/6/7 groups; R13 group counts showed additional useful low-pressure groups at degrees 4, 8, 9 and 10. Degree 19 was deliberately not fused because retaining inputs plus absolute values would exceed the safe vector-register budget and invite spills.
- Added generator-level fusion for degrees 4, 8, 9 and 10. This keeps the OAI decoder interface and generated-header workflow intact and reuses loads/absolute values across all outgoing edges. Non-RISC-V behavior and the LDPC graph are unchanged.
- Fixed-seed A/B tests used 1,000 identical BG1 R13 vectors. At every stage BLER, uncoded BER and mean iteration count were identical. Degree 8 reduced mean decode time by about 1.9-2.2%, degree 9 by 2.6-2.7%, and degree 10 by 1.7-2.2%. Degree 4 was smaller (roughly 0.5-0.9%) but repeatable in the aggregate and retained.
- Final generator: `/home/ubuntu/sionna-rk/ext/openairinterface5g/openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_tools/generator_cnProc/cnProc_gen_BG1_128.c`, SHA-256 `8873edbc850c34abb16927f7df7498097740c1db22c190b374d4b0e42ec60881`. A final source snapshot is stored beside it as `.fused-g45678910-final`.
- Final library: `/home/ubuntu/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build/libldpc.so`, SHA-256 `f652a912afc099f4f70c046b8b9aa8e44fe771ff09c715034914811ae7e7c964`; identical retained copy: `libldpc_fused-g45678910.so`.
- Incremental rollback libraries are `libldpc_fused-g567-before-g4.so` (SHA-256 `2dbf3083...`), `libldpc_fused-g45678.so` (`019d4801...`) and `libldpc_fused-g456789.so` (`f91d38d0...`). The original pre-fusion generator and baseline library remain recorded in the earlier LDPC section.
- The final generator target rebuilt with no warnings. The temporary fixed random seed was removed from `ldpctest.c` after A/B testing.

### Final standard RFsim result

- Evidence: `/home/ubuntu/sionna-rk/results-rfsim-ldpc-g45678910-20260916/ideal-run1-window-stats.csv` and `ideal-run2-window-stats.csv`.
- Both 120-second runs synchronized on the first attempt, used CPUs 0-7, retained the default two-worker RU pool, explicitly enabled PUSCH delay reuse, and reproduced the same performance.
- Authoritative run 2 versus `/home/ubuntu/sionna-rk/results-no-ru-tp-packs-madd-20260916`:
  - gNB RX FEP: 2005.355 to 1696.204 us (15.4% faster).
  - gNB TX FEP: 1578.780 to 1323.475 us (16.2% faster); L1 TX total: 1568.145 to 1368.174 us (12.8% faster).
  - nrUE DLSCH procedure: 1414.687 to 1210.901 us (14.4% faster); DLSCH decoding: 1335.738 to 1132.563 us (15.2% faster); LDPC decoding: 1158.355 to 1026.697 us (11.4% faster).
  - gNB PUSCH inner receiver: 616.331 to 541.481 us (12.1% faster); channel estimation: 418.391 to 390.468 us (6.7% faster).
  - gNB UL segments decoding: 755.645 to 678.130 us (10.3% faster); UL CN processing: 142.984 to 120.947 us (15.4% faster).
- DLSCH encoding remained neutral (339.086 to 338.405 us), so no unproven encoder-specific change was added.
