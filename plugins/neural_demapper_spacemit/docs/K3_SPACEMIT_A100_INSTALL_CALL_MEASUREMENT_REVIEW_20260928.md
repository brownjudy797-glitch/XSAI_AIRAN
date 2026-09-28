# K3 SpaceMIT 库安装、A100 调用与测量复盘

记录日期：2026-09-28

如果目标是“安装完成后马上跑起来”，先看
[K3_SPACEMIT_AFTER_INSTALL_QUICKSTART.md](K3_SPACEMIT_AFTER_INSTALL_QUICKSTART.md)。
本文用于解释完整原理、调用链和测量口径，不作为第一份操作手册。

## 1. 整条链路是什么

```text
OAI PUSCH 接收
  -> 信道补偿后的 IQ/magnitude
  -> demapper 插件 ABI
  -> RVV 归一化并形成 FP16 [N,2]
  -> ONNX Runtime Session::Run
  -> SpaceMIT Execution Provider
  -> A100 worker（CPU8-15）执行 2->32->32->4 MLP
  -> FP16 [N,4]
  -> RVV 转 int16 LLR（当前 K3 scale=8）
  -> OAI unscramble / LDPC
```

插件替换的是 `nr_ulsch_compute_llr()` 之后对应的神经解调计算边界，不替换
FFT、信道估计、资源提取或 LDPC。模型沿用 Spark 的 FP16 MLP：输入
`[N,2]`，三层为 `2→32→32→4`，共 1284 个参数。

## 2. SpaceMIT 库是怎么安装的

### 2.1 已核验的历史安装命令

K3 的 `/var/log/apt/history.log` 记录：

```text
Start-Date: 2026-09-27 12:35:11
Commandline: apt-get install -y spacemit-onnxruntime python3-spacemit-ort
Install: spacemit-onnxruntime:riscv64 (2.0.3+3),
         python3-spacemit-ort:riscv64 (2.0.3+3),
         spacemit-tcm:riscv64 (3.0.0+3, automatic)
```

也就是说，明确执行过的安装命令是：

```sh
sudo apt-get update
sudo apt-get install -y spacemit-onnxruntime python3-spacemit-ort
```

`spacemit-tcm` 是自动依赖，不是本项目手工编译安装。软件源已经配置在：

```text
/etc/apt/sources.list.d/spacemit-ubuntu-k3-resolute.sources
URIS: https://ppa.launchpadcontent.net/spacemit/k3/ubuntu
```

当前 `apt-cache policy` 显示三个包都来自该 PPA 的 `resolute/main riscv64`，
pin priority 为 1100。这里没有反推软件源最初是如何加入系统的；只记录已经
核验到的当前配置与历史安装命令。

### 2.1.1 现场终端输出复核

用户保存的完整安装输出进一步确认：

- `apt-get update` 同时命中 Ubuntu `resolute` 软件源和 SpaceMIT K3 PPA；
- apt 明确列出 `python3-spacemit-ort`、`spacemit-onnxruntime` 和
  `spacemit-tcm` 为三个新安装包；
- 下载量约 33.0 MB，安装后新增磁盘占用约 131 MB；
- 三个包的架构均为 `riscv64`；
- 最后依次出现三个包的 `Setting up ...`，说明 dpkg 配置阶段完成；
- 没有服务、容器或用户会话需要重启，运行内核也被判断为最新。

下载过程中 `python3-spacemit-ort` 和 `spacemit-onnxruntime` 曾显示一次
`Ign`，但 apt 随后重新执行 `Get` 并完成下载、解包和 `Setting up`。这属于
下载重试，不能判为安装失败。

最后的：

```text
ldconfig: /lib/libethercat.so.1 is not a symbolic link
```

是系统中已有 EtherCAT 动态库的符号链接布局警告，不属于 SpaceMIT 包的安装
错误，也没有阻止 `libspacemit_ep`、`libonnxruntime` 和 `libspine_tcm` 注册。

### 2.2 安装后关键文件

| 内容 | 文件/版本 |
|---|---|
| SpaceMIT EP | `/lib/libspacemit_ep.so.2`，provider 2.0.3 |
| ONNX Runtime | `/lib/libonnxruntime.so.1` |
| C++ 公共入口 | `/usr/include/spacemit_ort_env.h` |
| TCM runtime | `/lib/libspine_tcm.so.3`，3.0.0 |
| TCM 状态工具 | `/usr/bin/spacemit-tcm-smi` |

公开头文件只提供：

```cpp
Ort::Status Ort::SessionOptionsSpaceMITEnvInit(
    Ort::SessionOptions &options,
    const std::unordered_map<std::string, std::string> provider_options = {});
```

没有找到对应用开放的持久 executor、预编译子图直接加载、异步 submit 或
fused MLP 稳定 ABI。因此当前实现没有调用库内私有符号。

## 3. K3 上的 A100 到底是什么

K3 是 16 核异构 CPU：

| 核簇 | Linux CPU | 最高频率 | 用途 |
|---|---|---:|---|
| X100 | 0–7 | 2.15 GHz | OAI 主流程、插件预处理/后处理 |
| A100 | 8–15 | 1.80 GHz | SpaceMIT EP 的 AI/matrix worker |

