# K3＋B210＋CN5G 端到端性能标准实验指导

第一次接线、启动或配置 Quectel UE 时，请先按 `riscv_k3_E2E_BEGINNER_GUIDE.md` 完成新手流程；本文只规定正式实验方法和数据有效性。

## 1. 实验目标与边界

本实验测量真实 UE 到 K3 用户面的端到端性能：

```text
Windows UE终端 ── 真实UE/空口 ── B210 ── K3 gNB ── N3 ── K3 UPF(12.1.1.1)
                                                    ├─ AMF/SMF/MySQL
                                                    └─ 本地 iperf3 服务端
```

主指标为接入成功、会话稳定、RTT、吞吐、UDP 丢包和抖动。K3 CPU、线程、频率、温度、网卡和日志是解释性能的辅助数据。该实验不等价于 RFsim 理想信道热点测试；不能把二者直接相除称为平台加速比。

Sionna-RK 原始 Compose 使用 `mysql:8.0`、服务名 `mysql`、数据库 `oai_db` 和用户表 `users`。K3 使用 Ubuntu RISC-V 原生 MySQL 8.4，保持 `type: mysql`、`oai_db`、`users`、初始化 SQL和健康检查语义一致。二者的小版本差异必须记录在实验元数据中。

## 2. 固定变量

每组实验必须固定：K3/OAI/CN5G 提交、编译选项、gNB 配置、PRB/SCS/TDD、B210 序列号及 USB 端口、天线/衰减、UE 和 USIM、CPU 绑核、调频策略、环境位置。优化前后一次只改一个因素。

推荐基线：预热 60 s、测量 120 s、档间冷却 30 s、3 轮预实验、5 轮正式实验。每个上下行速率档均使用独立的 120 s 测量窗口。UDP 阶梯为 100K、250K、500K、1M、2Mbit/s；稳定后再扩展上限。速率阶梯属于项目实验条件，不是 5G 标准规定值。

## 3. 有效性规则

以下任一发生，本轮标记 `INVALID`，但不得删除结果：gNB/AMF/SMF 退出或重启、UE 地址变化、PDU Session 中断、iperf 返回错误、采集器未完整停止。失败轮不能填成 0 Mbit/s，也不能混入有效轮均值。

正式报告同时给出：有效轮数/总轮数、均值、标准差、最小值、最大值。端到端嵌套计时项不能相加。

## 4. 安装实验脚本

将仓库中的 `run-k3-e2e-collector.sh` 放到 K3：

```bash
scp run-k3-e2e-collector.sh <K3_USER>@<K3_IP>:~/sionna-rk/scripts/
ssh <K3_USER>@<K3_IP> 'chmod +x ~/sionna-rk/scripts/run-k3-e2e-collector.sh && bash -n ~/sionna-rk/scripts/run-k3-e2e-collector.sh'
```

Windows 保留 `Run-K3-E2E-Experiment.ps1`，并准备 Windows 版 iperf3。不要在脚本或文档中保存 SSH 密码。

K3 依赖：

```bash
sudo apt-get install -y iperf3 sysstat usbutils
command -v iperf3 pidstat mpstat sar
```

## 5. 实验前检查

K3 上启动常规系统，并确认真实 UE 已注册：

```bash
cd "$HOME/sionna-rk"
./scripts/k3-system.sh status
systemctl is-active mysql
sudo mysql -N -e "SELECT COUNT(*) FROM oai_db.users;"
pgrep -a nr-softmodem
pgrep -a amf
pgrep -a smf
ip -4 address show tun0
lsusb -t
```

Windows 上找出真实 UE 网卡的 `ifIndex` 和 `12.1.1.x` 地址：

```powershell
Get-NetAdapter | Format-Table Name,InterfaceDescription,ifIndex,Status
Get-NetIPAddress -AddressFamily IPv4 | Sort-Object InterfaceIndex
```

SSH 必须免交互，且实验用户只能获得启动临时 iperf 服务所需的 sudo 权限。脚本不会接受或保存密码。

## 6. 执行顺序

先做 10 秒冒烟测试：

```powershell
.\Run-K3-E2E-Experiment.ps1 -K3 '<K3_USER>@<K3_IP>' -InterfaceIndex <UE_IFINDEX> -Mode Smoke -Rounds 1
```

