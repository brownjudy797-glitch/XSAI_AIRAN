<!-- SPDX-License-Identifier: Apache-2.0 -->
> 新机器先阅读 [CN5G/B210 必需前提](FROM_ZERO.md)，补齐本地网络、订阅与 UHD。第 6.2 节仅供已有源码布局使用；Release 安装不能直接运行它。RFsim 热点实验改用 [当前 K3 复现流程](../reproduction/README.md)。

# K3 SCTP 内核与 OAI CN5G RISC-V 移植说明

本教程已整理为仓库下载版（2026-10-29）：保留原操作步骤，补丁和长脚本统一按版本分发、下载时检查 SHA256。
[返回教程入口](../README.md) · [工具来源与版本](../assets/20261029/README.md)
语法、补丁应用与失败停止逻辑已在本地检查；平台编译、射频、核心网和性能结果仍需在对应设备现场验证。

## 1. 移植目标
目标平台为 K3 Pico-ITX、RV64。核心网采用精简的非 NRF 结构：MariaDB、OAI AMF、OAI SMF、OAI UPF。gNB 经 N2/SCTP 接入 AMF，经 N3/GTP-U 接入 UPF；SMF 与 UPF 使用 N4/PFCP。

## 2. SCTP 内核
基线内核为 `6.18.3-7-spacemit-generic`。移植内核版本标记为 `6.18.3-k3-sctp+`，SCTP 以模块形式提供：

```text
/lib/modules/6.18.3-k3-sctp+/kernel/net/sctp/sctp.ko.zst
```

安装包同时保存内核映像、initramfs、配置、System.map、K3 DTB 和完整模块树。K3 的 U-Boot `boot.scr` 固定 `fk_kvers`，因此只复制内核文件并不足以启动；安装脚本会备份并切换对应的 `boot.scr`，然后执行 `update-grub`。原厂内核及其文件不会删除。

验收：

```bash
uname -r
grep -i sctp /proc/net/protocols
modinfo sctp
ss -lnp --sctp
```

## 3. 已完成的功能验证
+ AMF N2/SCTP 监听和 gNB NG Setup；
+ SMF–UPF N4/PFCP association；
+ UE 注册、5G-AKA、Security Mode、Registration Accept；
+ PDU Session 建立，UE 获得 `12.1.1.130`；
+ UPF 上下行 PDR/FAR 和 N3 GTP-U；
+ UE 到 UPF、UE 到公网的双向转发；
+ gNB、UE 与核心网的一键启停回归。

## 4. 限制
+ 仅保证相同 K3 型号与相同 Ubuntu 系统基线；
+ 配置中的出口网卡和主机地址必须针对目标板重新生成；
+ B210 实时空口仍受 K3 实时性和 UHD overflow 影响，这与 CN5G 功能移植是否成功是两个独立验收项；
+ 若升级系统 glibc、OpenSSL、MariaDB 或核心网源码，需要重新执行 `ldd`、SCTP/N4/N2 和 PDU Session 回归。

## 4.1 安装布局与后续命令的前提

在线 Release 安装使用 `/opt/sionna-rk-k3/cn5g`、`/etc/sionna-rk-k3/cn5g` 和 `/var/lib/sionna-rk-k3/cn5g`。
当前安装脚本依赖 `mysql` 服务及客户端；原记录中的 MariaDB 是历史环境描述，新安装按脚本实际要求使用 MySQL 兼容环境。
第 6.2 节的一键 RFsim 示例属于已有完整源码部署环境，还需要 `ext/oai-cn5g-fed`、本机订阅、`config/cn5g-k3` 和配套启动脚本；Release 安装本身不会自动创建该源码布局。
新设备先完成本节在线安装与 N2/N4 检查，再按 B210 路线配置真实 UE；已有源码部署环境才执行第 6.2 节。
RFsim 热点测量使用 `--phy-test --noS1`，不需要核心网，参见 K3/x86/ARM64 热点教程。

## 5. 在线安装（推荐）
目标 K3 能访问 GitHub 时，使用本节。安装程序会从公开 Release 下载并校验 RISC-V 安装包。

### 5.1 下载说明与仓库
+ K3 已支持 SCTP 时，只需下载约 128 MB 的 CN5G 包；
+ 只有缺少 SCTP 时，才额外下载约 875 MB 的内核包；
+ 安装程序会核对 Release 中发布的 SHA-256，校验失败会停止安装。

先安装下载工具，再下载安装仓库：

