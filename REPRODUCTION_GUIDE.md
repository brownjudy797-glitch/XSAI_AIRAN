# K3 OAI RFsim 可复现实验指导（修订版）

本指导不依赖固定用户名、历史日期、历史分支或作者本机目录。所有结果进入
`$HOME/k3-rfsim-results/<RUN_ID>`，且不修改 OAI 仓库中的配置文件。

## 已修正的问题

- 不再要求外层仓库必须是历史 `time-measure` 分支或特定提交。
- 不把历史二进制 SHA-256 当作当前环境应满足的固定值；每轮写入 manifest。
- 不原地覆盖 `cmake_targets/ran_build/build`，本轮先复用已经验证的当前二进制。
- 不原地修改官方 gNB 配置；从当前 OAI `HEAD` 导出干净副本。
- 不重复修改 `time_meas.c`；正式命令使用 `-q`，并记录当前源码状态。
- 不写死 `/home/ubuntu/k3-ul-test/manual-time-measure-20260902`。
- 同机运行时，UE 固定连接 `127.0.0.1`，不引用其他机器的局域网地址。
- 每轮启动前删除构建目录中的旧统计文件，结束后立即复制到本轮目录。
- 用 `PIPESTATUS[0]` 保存 OAI/timeout 的真实退出码，避免被 `tee` 掩盖。

## 第 1 步：初始化本轮实验目录

```bash
cd "$HOME/sionna-rk"
./scripts/prepare-rfsim-experiment.sh
```

脚本会输出本轮 `RUN_DIR`，并将它写入：

```bash
cat "$HOME/k3-rfsim-results/LATEST"
```

验收条件：

```bash
RUN_DIR=$(cat "$HOME/k3-rfsim-results/LATEST")
test -s "$RUN_DIR/manifest.txt"
test -s "$RUN_DIR/ideal/gnb.conf"
test -s "$RUN_DIR/ideal/ue.conf"
grep -q 'noise_power_dB = -95' "$RUN_DIR/awgn-minus95/gnb.conf"
printf 'Step 1 OK: %s\n' "$RUN_DIR"
```

## 第 2 步：运行前检查（下一阶段）

确认二进制、CPU、端口、旧进程、测量开关和配置一致性：

```bash
RUN_DIR=$(cat "$HOME/k3-rfsim-results/LATEST")
OAI="${OAI_ROOT:-$HOME/sionna-rk/ext/openairinterface5g}"
BUILD="${OAI_BUILD:-$OAI/cmake_targets/ran_build/build}"

test -x "$BUILD/nr-softmodem"
test -x "$BUILD/nr-uesoftmodem"
! pgrep -x nr-softmodem
! pgrep -x nr-uesoftmodem
! sudo ss -lnt | grep -q ':4043 '
grep -q 'dl_carrierBandwidth.*106' "$RUN_DIR/ideal/gnb.conf"
grep -q 'dl_subcarrierSpacing.*1' "$RUN_DIR/ideal/gnb.conf"
! grep -q 'channelmod' "$RUN_DIR/ideal/gnb.conf"
! grep -q 'SAT_LEO_TRANS\|channelmod_rfsimu_LEO' "$RUN_DIR/ideal/ue.conf"
grep -q 'noise_power_dB = -95' "$RUN_DIR/awgn-minus95/gnb.conf"
readelf -A "$BUILD/nr-softmodem" | grep -q 'v1p0'
printf 'Step 2 OK\n'
```

当前 K3 的 CPU0-7 为 X100，实测最高频率 2.15 GHz；CPU8-15 为 A100，
最高频率 1.8 GHz。复现历史实验仍使用 CPU0-7，但这意味着同机 gNB/UE 会
共享八个核心。该限制必须写入结果解释，不能将其当成独立设备实时性能。

## 第 3 步：理想信道（下一阶段）

在两个终端启动 gNB 和 nrUE；运行完成后归档日志、统计和退出码。

## 第 4 步：AWGN -95 dB（下一阶段）

使用独立的 AWGN 配置副本，并验证 channel model 激活与 UE 同步。

## 第 5 步：结果复核（下一阶段）

核对调用次数、均值、最大值、HARQ、同步状态和文件哈希。多轮实验再增加
P50/P95/P99 或重复试验统计。
