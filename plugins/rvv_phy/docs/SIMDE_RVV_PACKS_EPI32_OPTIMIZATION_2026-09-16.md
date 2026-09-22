# K3 SIMDe `packs_epi32` RVV 优化记录

日期：2026-09-16  
目标平台：K3，RISC-V 64，RVV，硬件 VLEN=256  
编译器：GCC 16.0.1  
OAI提交：`207aac94d1`  
CPU约束：所有编译与测试仅使用CPU 0–7；CPU 8–15不用于本实验  
信道：RFsim ideal；未使用AWGN

## 1. 背景与结论

OAI的2048点DFT/IDFT大量使用SIMDe模拟AVX2。反汇编显示，真正的向量乘加指令较少，大量时间花在向量配置、数据抽取、重排和压缩上。其中 `simde_mm256_packs_epi32` 没有RISC-V专用分支，通用实现被GCC 16展开为逐元素提取、上下界比较、分支和写回。

本次仅在SIMDe的RISC-V分支中实现AVX2 `packs_epi32` 语义：使用RVV `vnclip.wi` 将32位有符号整数饱和压缩为16位，同时保持AVX2按两个128位子通道分别打包的输出顺序。没有修改OAI算法和函数接口。

验证结论：修改正确且具有稳定收益，可以保留。2048点DFT/IDFT微基准提升约17%，RFsim中的单符号DFT/IDFT及FEP整体下降约17%–18%。

## 2. 修改位置

K3当前生效文件：

```text
/usr/include/simde/x86/avx2.h
```

修改函数：

```c
simde_mm256_packs_epi32(simde__m256i a, simde__m256i b)
```

新增分支：

```c
#elif defined(SIMDE_RISCV_V_NATIVE)
```

实现要点：

- 分别读取 `a`、`b` 的低四个和高四个32位元素；
- 使用 `__riscv_vnclip_wx_i16mf2(..., 0, 0, vl)` 完成有符号饱和窄化；
- 输出顺序保持为 `a[0:4], b[0:4], a[4:8], b[4:8]`，对应AVX2的128位子通道语义；
- 显式传递GCC 16所要求的VXRM参数；移位量为0，因此舍入模式不改变数值结果。

可复用补丁：

```text
/home/ubuntu/sionna-rk/plugins/rvv_phy/patches/simde-avx2-rvv-packs-epi32.patch
```

## 3. 备份与回滚

修改前备份：

```text
/tmp/avx2.h.before-20260916-packs-rvv
/tmp/libdfts.before-20260916-packs-rvv.so
/tmp/oai_dfts.before-20260916-packs-rvv.o
```

需要回滚时执行：

```bash
cp -p /tmp/avx2.h.before-20260916-packs-rvv /usr/include/simde/x86/avx2.h
cp -p /tmp/libdfts.before-20260916-packs-rvv.so \
  /home/ubuntu/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build/libdfts.so
cp -p /tmp/oai_dfts.before-20260916-packs-rvv.o \
  /home/ubuntu/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build/CMakeFiles/dfts.dir/openair1/PHY/TOOLS/oai_dfts.c.o
```

若回滚头文件后还要重新构建DFT库，必须只使用CPU 0–7：

```bash
cd /home/ubuntu/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build
touch /home/ubuntu/sionna-rk/ext/openairinterface5g/openair1/PHY/TOOLS/oai_dfts.c
taskset -c 0-7 make -j8 dfts
```

## 4. 验证过程

### 4.1 单函数正确性

测试 `simde_mm256_packs_epi32` 共100000组输入，包括：

- `INT32_MIN`、`INT32_MAX`；
- `-32769`、`-32768`、`32767`、`32768`；
- 全宽随机32位输入。

结果：全部通过，输出与AVX2定义的有符号饱和及子通道顺序逐位一致。

### 4.2 单函数反汇编与微基准

| 指标 | SIMDe通用实现 | RVV实现 |
|---|---:|---:|
| `run_pack`反汇编行数 | 335 | 170 |
| 标量向量元素抽取 `vmv.x.s` | 16 | 0（核心实现） |
| 饱和上下界分支 | 32 | 0（核心实现） |
| `vnclip.wi` | 0 | 4 |
| 运行时间 | 162–171 ns/次 | 44–46 ns/次 |

微基准通过易变函数指针并使用 `-fno-ipa-cp`，防止GCC针对固定输入进行跨过程常量传播。

### 4.3 DFT/IDFT A/B

基线库：

```text
/tmp/libdfts.scalable.so
```

候选库：

```text
/tmp/libdfts.packs-rvv.so
```

两个共享库用 `RTLD_DEEPBIND` 隔离，避免同名DFT子函数和全局旋转因子发生ELF符号抢占。每个函数验证100组输入，覆盖常用无线信号幅度、完整16位随机值及极值。