```bash
sudo apt update
sudo apt install -y git curl ca-certificates zstd
```

```bash
cd "$HOME"
git clone https://github.com/brownjudy797-glitch/sionna-rk-k3-porting.git
cd sionna-rk-k3-porting
```

如果此前已经下载过，只需更新：

```bash
cd "$HOME/sionna-rk-k3-porting"
git pull --ff-only origin main
git rev-parse --short HEAD
```

内核载荷校验误报修复包含在提交 `caa1be3` 及后续版本中。若输出的提交早于该版本，应先完成更新再安装。

### 5.1.1 修正在线入口的依赖包名

核对当前安装仓库时发现，`install-online.sh` 中数据库包名写成了 `mysql-serve`，会导致 APT 找不到软件包。
下面只修正目标机下载的安装仓库副本，改为 `mysql-server`，不修改本节分发仓库或设备配置。
若后续安装仓库已修正，反向检查会直接识别，无需重复应用。

```bash
(
set -e
target="$HOME/sionna-rk-k3-porting/k3-porting-dependency.patch"
mkdir -p -- "$(dirname "$target")"
tmp=$(mktemp "${target}.download.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
curl -fL --retry 3 --connect-timeout 15 \
  "https://raw.githubusercontent.com/brownjudy797-glitch/XSAI_AIRAN/main/tutorials/assets/20261029/k3-porting-dependency.patch" -o "$tmp"
printf '%s  %s\n' '41046d89c5797d95f0833d5207ffe61dde6087b5eb864cedfcfd2adba9c86f57' "$tmp" | sha256sum --check -
mv -- "$tmp" "$target"
)
(
set -e
cd "$HOME/sionna-rk-k3-porting"
patch="$PWD/k3-porting-dependency.patch"
if git apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "依赖包名已正确。"
else
    git apply --check "$patch"
    git apply "$patch"
    git apply --reverse --check "$patch"
fi
)
```

### 5.2 检查平台和 SCTP
```bash
./install-online.sh check
```

若结果显示 `SCTP: available（无需更换内核）`，不要重复安装内核，直接进入下一步。

只有 SCTP 不可用时才执行：

```bash
./install-online.sh kernel
sudo reboot
```

安装程序会先校验 Release 的 SHA-256，再完整读取压缩包目录，并确认以下两部分同时存在：

```text
boot/vmlinuz-6.18.3-k3-sctp+
lib/modules/6.18.3-k3-sctp+/
```

若旧版脚本显示 `ERROR: 内核载荷不完整`，不要删除载荷或重启。先确认脚本是否已经更新：

```bash
grep -n PAYLOAD_LIST 01-sctp-kernel/install-sctp-kernel.sh
```

没有输出表示仍是旧脚本，执行：

```bash
git pull --ff-only origin main
```

需要人工复核已下载载荷时执行：

```bash
tar --zstd -tf 01-sctp-kernel/kernel-payload.tar.zst > /tmp/k3-kernel-files.txt
grep -Fx 'boot/vmlinuz-6.18.3-k3-sctp+' /tmp/k3-kernel-files.txt
grep -F 'lib/modules/6.18.3-k3-sctp+/' /tmp/k3-kernel-files.txt | head
```

两条检查都有输出才表示内核映像和模块树均存在。修正版脚本避免了旧版 `pipefail` 与 `grep -q` 组合造成的误报。

重启后重新进入仓库并检查：

```bash
cd "$HOME/sionna-rk-k3-porting"
./install-online.sh check
```

### 5.3 在线安装 CN5G
使用自动检测到的本机网络参数安装：

```bash
./install-online.sh cn5g
```

需要明确指定地址和出口网卡时，先生成本机配置：

```bash
cp 02-cn5g/config.env.example config.env
nano config.env
./install-online.sh cn5g ./config.env
```

公开安装包不包含实验室 UE 的 IMSI、K、OPc 等鉴权数据。真实 UE 的用户信息必须在本机单独配置，不要提交到公开仓库。

### 5.4 安装 B200/B210 启动脚本
确认 `$HOME/sionna-rk` 中的 OAI RAN 已经编译完成后执行：

```bash
cd "$HOME/sionna-rk-k3-porting"
./install-online.sh b200 "$HOME/sionna-rk"
```

脚本会安装到 `$HOME/sionna-rk/scripts/run-k3-b200.sh`。完整启动方法见第 6 节。

