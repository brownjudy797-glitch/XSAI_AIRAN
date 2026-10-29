<!-- SPDX-License-Identifier: Apache-2.0 -->
# 独立 DFT microbench

源码来自 2026-10-29 只读核查的 K3 `benchmarks/dft`。框架直接加载 OAI `libdfts.so`，调用 `dfts_autoinit` 和 `dft_implementation`，不替换 DFT 算法。原始基线 JSON 仍保留在实验机，本次没有上传或重新测量。

## 条件与口径

- seed=42 的低幅度复数 int16 输入、64 字节对齐、scale=1，覆盖 NFFT 128/512/1024/2048，各三轮。
- 先对 FP64 数学 DFT 检查归一化 RMS EVM <= 5%；这只是该输入的初步数值门禁，不等于完整 OAI 正确性验证。
- 每轮 100 次预热、1000 个计时 batch、每 batch 32 次调用，保留计时开销。
- p50/p95/p99 是 batch 平均每次调用时间的分位数，不是单次调用的尾延迟。CPU 周期未测量，不用主频乘时间代替。
- 默认绑 CPU0，记录起止频率；未完成原始 OAI 全幅度门禁、单调用尾部或 PMU 测量。

## 构建和运行

仅在有匹配 OAI 构建产物的独立目录运行，保持正式 gNB 空闲。下面的命令不会安装依赖或重编译 OAI：

```bash
OAI_ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}/ext/openairinterface5g"
OAI_BUILD="${OAI_BUILD:-$OAI_ROOT/cmake_targets/ran_build/build}"
cc -O2 -rdynamic -DT_TRACER bench_dft.c \
  "$OAI_ROOT/common/utils/minimal_stub.c" \
  -Wl,--start-group \
  "$OAI_BUILD/common/utils/LOG/libLOG.a" \
  "$OAI_BUILD/common/utils/T/libT.a" \
  "$OAI_BUILD/libCONFIG_LIB.a" \
  -Wl,--end-group -ldl -lm -lpthread -o bench_dft
```

结果写入新的本地目录，保留每轮源代码和库散列：

```bash
(
set -e
run="$HOME/k3-dft-results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$HOME/k3-dft-results"
mkdir "$run"
python3 run_dft.py > "$run/result.json"
echo "$run/result.json"
)
```

Python 启动器支持 `SIONNA_RK_ROOT` 与 `OAI_BUILD` 环境变量；测试可执行文件从本目录加载。发布前只在 K3 对 C 框架做了 `cc -fsyntax-only`，没有运行新的数值或计时测量。
