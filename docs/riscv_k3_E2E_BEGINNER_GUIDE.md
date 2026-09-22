# K3＋B210＋真实 UE 端到端实验新手指导

本文面向第一次使用本项目的人，目标是从设备接线开始，完成 K3 核心网和 gNB 启动、Quectel UE 注册、基础连通检查，以及 120 秒端到端性能和热点实验。

> **脚本不要选错：**真实 B210 和 Quectel UE 使用 `scripts/run-k3-b200.sh`。不要执行 `start-full-cn5g-k3.sh`，后者启动的是 RFsim 虚拟 gNB/nrUE，不是本指导的真实空口实验。

## 1. 实验拓扑

```text
Windows 本机
  └─ USB：Quectel RM520N-GL UE（12.1.1.x）
                ⇅ 5G NR SA / n78
              B210
                │ USB 3.0
K3：gNB ── N2 ── AMF
        └─ N3 ── UPF ── tun0（12.1.1.1/24）
                    ├─ SMF
                    └─ MySQL / oai_db
```

## 2. 开始前准备

### 2.1 硬件

准备以下设备：

- K3 RISC-V 开发板及稳定电源；
- Ettus USRP B210；
- n78 天线或实验室允许使用的射频连接/衰减方案；
- Quectel RM520N-GL 5G 模组和已写入项目用户信息的 USIM；
- Windows 实验电脑；
- K3 网络连接。

先连接 B210，再启动 gNB。B210 尽量直接接 K3 的 USB 3.0 接口，不要经过不稳定的 Hub。射频发射必须符合所在实验室和当地频谱管理要求。

### 2.2 本指导采用的固定参数

| 项目 | 值 |
|---|---|
| PLMN | `26299` |
| 制式 | 5G SA |
| 频段 | n78 |
| B210 序列号 | 以 `uhd_find_devices` 的现场输出为准 |
| K3 N2/N3 地址 | 读取 `config/b200/.env` 中的 `GNB_IP` |
| UPF N3 地址 | 读取 `config/cn5g-k3/upf.yaml` |
| UE 地址池 | `12.1.1.0/24` |
| UPF 用户面地址 | `12.1.1.1` |
| DNN/APN | `oai` |
| 正式测量窗口 | 每个档位 120 秒 |

如果现场配置与表中不同，应先修改项目配置并记录，不能只在结果表里改名称。

## 3. 从 Windows 登录 K3

打开 PowerShell：

```powershell
ssh <K3_USER>@<K3_IP>
```

进入项目：

```bash
cd "$HOME/sionna-rk"
```

如果 SSH 失败，先在 K3 本地终端执行：

```bash
hostname -I
systemctl is-active ssh
ip -4 address
```

选择实验电脑能够直接访问的 K3 地址作为 `<K3_IP>`。文档不固定用户名、管理网地址或组网工具；不要把密码写入脚本或文档。

## 4. 启动前检查

### 4.1 检查内核和程序

在 K3 执行：

```bash
uname -m
uname -r
test -x "$HOME/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem" && echo "gNB binary OK"
```

正常情况下应看到：

```text
riscv64
6.18.3-k3-sctp+
gNB binary OK
```

内核版本可以随维护升级，但必须支持 SCTP：

```bash
grep -w sctp /proc/modules || sudo modprobe sctp
```

### 4.2 检查 B210

```bash
lsusb | grep '2500:0020'
uhd_find_devices
```

应看到：

```text
Ettus Research LLC USRP B210
serial: <B210_SERIAL>
product: B210
```

如果返回 `No UHD Devices Found`，不要继续启动。重新插拔 B210、换 USB 3.0 接口或线缆，然后再次检查。

### 4.3 检查数据库

```bash
systemctl is-active mysql
sudo mysqladmin ping
sudo mysql -N -e "SELECT COUNT(*) FROM oai_db.users;"
```

正常结果应包含 `active`、`mysqld is alive`，并返回大于 0 的用户数。项目当前使用 MySQL；不要另外安装或启动 MariaDB。

## 5. 启动核心网和 gNB

执行一次预检查：

```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-b200.sh check
```

预检查通过后启动：

```bash
./scripts/run-k3-b200.sh start
```

该命令会在需要时自动启动 MySQL、UPF、SMF、AMF，然后启动 B210 gNB。正常输出应包含：

```text
Native K3 B200 gNB started.
AMF: <AMF_IP>
USRP: <B210_SERIAL>
```

检查状态：

```bash
./scripts/run-k3-b200.sh status
```

重点确认：

- `mysql: healthy`；
- UPF、SMF、AMF 均为 `running`；
- `N4: associated`；
- `k3-b200-gnb.service` 为 `active (running)`；
- 日志含 `Received NGSetupResponse from AMF`。

实时查看 gNB 日志：

```bash
./scripts/run-k3-b200.sh log
```

按 `Ctrl+C` 只退出日志查看，不会停止 gNB。

## 6. 在 Windows 检查 Quectel UE