## 6. 启动 gNB、CN5G 并连接 UE
本节要求目标 K3 已经按第 5 节在线安装 CN5G，并且已经安装、编译 Sionna-RK 中的 OAI RAN。确认下面两个程序存在：

```bash
cd "$HOME/sionna-rk"
test -x ext/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem \
  && echo "gNB: OK" || echo "gNB: MISSING"
test -x ext/openairinterface5g/cmake_targets/ran_build/build/nr-uesoftmodem \
  && echo "nrUE: OK" || echo "nrUE: MISSING"
```

在线安装的 `02-cn5g` 只负责核心网，不包含 OAI RAN 编译产物。若显示 `MISSING`，应先完成 OAI RISC-V 移植和编译，不能直接执行下面的启动命令。

### 6.1 两种 UE 接入方式
本项目支持两种不同的验证方式：

1. RFsim 软件 UE：gNB、RFsim、nrUE 和核心网都运行在 K3，用于验证完整协议流程，不发射真实无线信号；
2. B210 + 真实 UE：K3 运行 gNB 和核心网，B210 提供真实射频，手机或测试终端作为 UE。

初次部署应先完成 RFsim 软件 UE 验证，再尝试 B210 和真实 UE。

### 6.2 已有源码部署环境：启动核心网、gNB 和软件 UE
本节是历史源码布局操作，下面的 `pkill` 会停止整机所有同名进程，仅供确认可以停机的专用实验机使用。新复现主线使用独立 namespace，不需要这些全局清理命令；不要在保留在线部署的 K3 上照抄本节。

先停止可能遗留的进程：

```bash
cd "$HOME/sionna-rk"
sudo env SIONNA_RK_ROOT="$HOME/sionna-rk" ./scripts/stop-full-cn5g-k3.sh || true
sudo pkill -INT -x nr-uesoftmodem 2>/dev/null || true
sudo pkill -INT -x nr-softmodem 2>/dev/null || true
sleep 3
```

启动完整 RFsim 5G 系统：

```bash
cd "$HOME/sionna-rk"
sudo -v
./scripts/start-full-cn5g-k3.sh
```

该脚本按以下顺序执行：

```text
MariaDB
→ UPF
→ SMF
→ AMF
→ N4 PFCP association
→ gNB
→ N2 NG Setup
→ 创建 cn5g-ue network namespace
→ nrUE
→ 注册和 PDU Session
```

检查整体状态：

```bash
cd "$HOME/sionna-rk"
./scripts/status-full-cn5g-k3.sh
```

成功结果应至少包含：

```text
upf: running
smf: running
amf: running
N4: associated
gNB: running
nrUE: running
UE PDU: active
N2 NG Setup: confirmed
PDU Session Accept: confirmed
```

检查 UE 地址：

```bash
sudo ip netns exec cn5g-ue ip -br address show oaitun_ue1
```

默认应看到 UE 地址 `12.1.1.130`。

验证 UE 到 UPF：

```bash
sudo ip netns exec cn5g-ue ping -I oaitun_ue1 -c 5 12.1.1.1
```

验证 UE 到公网：

```bash
sudo ip netns exec cn5g-ue ping -I oaitun_ue1 -c 5 8.8.8.8
```

查看各组件日志：

```bash
cd "$HOME/sionna-rk"
tail -100 logs/cn5g-k3/upf.log
tail -100 logs/cn5g-k3/smf.log
tail -100 logs/cn5g-k3/amf.log
tail -100 logs/cn5g-k3/gnb.log
tail -100 logs/cn5g-k3/nrue.log
```

快速检查关键流程：

```bash
grep -E 'Received NGSetupResponse|associated AMF' logs/cn5g-k3/gnb.log
grep -E 'Initial sync successful|UE synchronized|Registration Accept|PDU Session Establishment Accept' logs/cn5g-k3/nrue.log
grep -E 'Authentication Response|Registration Complete' logs/cn5g-k3/amf.log
grep -E 'N4 ASSOCIATION SETUP RESPONSE|PDU_SESSION_ACTIVE' logs/cn5g-k3/smf.log
```

停止完整 RFsim 系统：

```bash
cd "$HOME/sionna-rk"
sudo env SIONNA_RK_ROOT="$HOME/sionna-rk" ./scripts/stop-full-cn5g-k3.sh
```

停止后确认没有残留：

```bash
pgrep -a nr-softmodem || true
pgrep -a nr-uesoftmodem || true
pgrep -a amf || true
pgrep -a smf || true
pgrep -a upf || true
ip netns list
```