A100 在这里不是 NVIDIA A100 GPU，而是 K3 SoC 的 AI 核簇。Linux 仍把它们
呈现为 CPU8–15，但厂商 EP 会在这些核上使用相应的矩阵/AI 执行能力。

### 3.1 旧路径：整个进程切到 A100

早期纯 RVV 插件通过 `tools/run_on_k3_a100.c` 向 `/proc/set_ai_thread` 写入
当前 PID，再执行目标程序。这条路径要求 launcher 用 `-march=rv64gc` 编译，
必须在任何 RVV 指令运行前完成 AI thread 切换：

```sh
gcc-16 -O2 -Wall -Wextra -Werror -march=rv64gc -mabi=lp64d \
  tools/run_on_k3_a100.c -o build/run_on_k3_a100
build/run_on_k3_a100 taskset -c 8 COMMAND [ARG...]
```

这会让整个目标进程运行在 A100 核簇。实测对 OAI 通用控制流并不划算，故不再
作为当前架构。

### 3.2 当前路径：OAI 留在 X100，EP worker 使用 A100

当前插件创建 ORT 环境和 SessionOptions，把线程配置交给官方 EP：

```cpp
Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "spark-demapper");
Ort::SessionOptions options;
std::unordered_map<std::string, std::string> ep_options{
  {"SPACEMIT_EP_INTRA_THREAD_NUM", "8"},
  {"SPACEMIT_EP_INTRA_THREAD_AFFINITY", "8;9;10;11;12;13;14;15"},
  {"SPACEMIT_EP_INTER_THREAD_NUM", "1"},
  {"SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD", "1"},
};
Ort::SessionOptionsSpaceMITEnvInit(options, ep_options);
Ort::Session session(env, model_path, options);
session.Run(...);
```

项目通过以下环境变量生成这些 provider options：

```sh
export XSAI_SPACEMIT_EP_THREADS=8
export XSAI_SPACEMIT_EP_AFFINITY='8;9;10;11;12;13;14;15'
export XSAI_SPACEMIT_EP_STREAMS=1
export XSAI_SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD=1
```

因此测试命令中的 `taskset -c 0` 只是把 host benchmark 固定在 X100 CPU0；
模型计算仍由 EP 建立并绑定在 CPU8–15 的 A100 worker 执行。两层 affinity
控制的是不同线程，不能只看 `taskset` 就判断“没有调用 A100”。

## 4. 插件怎么编译和加载

### 4.1 编译

`tools/build_spacemit_ep_k3.sh` 的关键编译参数是：

```sh
g++ -O3 -funroll-loops -fPIC -shared \
  -march=rv64gcv_zba_zbb_zbs_zfhmin_zvfh -mabi=lp64d \
  -mrvv-vector-bits=scalable \
  tests/demapper_spacemit_ep.cpp \
  -lonnxruntime -lspacemit_ep -lpthread -ldl \
  -DSPARK_LLR_SCALE=8 \
  -o build/libdemapper_spacemit_ep_scale8.so
```

RVV 用于 host 端的输入归一化和输出量化；`libspacemit_ep` 负责模型在 A100
worker 上的执行。

### 4.2 初始化和每次调用

`demapper_init()`：

1. 读取 Spark ONNX 模型路径；
2. 建立 `Ort::Env`、`Ort::SessionOptions`；
3. 调用 `SessionOptionsSpaceMITEnvInit()` 注册 SpaceMIT EP；
4. 加载动态模型及可选的 3312/6624/9936/13248 固定形状模型；
5. 建立 CPU memory info，供 host 输入/输出 buffer 包装为 `Ort::Value`。

`demapper_compute_llr()` 或 batch/multi-ULSCH ABI：

1. 将复数 IQ 按 magnitude 归一化到 FP16 `[N,2]`；
2. 按总 RE 数选择固定 shape Session，找不到才走动态 Session；
3. 调用一次 `session->Run()`；
4. 把 FP16 `[N,4]` 输出转换成 scale=8 的 int16 LLR；
5. 多 ULSCH 情况按 group 分散回各自 buffer。

固定模型选择变量：

```text
XSAI_SPACEMIT_FIXED_MODEL          -> 3312 RE
XSAI_SPACEMIT_FIXED_MODEL_6624     -> 2 ULSCH
XSAI_SPACEMIT_FIXED_MODEL_9936     -> 3 ULSCH
XSAI_SPACEMIT_FIXED_MODEL_13248    -> 4 ULSCH
```

OAI 通过 loader 参数加载插件，例如：

```sh
nr_ulsim ... \
  --loader.demapper.shlibpath /home/ubuntu/sionna-rk/.work-neural-demapper-a100/build \
  --loader.demapper.shlibversion _spacemit_ep_scale8
```

## 5. 数据是怎么测出来的

### 5.1 纯插件微基准

入口为 `tests/bench_demapper_a100.c`。流程是：