再做空载/轻载 RTT 基线：

```powershell
.\Run-K3-E2E-Experiment.ps1 -K3 '<K3_USER>@<K3_IP>' -InterfaceIndex <UE_IFINDEX> -Mode Baseline -Rounds 3 -WarmupSeconds 60 -MeasureSeconds 120
```

基线有效后执行上下行 UDP 阶梯：

```powershell
.\Run-K3-E2E-Experiment.ps1 -K3 '<K3_USER>@<K3_IP>' -InterfaceIndex <UE_IFINDEX> -Mode Step -Rounds 3 -Iperf iperf3.exe -WarmupSeconds 60 -MeasureSeconds 120 -CooldownSeconds 30
```

正式数据建议改成 `-Rounds 5`。先完整跑完原始版本，再应用一个优化并使用不同 `-Label` 重复，不要交错修改配置。

## 7. 结果文件

Windows 结果位于 `results-e2e/<时间-标签-模式-runN>/`：

| 文件 | 含义 |
|---|---|
| `metadata.json` | 模式、轮次、UE 地址和时间参数 |
| `warmup-ping.txt` | 预热连通性 |
| `measure-ping.txt` | Smoke/Baseline RTT 与丢包 |
| `UL-*.json`、`DL-*.json` | iperf3 原始上下行结果 |
| `summary.csv` | 每档方向、目标速率、接收吞吐、丢包、抖动和包数 |
| `outcome.txt` | 本轮有效性判定 |
| `k3/metadata-start.txt`、`metadata-end.txt` | 代码、二进制、CPU、网卡及服务状态 |
| `k3/pidstat-gnb.txt` | gNB CPU、内存和上下文切换 |
| `k3/mpstat.txt` | 分核 CPU 使用率 |
| `k3/frequency-temperature.csv` | 频率和温度时间序列 |
| `k3/gnb-journal.log` | 本轮 gNB 日志窗口 |
| `k3/amf.log`、`smf.log`、`upf.log` | 核心网日志副本 |
| `k3/nrL1_stats-start.log`、`nrL1_stats-end.log` | OAI 内部累计计时的窗口首尾快照，必须做差分后使用 |
| `k3/perf.data` | 49 Hz 调用栈原始采样，可重新生成报告 |
| `k3/perf-report-flat.txt` | gNB 函数级 Self 热点 |
| `k3/perf-report-callgraph.txt` | 带调用关系的 gNB 热点报告 |
| `k3/SHA256SUMS` | K3 结果完整性校验 |

端到端主表至少包含：日期、标签、轮次、方向、目标速率、接收吞吐、丢包率、抖动、RTT、有效性、失效原因。原始 JSON 和日志必须保留，不能只保留汇总均值。

## 8. 验收建议

冒烟测试只验证路径；Baseline 用于判断会话能否稳定；Step 用于寻找吞吐拐点。项目可暂用以下验收线：Baseline Ping 响应率 ≥99%，每档接收吞吐 ≥目标 95%，UDP 丢包 ≤1%，实验期间服务和 UE 地址不变。最终候选速率还应连续运行至少 30 分钟；短阶梯不能证明长时间稳定。

## 9. 与物理层热点计时联动

若要解释某档速率为何下降，应在完全相同的稳定负载窗口采集 OAI 起点/终点累计统计并做窗口差分。没有双快照时，不得把启动以来累计均值当作该档业务的模块耗时。优先关联 `feprx`、PUSCH inner-receiver 及其子项、UL LDPC、DLSCH encoding、OFDM/IFFT，同时检查调用次数是否符合当前 PRB、TDD 和业务方向。

窗口平均耗时按累计量恢复，不可直接用两个累计平均值相减：

```text
窗口调用数 = end.trials - start.trials
窗口总耗时 = end.avg_us × end.trials - start.avg_us × start.trials
窗口平均耗时 = 窗口总耗时 / 窗口调用数
```

`perf` 与 OAI 内置计时回答不同问题：前者定位具体函数、内核和 USB 路径，后者定位物理层模块。K3 PMU 上不要同时运行基于硬件 cycles 的 `perf stat` 与 `perf record`，否则 `perf record` 可能没有样本；进程 CPU、上下文切换和分核负载由 `pidstat/mpstat` 记录。
