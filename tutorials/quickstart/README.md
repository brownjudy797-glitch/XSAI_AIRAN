# Quickstart：运行 K3 真实 UE 端到端链路

目标：在已部署的 K3 上，使用固定 A 版接通真实 UE，获得 `12.1.1.x` 地址，并通过该 UE 地址访问 UPF 的 `12.1.1.1`。

```text
Windows ──USB── Quectel UE
                   │ 真实 5G 空口
                  B210 ──USB 3── K3：A 版 gNB → UPF → 12.1.1.1
                                          AMF / SMF / MySQL
```

## 0. 适用条件

- K3 已完成内核、UHD、OAI、核心网和测试 SIM 的部署，拥有项目目录 `/home/ubuntu/sionna-rk`。
- 已建立 `K3-A-20260922` 本地版本快照，`scripts/k3-fixed-baseline.py --check` 可以通过。
- B210 及 UE 接线、电源正常；只在实验室许可的屏蔽/衰减或合规射频环境下发射。馈线直连必须使用经确认的衰减方案，不能直接连接两个射频口。
- Windows 已安装 UE 驱动，并配置匹配核心网的 APN/DNN（当前为 `oai`）；测试 SIM 与核心网订阅匹配。不要把 SIM 密钥写进教程。
- SSH、Bash、Python 3、systemd、usbutils，以及 Windows PowerShell 可用。

**新机器请先完成部署。** 此教程不会安装依赖、导入数据库、创建基线、编译 OAI 或从不存在的 GitHub 地址拉取项目。脚本中的 `ProjectRoot` 是已部署项目路径，不是本教程目录。

## 1. 获取并放置教程文件

本地 Windows PowerShell，进入本 README 所在目录。替换 SSH 目标；不要保留示例尖括号：

```powershell
$K3Host = '<用户名>@<K3管理IP>'
ssh $K3Host 'mkdir -p /home/ubuntu/XSAI-tutorial'
scp ./k3-quickstart.sh "${K3Host}:/home/ubuntu/XSAI-tutorial/"
ssh $K3Host
```

`/home/ubuntu` 是当前部署账号目录；使用其他账号时，相应替换教程存放位置。固定基线仍绑定原项目绝对路径，不能简单搬目录后跳过校验。

## 2. K3：检查版本与设备（不启动、不重置）

在 **K3 Bash** 中执行：

```bash
bash /home/ubuntu/XSAI-tutorial/k3-quickstart.sh check
```

应看到 `baseline OK` 和 `Preflight passed`。检查涵盖固定文件、RISC-V 架构、启动器和 B210 USB 枚举。它不证明天线、射频收发或 UE 链路正常。

若报文件变化：停止操作，核对变更并建立新的版本记录，不重新冻结覆盖旧快照。若 B210 未找到：检查线缆、供电与 USB 3 接口；不要复位整条 USB 总线。

## 3. K3：启动并确认核心网连接

```bash
bash /home/ubuntu/XSAI-tutorial/k3-quickstart.sh start
bash /home/ubuntu/XSAI-tutorial/k3-quickstart.sh status
```

如果 gNB 已运行，脚本保持现状，不重启；只提示已运行，不把它当成端到端验收通过。未运行时调用固定启动器：按需启动核心网、应用既有网络与主机设置，再启动 A 版 gNB。

只检查**当前这次启动**的日志：

```bash
invocation=$(systemctl show k3-b200-gnb.service -p InvocationID --value)
journalctl "_SYSTEMD_INVOCATION_ID=$invocation" -n 100 --no-pager
```

确认 gNB 为 `active`，核心网组件在运行，当前日志包含 `Received NGSetupResponse from AMF`。如果启动器报告核心网已存在但不健康，不重复启动多个进程，转到故障表处理。

> 推荐入口只使用 `scripts/run-k3-b200.sh`。不使用 `start-full-cn5g-k3.sh`、旧 `ran_build/build`、B 版入口或 `.runtime` 中的诊断启动器。