1. `dlopen()` 插件并执行 `demapper_init()`；
2. 生成确定性的 IQ/magnitude 输入；
3. 预热 20 次；
4. 使用 `CLOCK_MONOTONIC` 对每次调用单独计时；
5. 默认正式测 2000 次，排序后报告 mean/P50/P95/P99/max；
6. 执行 `demapper_shutdown()`，打印逻辑调用、物理 batch 和 multi-ULSCH 计数。

复现单 shape 的核心命令形态：

```sh
cd /home/ubuntu/sionna-rk/.work-neural-demapper-a100
export XSAI_SPACEMIT_EP_THREADS=8
export XSAI_SPACEMIT_EP_AFFINITY='8;9;10;11;12;13;14;15'
export XSAI_SPACEMIT_EP_STREAMS=1
export XSAI_SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD=1
export XSAI_SPACEMIT_FIXED_MODEL="$PWD/models/neural_demapper.3312xfloat16.onnx"
export XSAI_SPACEMIT_REUSE_3312_IO=1
taskset -c 0 build/bench_demapper_a100 \
  build/libdemapper_spacemit_ep_stage18_cache_scale8.so 3312 2000
```

这个数字包括 RVV 预处理、ORT/EP、A100 inference 和输出量化；不包括完整
OAI RX。变更门禁不是只跑一次，而是通常做 5 次、交替或轮换执行顺序，减少
温度、频率和先后顺序造成的偏差。

### 5.2 算子 profile

打开厂商 EP profile 后，将每个 worker 对同一 node 的 trace 合并为
跨 worker 的 wall-clock envelope，不能把 8 个 worker 的 event 时长直接相加。
在 3312 RE 下，debug profile 的 Session 约 159 us，其中三个神经节点约
40.24 us，非节点/运行时部分约 118.8 us。profile 本身有额外开销，所以它只
用于定位比例，生产延迟仍以关闭 debug 的微基准为准。

### 5.3 数值门禁

相同确定性输入同时走基线和候选路径，逐个比较 FP16/int16 输出，记录总元素、
差异数、最大绝对差和符号翻转。Stage 18 的两 ULSCH 合并共比较 26,496 个
int16 LLR，合并与两次独立调用 bit-exact。

### 5.4 多 ULSCH 和 shape cache

`tests/bench_spacemit_multi_ulsch.c` 先验证非法输入保护，再以 5000 次迭代比较：

| 路径 | mean | P99 |
|---|---:|---:|
| 两次独立 3312 | 302.717 us | 339.398 us |
| 一次合并 6624 | 228.863 us | 255.611 us |

合并节省 73.854 us，即 24.4%。

`tools/run_spacemit_shape_cache_stage18.py` 对四个 shape 做 5 轮、每轮 2000 次并
轮换顺序。固定缓存 + shared pool 在混合 shape 场景比动态 Session 快约
6.6%–8.3%；但 9936 RE 相对专用插件仍有约 1.4% 回退，需要继续观察。

### 5.5 完整 OAI/nr_ulsim

完整 RX 使用 `XSAI_TEST_RX_WALL=1`，以 `CLOCK_MONOTONIC` 记录
`FFT_rotation_to_RX_return` 等区间，丢弃前 10 帧 warmup，并固定 seed、SNR、
PRB、MCS、层数和 SCS。同时解析 BLER、false positive、插件调用计数和物理
A100 run 数。

Stage 15 的双上下文测试参数为 seed 180043、SNR 7 dB、24 RB、MCS 10、
单层 16QAM；5 次交替顺序、每次 500 帧。两次独立 A100 run 的完整 RX 均值
为 1610.336 us，一次合并为 1550.296 us，节省 60.040 us（3.73%）。它克隆
同一 RF 波形，只能证明 OAI 所有权、scatter 和两路独立解码正确，不能当作
真实双 UE 结果。

## 6. 结果如何保存和防止误测

- 每次脚本用唯一临时目录写入远端
  `/home/ubuntu/sionna-rk/.work-neural-demapper-a100/results/`，不覆盖旧结果。
- 保存每轮 log 和 `results.json`；关键 gate 保存模型、插件和测试二进制的
  SHA256。
- 运行前确认没有 `nr-softmodem`，避免影响线上进程。
- 记录 mean 和 P50/P95/P99/max，异常值保留，不静默删除。
- 实验前后执行 `spacemit-tcm-smi`。2026-09-28 复盘时为 8/8 block 空闲，
  每块 393216 bytes。
- 性能结论必须写清测量边界：纯插件、operator profile、完整 RX 三者不可互换。

## 7. 当前可信结论与边界

可信结论是：官方 SpaceMIT EP 已被正确初始化，A100 worker 明确绑定 CPU8–15；
冻结 Spark 模型可以在 K3 上运行；固定 shape 缓存和多 ULSCH 合并能够降低
重复 EP 边界成本。

尚不能声称：已经达到 A100 性能极限、已经完成真实多 UE 端到端优化、已经满足
硬实时 deadline，或 Stage 15 代表真实 RF/OTA 容量。下一阶段应先完成不同
ULSCH 输入的 slot coordinator，再对完整端到端链路做单独优化和长尾验证。