第二轮稳定结果：

| 函数 | 基线 | RVV `packs` | 提升 |
|---|---:|---:|---:|
| DFT512 | 51.583 μs | 44.021 μs | 14.66% |
| IDFT512 | 49.015 μs | 41.243 μs | 15.86% |
| DFT2048 | 237.030 μs | 196.052 μs | 17.29% |
| IDFT2048 | 226.284 μs | 186.607 μs | 17.53% |

所有输出逐位一致。

### 4.4 RFsim热点实验

实验配置：RFsim ideal、启用 `SIONNA_PUSCH_DELAY_REUSE=1`、预热10秒、测量30秒、CPU 0–7。

结果目录：

```text
/home/ubuntu/sionna-rk/results-packs-rvv-20260916
```

与2026-09-15同配置方向的优化前热点记录比较：

| 热点 | 修改前 | 修改后 | 变化 |
|---|---:|---:|---:|
| RX单符号DFT | 243.377 μs | 200.211 μs | -17.74% |
| TX单符号IDFT | 225.557 μs | 184.954 μs | -18.00% |
| RX FEP | 1692.401 μs | 1405.591 μs | -16.95% |
| RX半时隙FEP任务 | 1646.567 μs | 1361.376 μs | -17.32% |
| TX OFDM | 1548.764 μs | 1270.927 μs | -17.94% |
| TX FEP总计 | 1610.299 μs | 1330.483 μs | -17.38% |
| PUSCH信道估计 | 462.456 μs | 419.486 μs | -9.29% |

PUSCH内部的IDFT/时延搜索从约231.541 μs降到191.327 μs。实验结束后确认无gNB或nrUE进程残留。

## 5. 已否决的方案

固定VLEN=256构建参数：

```text
-march=rv64gcv_zba_zbb_zbs_zvl256b -mrvv-vector-bits=zvl
```

虽然它减少部分 `vset` 和gather，但会定义 `__riscv_v_fixed_vlen=256`，从而关闭当前SIMDe中的若干GCC16/RVV快速路径。DFT512逐位一致性测试失败，因此已经否决。正式构建继续使用：

```text
-mrvv-vector-bits=scalable
```

## 6. 后续维护要求

- OAI升级时不直接手工重写 `oai_dfts.c`；优先重新应用项目内SIMDe补丁。
- SIMDe升级后先运行 `patch --dry-run`。若补丁已被上游实现覆盖，应检查上游反汇编和性能，不要重复应用。
- GCC或SIMDe版本改变后必须重跑：单函数边界测试、DFT逐位A/B、DFT微基准和RFsim热点实验。
- 不能只根据源码中出现RVV intrinsic判断优化成功，必须检查最终反汇编。
- 后续候选目标为 `simde_mm256_madd_epi16`，但必须沿用本次的真实头文件命中检查与三层验证流程。

## 7. 后续追加：`madd_epi16` RVV优化

同日继续为 `simde_mm256_madd_epi16` 增加RVV分支。该函数对应AVX2 `PMADDWD`：相邻两组16位有符号乘积相加，以32位环绕语义输出。

实现使用4次 `vlse16.v` 直接读取偶数/奇数通道，再使用 `vwmul.vv + vwmacc.vv` 形成8个32位结果，避免通用实现的“16路扩宽乘法后再gather偶/奇项”。本次测试明确使用 `<x86/avx2.h>` 和候选目录，编译日志及反汇编均确认命中候选头文件。

单函数结果：

- 100000组随机、极值及32位求和溢出用例全部逐位一致；
- 基线约67–69 ns/次；RVV版本约49–51 ns/次；
- 稳定提升约24%–27%。

在已有 `packs_epi32` 优化基础上的第二轮DFT结果：

| 函数 | 仅packs | packs+madd | 追加提升 |
|---|---:|---:|---:|
| DFT512 | 43.834 μs | 40.101 μs | 8.52% |
| IDFT512 | 41.009 μs | 38.306 μs | 6.59% |
| DFT2048 | 196.514 μs | 182.208 μs | 7.28% |
| IDFT2048 | 187.319 μs | 176.258 μs | 5.90% |

每个函数再次使用100组不同范围输入做隔离动态库A/B，全部逐位一致。

RFsim ideal、延迟复用开启、预热10秒、测量30秒的结果目录：

```text
/home/ubuntu/sionna-rk/results-packs-madd-rvv-20260916
```

| 热点 | 仅packs | packs+madd | 追加变化 | 相对最初基线累计变化 |
|---|---:|---:|---:|---:|
| RX单符号DFT | 200.211 μs | 186.964 μs | -6.62% | -23.18% |
| TX单符号IDFT | 184.954 μs | 173.844 μs | -6.01% | -22.93% |
| RX FEP | 1405.591 μs | 1308.669 μs | -6.90% | -22.67% |
| TX OFDM | 1270.927 μs | 1190.682 μs | -6.31% | -23.12% |
| PUSCH信道估计 | 419.486 μs | 408.616 μs | -2.59% | -11.64% |