### 6.3 RFsim 启动失败时检查
如果提示 gNB 没有完成 NG Setup：

```bash
grep -E 'NGSetup|SCTP|AMF|ERROR|Assert' "$HOME/sionna-rk/logs/cn5g-k3/gnb.log" | tail -100
sudo ss -lnp --sctp
ip route get "$(hostname -I | awk '{print $1}')"
```

如果 nrUE 无法建立 PDU Session：

```bash
grep -E 'Initial sync|UE synchronized|Registration|Authentication|PDU Session|ERROR|Assert' \
  "$HOME/sionna-rk/logs/cn5g-k3/nrue.log" | tail -150
tail -100 "$HOME/sionna-rk/logs/cn5g-k3/amf.log"
tail -100 "$HOME/sionna-rk/logs/cn5g-k3/smf.log"
```

再次运行前必须先清理：

```bash
cd "$HOME/sionna-rk"
sudo env SIONNA_RK_ROOT="$HOME/sionna-rk" ./scripts/stop-full-cn5g-k3.sh || true
```

### 6.4 B210：启动核心网和真实射频 gNB
真实射频测试应在屏蔽箱或符合当地无线电管理要求的实验环境中进行，并使用合适的衰减器。不要在未经许可的频段直接辐射发射。

该启动器不属于 Sionna-RK 官方仓库，属于 **【K3 移植新增】**。可以直接在目标 K3 上生成，不需要从作者电脑复制脚本。

#### 6.4.1 准备 B200/B210 运行脚本
运行脚本属于 **【K3 移植新增】**，不属于 Sionna-RK 官方仓库。请选择一种方式：

1. 已有源码部署环境：按文末附录 A 下载历史源码布局启动脚本；
2. 按照下一小节由在线安装程序提供与安装布局匹配的启动脚本。

正文不再放置完整脚本，后续修改或核对脚本时统一查看附录 A。

#### 6.4.2 使用在线安装程序
已经下载移植仓库时，可以由在线安装程序提供与安装布局匹配的启动脚本：



```bash
cd "$HOME/sionna-rk-k3-porting"
./install-online.sh b200 "$HOME/sionna-rk"
```

安装后应存在：

```text
$HOME/sionna-rk/scripts/run-k3-b200.sh
$HOME/sionna-rk/config/b200/.env.k3-example
```

检查脚本：

```bash
test -x "$HOME/sionna-rk/scripts/run-k3-b200.sh" \
  && echo "B200 launcher: OK" || echo "B200 launcher: MISSING"
bash -n "$HOME/sionna-rk/scripts/run-k3-b200.sh"
```

如果 `config/b200/.env` 尚不存在，以项目原有配置或 `.env.k3-example` 为参考创建。  
至少要填写 `USRP_SERIAL`、`AMF_IP`、`GNB_IP`、`K3_GNB_BUILD` 和  
`K3_GNB_ALLOWED_CPUS`。示例里的序列号、IP 和用户名路径不能直接照抄。

确认 B210 已连接到 USB 3：

```bash
lsusb | grep '2500:0020'
uhd_find_devices
uhd_usrp_probe
```

记录 `uhd_find_devices` 输出的序列号，然后检查：

```bash
cd "$HOME/sionna-rk"
grep -E '^(USRP_SERIAL|AMF_IP|GNB_IP|K3_GNB_BUILD|K3_GNB_ALLOWED_CPUS)=' config/b200/.env
```

至少确认：

+ `USRP_SERIAL` 与当前 B210 一致；
+ `AMF_IP` 是本机 AMF 实际监听地址；
+ `GNB_IP` 已分配给当前 K3；
+ `K3_GNB_BUILD` 指向有效的 RISC-V OAI 构建目录。

检查配置但不启动：

```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-b200.sh check
```

检查通过后启动核心网和 B210 gNB：

```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-b200.sh start
```

只有已经另外应用 K3 `start_system.sh` 集成补丁的开发环境，才可以使用统一入口：

```bash
cd "$HOME/sionna-rk"
./scripts/start_system.sh b200
```

在线安装程序默认保证可用的是 `run-k3-b200.sh`。两种入口选择一个执行，不要重复启动。

检查状态：

```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-b200.sh status
```

持续查看 gNB 日志：

```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-b200.sh log
```

重点确认：

```text
Received NGSetupResponse
associated AMF 1
```

这只说明 gNB 已通过 N2 接入核心网，不代表真实 UE 已经注册。