### 6.1 找到 AT 口和数据网卡

打开新的 PowerShell：

```powershell
Get-PnpDevice -PresentOnly |
  Where-Object FriendlyName -Match 'Quectel' |
  Format-Table Status,Class,FriendlyName

Get-NetAdapter |
  Where-Object InterfaceDescription -Match 'Quectel' |
  Format-Table ifIndex,Name,InterfaceDescription,Status
```

本次设备示例：

```text
Quectel USB AT Port (COMx)
Quectel Wireless Ethernet Adapter
ifIndex <UE_IFINDEX>
```

实际 COM 口和 `ifIndex` 可能变化，后续命令必须使用现场查询结果。

### 6.2 用 AT 命令确认注册

可以使用串口工具打开 AT 口，波特率设置为 `115200`，依次执行：

```text
ATI
AT+CPIN?
AT+COPS?
AT+C5GREG?
AT+QNWINFO
AT+QENG="servingcell"
AT+CGATT?
AT+CGDCONT?
AT+CGACT?
AT+CGPADDR=1
```

成功时应看到类似结果：

```text
+CPIN: READY
+COPS: 0,0,"262 99",11
+C5GREG: 0,1
+QNWINFO: "TDD NR5G","26299","NR5G BAND 78",640320
+QENG: "servingcell","NOCONN","NR5G-SA",...
+CGATT: 1
+CGACT: 1,1
+CGPADDR: 1,"<UE_IP>"
```

`NOCONN` 表示当前没有持续业务传输，不等于没有注册。注册是否成功主要看 `C5GREG: 0,1`、`CGATT: 1` 和 `12.1.1.x` 地址。

如果 UE 一直不注册，可先开启飞行模式约 5 秒再关闭，或让模组重新搜网。不要反复重启整套核心网。

## 7. 首次连通验证

### 7.1 找到 UE 地址

```powershell
$ueIf = <UE_IFINDEX>
Get-NetIPAddress -InterfaceIndex $ueIf -AddressFamily IPv4
```

确认地址属于 `12.1.1.0/24`。

### 7.2 Ping UPF

```powershell
ping.exe -4 -S <UE_IP> -n 10 12.1.1.1
```

将 `<UE_IP>` 换成现场查询到的 UE 地址。首次跑通后应建立本套设备自己的基线，不能引用其他机器的延时作为本机验收值。

如果 Windows 已获得 `12.1.1.x`，但 Ping 不通，依次检查：

```bash
# K3
ip -4 address show tun0
ip route | grep 12.1.1
./scripts/status-cn5g-k3.sh
systemctl is-active k3-b200-gnb
```

## 8. 安装 Windows iperf3

在管理员或普通 PowerShell 中执行：

```powershell
winget install --id ar51an.iPerf3 --exact --accept-package-agreements --accept-source-agreements
```

关闭并重新打开 PowerShell，然后检查：

```powershell
iperf3.exe --version
```

如果新窗口仍找不到命令，可在执行实验时用 `Get-Command iperf3.exe` 返回的完整路径作为 `-Iperf` 参数。

## 9. 准备实验脚本

Windows 侧文件：

- `Run-K3-E2E-Experiment.ps1`
- `riscv_k3_E2E_PERFORMANCE_GUIDE.md`

K3 侧应存在：

```bash
test -x "$HOME/sionna-rk/scripts/run-k3-e2e-collector.sh" && echo "collector OK"
command -v iperf3
command -v perf
command -v pidstat
command -v mpstat
```

缺少 K3 工具时执行：

```bash
sudo apt-get update
sudo apt-get install -y iperf3 sysstat linux-perf
```

## 10. 按顺序执行实验

在存放 PowerShell 脚本的目录打开 PowerShell：

```powershell
cd "<实验工具目录>"
```

以下命令中的 `<K3_USER>`、`<K3_IP>` 和 `<UE_IFINDEX>` 必须替换成现场查询值。

### 10.1 Smoke：只验证路径

```powershell
.\Run-K3-E2E-Experiment.ps1 `
  -K3 '<K3_USER>@<K3_IP>' `
  -InterfaceIndex <UE_IFINDEX> `
  -Mode Smoke `
  -Rounds 1 `
  -WarmupSeconds 10 `
  -Label first-smoke
```

打开本轮目录中的 `outcome.txt`，必须是 `VALID`；`measure-ping.txt` 应有响应。

### 10.2 Baseline：120 秒空载时延

```powershell
.\Run-K3-E2E-Experiment.ps1 `
  -K3 '<K3_USER>@<K3_IP>' `
  -InterfaceIndex <UE_IFINDEX> `
  -Mode Baseline `
  -Rounds 3 `
  -WarmupSeconds 60 `
  -MeasureSeconds 120 `
  -CooldownSeconds 30 `
  -Label baseline-120s
```

### 10.3 Step：120 秒上下行分档