追加修改前备份：

```text
/tmp/avx2.h.before-20260916-madd-rvv
/tmp/libdfts.before-20260916-madd-rvv.so
/tmp/oai_dfts.before-20260916-madd-rvv.o
```

可复用补丁目标路径：

```text
/home/ubuntu/sionna-rk/plugins/rvv_phy/patches/simde-avx2-rvv-madd-epi16.patch
```

## 8. RU多核关闭对照实验

将RFsim配置中的下列两行注释：

```ini
# num_tp_cores = 4;
# tp_cores = [0, 1, 2, 3];
```

OAI没有退化为单工作线程，而是自动选择：

```text
RU thread-pool core string -1,-1 (size 2)
```

即2个未绑定RU工作线程。实验仍采用RFsim ideal、延迟复用开启、预热10秒、测量30秒、gNB和nrUE均限制在CPU 0–7。结果目录：

```text
/home/ubuntu/sionna-rk/results-no-ru-tp-packs-madd-20260916
```

与显式4工作线程配置的 `packs+madd` 实验比较：

| 指标 | RU显式4线程 | 注释后默认2线程 | 变化 |
|---|---:|---:|---:|
| RX单符号DFT | 186.964 μs | 186.795 μs | 基本不变 |
| TX单符号IDFT | 173.844 μs | 174.061 μs | 基本不变 |
| RX半时隙FEP任务 | 1262.718 μs | 1263.808 μs | 基本不变 |
| RX FEP总计 | 1308.669 μs | 2028.918 μs | 增加55.04% |
| TX OFDM计算 | 1190.682 μs | 1189.953 μs | 基本不变 |
| TX FEP总计 | 1251.015 μs | 1573.900 μs | 增加25.81% |
| L1 TX处理 | 1304.168 μs | 1558.475 μs | 增加19.50% |
| PUSCH信道估计 | 408.616 μs | 415.362 μs | 增加1.65% |

结论：SIMDe/RVV内核的单次计算性能与RU线程数量无关，优化收益仍然成立；但默认2线程明显增加任务排队、派发和等待时间，使FEP总时间恶化。因此K3当前实验应保留 `num_tp_cores=4`。由于进程仍缺少 `SYS_NICE`，`tp_cores=[0,1,2,3]` 是OAI目标配置，但线程亲和性未被内核强制应用。

### 正式基线约定（用户确认）

后续实验不恢复显式4线程配置，以注释RU多核设置后的默认配置作为正式基线。前一段“应保留4线程”仅代表性能对照结论，不再作为后续实验配置要求。

正式基线配置：

```ini
# num_tp_cores = 4;
# tp_cores = [0, 1, 2, 3];
```

OAI实际行为：

```text
RU thread-pool core string -1,-1 (size 2)
```

正式基线结果目录：

```text
/home/ubuntu/sionna-rk/results-no-ru-tp-packs-madd-20260916
```

后续SIMDe、DFT和FEP优化均与以下数据比较：RX单符号DFT 186.795 μs、TX单符号IDFT 174.061 μs、RX FEP总计2028.918 μs、TX FEP总计1573.900 μs、PUSCH信道估计415.362 μs。实验继续使用RFsim ideal、`SIONNA_PUSCH_DELAY_REUSE=1`、预热10秒、测量30秒，并将gNB和nrUE进程限制在CPU 0–7。

## 9. 后续通用重排候选测试

以默认2线程RU正式基线继续检查两类通用SIMDe重排函数，但均未安装：

1. `simde_mm256_shuffle_epi8`：显式RVV实现通过100000组任意掩码、128位子通道和最高位清零语义测试，但微基准由42.307 ns增加到44.815 ns，约慢5.9%。GCC16现有快速路径已经生成一次 `vrgather + merge`，显式实现额外增加 `vid/and/or`准备开销。
2. `simde_mm256_unpacklo_epi32`和`simde_mm256_unpackhi_epi32`：分段加载/分段存储实现通过100000组逐位测试，但一对lo/hi调用由49.128 ns增加到73.238 ns，约慢49.1%。RVV tuple构造和两段128位语义处理的成本高于GCC现有固定shuffle。

结论：继续逐条替换通用重排intrinsic已经没有收益。下一阶段应融合OAI当前连续出现的 `unpack + arithmetic shift + signed packs`，让32位实部/虚部直接变成最终交错Q15复数输出，跨越SIMDe单指令语义边界。融合实现应位于 `plugins/rvv_phy`，OAI只保留薄调用与原SIMDe回退。