### 6.5 真实 UE/手机的 USIM 条件
普通运营商 SIM 不能直接注册到本实验核心网。真实 UE 必须满足：

+ 支持 SA 5G NR 和 n78；
+ 使用可编程测试 USIM；
+ USIM 中的 IMSI、K、OPc/OP 与 AMF 查询的 `oai_db.users` 记录一致；
+ PLMN 与 gNB/AMF 配置一致，本项目当前使用 `MCC=208`、`MNC=95`；
+ APN/DNN 与核心网配置一致，当前为 `oai`。

查看 OAI 软件 UE 使用的测试身份：

```bash
cd "$HOME/sionna-rk"
grep -E '^[[:space:]]*(imsi|key|opc|dnn)' \
  ext/oai-cn5g-fed/docker-compose/ran-conf/nr-ue.conf
```

查看数据库中已经配置的 IMSI（需要数据库管理员权限）：

```bash
sudo mariadb oai_db -e 'SELECT imsi,mcc,mnc FROM users;'
```

不要把测试 USIM 的 K、OPc 或数据库口令上传到公共平台。写入实体 USIM 时，应在受控环境中完成。

### 6.6 观察真实 UE 注册过程
另开一个终端观察 AMF：

```bash
tail -F "$HOME/sionna-rk/logs/cn5g-k3/amf.log" \
  | grep --line-buffered -E 'Registration|Authentication|Security Mode|PDU Session|imsi|supi'
```

观察 SMF：

```bash
tail -F "$HOME/sionna-rk/logs/cn5g-k3/smf.log" \
  | grep --line-buffered -E 'Create SM Context|N4|PFCP|PDU_SESSION_ACTIVE'
```

观察 UPF：

```bash
tail -F "$HOME/sionna-rk/logs/cn5g-k3/upf.log" \
  | grep --line-buffered -E 'SESSION ESTABLISHMENT|PDR|FAR|GTP'
```

真实 UE 接入成功应依次出现：

```text
RRC 接入
→ Registration Request
→ Authentication Response
→ Security Mode Complete
→ Registration Complete
→ PDU Session Establishment
→ PFCP Session Establishment
→ PDU_SESSION_ACTIVE
```

### 6.7 停止 B210 gNB 和核心网
如果使用 `run-k3-b200.sh` 启动：

```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-b200.sh stop
```

如果已经另外应用统一入口补丁并使用该入口启动：

```bash
cd "$HOME/sionna-rk"
./scripts/stop_system.sh b200
```

最后检查：

```bash
systemctl is-active k3-b200-gnb.service || true
pgrep -a nr-softmodem || true
pgrep -a amf || true
pgrep -a smf || true
pgrep -a upf || true
```

### 6.8 当前 B210 限制
当前 K3 已验证：B210 能被 UHD 识别、gNB 能初始化、核心网能启动、N2 NG Setup 能完成。但射频流仍可能出现 UHD `ERROR_CODE_OVERFLOW`。因此现阶段可以声明“B210 gNB 与 CN5G 框架已打通”，在 overflow 和实时性问题解决、真实 UE 完成注册及 PDU Session 前，不能声明真实空口端到端已经验收成功。

## 附录 A：下载 B200/B210 运行脚本
本附录是正文中最先出现的新增脚本。把下面代码块完整复制到目标 K3 终端执行；它会生成 `$HOME/sionna-rk/scripts/run-k3-b200.sh`。

```bash
cd "$HOME/sionna-rk"
mkdir -p scripts

(
set -e
target="$HOME/sionna-rk/scripts/run-k3-b200.sh"
mkdir -p -- "$(dirname "$target")"
tmp=$(mktemp "${target}.download.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
curl -fL --retry 3 --connect-timeout 15 \
  "https://raw.githubusercontent.com/brownjudy797-glitch/XSAI_AIRAN/main/tutorials/assets/20261029/run-k3-b200.sh" -o "$tmp"
printf '%s  %s\n' '9aa5ad924ae4ee6260a97956110286eec00c59360ed7ac8c04287099672acc32' "$tmp" | sha256sum --check -
mv -- "$tmp" "$target"
chmod 0755 -- "$target"
)

chmod +x scripts/run-k3-b200.sh
bash -n scripts/run-k3-b200.sh \
  && echo "B200 运行脚本创建成功，语法检查通过"
```

下载命令已包含 SHA256 校验；不再需要复制 heredoc 或大型脚本正文。

生成结果应位于：

```text
$HOME/sionna-rk/scripts/run-k3-b200.sh
```