## 4. Windows：连接 UE

回到 **Windows PowerShell**，查看实际网卡名称：

```powershell
Get-NetAdapter |
  Where-Object InterfaceDescription -Match 'Quectel' |
  Format-Table Name,ifIndex,Status
```

通过 Windows“设置 → 网络和 Internet → 手机网络”选择 UE，确认 APN 后连接。已经连接就保持现状，不执行飞行模式、AT 重置或核心网重启。

如需查看 AT 状态，先查实际 AT 口，在串口工具中只查询：

```text
AT+CPIN?
AT+COPS?
AT+C5GREG?
AT+QENG="servingcell"
```

当前实验 PLMN=`26299`、PCI=`0`、SSB ARFCN=`640320`。SIM 应为 READY；5G 注册状态应为已注册（1，或允许漫游场景下的 5）。`SEARCH`、`LIMSRV` 或其他运营商的小区，不算接入成功。`NOCONN` 不一定是故障，需结合注册和数据会话判断。

## 5. Windows：验证走 UE 的用户面

在本教程目录运行，网卡名替换为上一步现场结果：

```powershell
./Test-UePath.ps1 -InterfaceAlias '手机网络 2'
```

脚本要求该网卡已启用且具有唯一的 `12.1.1.x` 地址，然后执行源地址绑定的 Ping：

```powershell
ping.exe -4 -S <UE_IP> -n 10 12.1.1.1
```

这可避免不指定源地址而误走 Wi-Fi。检查终端的实际回复、丢包和耗时；脚本成功仅表示 Ping 返回成功状态，不保证 10 个包全部成功，更不代表最大吞吐或长时间稳定。

Windows 若阻止执行脚本，可在当前进程临时执行 `Set-ExecutionPolicy -Scope Process Bypass`，确认脚本内容后再运行；组织策略禁止时，请按上述命令手动检查，不修改系统级策略。

## 6. 记录本次结果

填写 [验收记录模板](acceptance-template.md)。分别记录：

1. 固定版本校验通过。
2. gNB 与核心网连接成功。
3. UE 注册且获得实验网地址。
4. 绑定 UE 地址的 Ping 回复及实际丢包数。

四项分开记录。不要把“服务 active”“UE 有信号”“用户曾反馈接通”写成四项全部通过。本教程不运行 iperf3，不生成正式 PHY 耗时或吞吐上限数据。

## 7. 停止（仅在确实需要时）

```bash
# K3 Bash：停止 gNB 和核心网，会中断现有 UE 业务
bash /home/ubuntu/XSAI-tutorial/k3-quickstart.sh stop
```

仅退出日志查看时用 Ctrl+C，不需要停止服务。不要在 gNB 运行时执行 `uhd_usrp_probe`、UHD 数据流测试或 USB 复位，避免争用 B210。

## 故障处理顺序

| 现象 | 先做什么 |
|---|---|
| 基线校验失败 | 核对变化文件，不绕过校验或覆盖基线 |
| gNB 已 active | 继续检查当前实例，不重复启动 |
| 无 NGSetupResponse | 检查当前实例日志、AMF 和网络地址 |
| UE 搜不到 26299 | 核对接线、射频路径、gNB 当前日志；暂不调大增益 |
| Msg3 成功但 Msg4 失败 | 保存同一时间段日志，不直接断言核心网或 UE 损坏 |
| 只有 169.254.x.x 地址 | 数据会话未就绪，先检查注册与 APN |
| 有 12.1.1.x 但 Ping 不通 | 检查 UPF、tun0、N3 及路由；公网 DNS 不是这一步的前提 |
| 0x139f / 网卡不存在 | 重新枚举 Windows 网卡，区分模块未恢复与无线未注册，不反复盲目重启 |

提交 issue 或分享记录时先脱敏：不公开 SIM 身份/密钥、数据库、密码、完整 `.env`、原始 AT/核心网日志。当前目录没有自动上传功能。