```powershell
.\Run-K3-E2E-Experiment.ps1 `
  -K3 '<K3_USER>@<K3_IP>' `
  -InterfaceIndex <UE_IFINDEX> `
  -Mode Step `
  -Rounds 3 `
  -WarmupSeconds 60 `
  -MeasureSeconds 120 `
  -CooldownSeconds 30 `
  -Rates 100K,250K,500K,1M,2M `
  -Label baseline-step-120s
```

脚本按每个速率分别运行上行和下行，每个方向均使用独立的 120 秒窗口。第一次使用建议先跑 1 轮；确认结果完整后再跑 3 轮预实验和 5 轮正式实验。

## 11. 如何查看结果

结果目录：

```text
results-e2e/<日期时间-标签-模式-runN>/
```

新手先看四类文件：

1. `outcome.txt`：本轮是否有效；
2. `measure-ping.txt`：RTT 和丢包；
3. `summary.csv`：上下行吞吐、UDP 丢包和抖动；
4. `k3/perf-report-flat.txt`：函数热点。

进一步分析：

| 文件 | 用途 |
|---|---|
| `UL-*.json`、`DL-*.json` | iperf3 原始数据 |
| `k3/pidstat-gnb.txt` | gNB CPU、内存和切换情况 |
| `k3/mpstat.txt` | 每个 CPU 核心负载 |
| `k3/frequency-temperature.csv` | CPU 频率和温度 |
| `k3/nrL1_stats-start.log` | OAI 测量窗口开始快照 |
| `k3/nrL1_stats-end.log` | OAI 测量窗口结束快照 |
| `k3/perf.data` | 可重新分析的原始函数采样 |
| `k3/perf-report-callgraph.txt` | 带调用关系的热点 |

OAI 的统计是启动以来的累计量，不能直接把两个平均值相减。窗口计算公式：

```text
窗口调用数 = end.trials - start.trials
窗口总耗时 = end.avg_us × end.trials - start.avg_us × start.trials
窗口平均耗时 = 窗口总耗时 / 窗口调用数
```

外层计时包含内部模块，不能把 `L1 Rx processing`、`PUSCH inner-receiver`、信道估计和 LDPC 等项目直接相加。

## 12. 一轮结果何时有效

同时满足以下条件才标为有效：

- `outcome.txt` 为 `VALID`；
- UE 地址在实验期间没有变化；
- gNB、AMF、SMF、UPF 没有退出或重启；
- iperf3 没有报错；
- K3 结果中存在 `COMPLETE`；
- OAI 首尾快照和 perf 报告均存在；
- 没有 B210 `LIBUSB_TRANSFER_NO_DEVICE` 错误。

失败轮必须保留并注明原因，不能把失败吞吐填成 0 后参与均值。

## 13. 常见问题

### 13.1 `No UHD Devices Found`

原因通常是 B210 未连接、USB 线缆/Hub 不稳定或 USB 设备掉线。执行：

```bash
lsusb
uhd_find_devices
dmesg --ctime | tail -100
```

只有 UHD 能看到正确序列号后才能重启 gNB。

### 13.2 gNB 启动后立即退出

```bash
sudo journalctl -u k3-b200-gnb.service -n 200 --no-pager
./scripts/run-k3-b200.sh check
```

重点搜索 `No UHD Devices`、`LIBUSB_TRANSFER_NO_DEVICE`、SCTP、AMF 地址和配置解析错误。

### 13.3 UE 能看到 n78，但没有 `12.1.1.x`

检查：

- `AT+C5GREG?` 是否为 `0,1`；
- `AT+CGATT?` 是否为 `1`；
- APN 是否为 `oai`；
- 用户 IMSI/密钥是否已录入 `oai_db.users`；
- SMF 日志是否建立 PDU Session；
- gNB 日志是否出现 `PDU Session Setup Response`。

### 13.4 `perf.data` 为空或无样本

本项目采集器只运行 `perf record`，不应在同一窗口额外启动基于硬件 cycles 的 `perf stat`。K3 PMU 同时使用时可能让热点采样无数据。

### 13.5 结果复制时提示 `Permission denied`

先等待 K3 结果目录出现 `COMPLETE`。最新版采集器最多等待 120 秒生成 perf 调用图，并在完成前修正 `perf.data` 权限。不要在 `COMPLETE` 出现前手动复制目录。

## 14. 停止系统

实验全部结束后在 K3 执行：

```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-b200.sh stop
```

这会停止 gNB 和 CN5G。确认：

```bash
systemctl is-active k3-b200-gnb || true
pgrep -a nr-softmodem || true
pgrep -a amf || true
pgrep -a smf || true
pgrep -a upf || true
```

停止后再安全断开 B210。不要在 gNB 正在运行时直接拔出 B210。

## 15. 下一步

完成新手流程后，再阅读 `riscv_k3_E2E_PERFORMANCE_GUIDE.md`。该文档规定正式实验的变量控制、有效性规则、统计方法及热点解释方式；新手指导负责“如何跑通”，标准实验指导负责“数据如何可信”。
