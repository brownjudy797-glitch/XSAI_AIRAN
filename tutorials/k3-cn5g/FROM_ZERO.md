<!-- SPDX-License-Identifier: Apache-2.0 -->
# CN5G 与真实 UE：新机器必须补齐的步骤

先完成 [无射频 RFsim 构建与验证](../reproduction/README.md)，再进入本页。2026-10-29 的现场核查发现：运行机采用源码布局、特定 AMF 选择器和 `phy-fixed-build-20260922`；公开 CN5G Release 使用 `/opt` 布局。两者不能照搬启动路径。本文补齐准备与验收门槛；本次没有在运行中的 K3 重装核心网、导入订阅、重启内核或发射射频，因此不宣称新机器整套验收已经通过。

2026-10-30 后续已完成 Release 安装器、独立新库、真实 UE 注册与用户面，以及上下行目标速率窗口，见 [验收记录](../../benchmarks/results/k3-20261030/README.md)。这是在现有 K3 OS 上的独立新装验收，没有重新烧录 OS；本页 USRP 从源码重新构建配方仍未在该次执行。

## 1. 选择唯一安装布局

新机器按 [原 CN5G 教程第 5 节](README.md) 安装 Release。该教程包含 SCTP 检查、需要时安装内核、安装入口 `mysql-serve` 包名修正、包散列检查与 B210 安装器。已有现场源码部署按 [Quickstart](../quickstart/README.md) 使用部署守卫，不运行 Release 安装器覆盖它。

外部安装仓库本次审阅提交是 `503f6b3fc8376e213ff69b39f070e107bbea62bf`，Release 是 `v2026.09.13`。安装脚本默认使用 latest；部署时同时记录安装仓库提交、Release 标签、压缩包 SHA256，避免把将来的 latest 当作本次固定版本。新机不应直接执行旧教程第 6.2 节：那一节要求完整源码布局和本地配置。

## 2. 本机网络配置必须先生成

在安装器目录创建仅本机使用的 `config.env`，将下面的 HOST_IP、WAN_IF 改为 `ip -4 route get 1.1.1.1` 和 `ip -br address` 确认的实际值；不能照抄原 K3 的地址。默认 dummy 地址须与现有网络无冲突。

```bash
umask 077
cat > config.env <<'EOF'
HOST_IP=192.0.2.10
WAN_IF=eth0
UPF_N3_IP=192.168.71.134
GNB_N3_IP=192.168.71.140
UE_SUBNET=12.1.1.0/24
UE_GATEWAY=12.1.1.1
EOF
${EDITOR:-nano} config.env
```

`192.0.2.10` 是文档占位地址，必须修改后才传给 `./install-online.sh cn5g "$PWD/config.env"`。该安装器会导入数据库并复制配置，不能用在已有订户数据库的机器上当作“更新”。

要精确使用本次验收包，可在已克隆的安装仓库内改用固定下载路径，绕过 `latest`（仍需先完成前页 SCTP 检查）。确认本节 `config.env` 已改好后执行：

```bash
(
set -e
git diff --quiet
git diff --cached --quiet
git checkout --detach 503f6b3fc8376e213ff69b39f070e107bbea62bf
sudo apt-get update
sudo apt-get install -y ca-certificates curl zstd iproute2 iptables mysql-server
(
set -e
cd 02-cn5g
test ! -e cn5g-payload.tar.zst
curl -fL --retry 3 --connect-timeout 20 \
  https://github.com/brownjudy797-glitch/sionna-rk-k3-porting/releases/download/v2026.09.13/cn5g-riscv64-v2.1.0.tar.zst \
  -o cn5g-riscv64-v2.1.0.tar.zst
printf '%s  %s\n' 0370f100cc156f1bc5d5c58ae6a609c4488d10dfba76dff59f0eb8732e3826ad cn5g-riscv64-v2.1.0.tar.zst | sha256sum --check -
ln -s cn5g-riscv64-v2.1.0.tar.zst cn5g-payload.tar.zst
)
sudo ./install.sh cn5g "$PWD/config.env"
)
```

使用这条固定路径时无需再执行 `install-online.sh cn5g`。下载慢时可在电脑下载相同包后传到 K3，仍按上述 SHA256 在 K3 校验。已有数据库和配置的机器不要直接执行此初始化；本次验收使用独立新库和私有目录保留原环境。

安装后逐项检查 `/etc/sionna-rk-k3/cn5g/` 中 AMF/SMF/UPF 配置：PLMN 的 MCC/MNC 与 MNC 位数、TAC、S-NSSAI 的 SST/SD、DNN，以及 gNB 的 AMF N2 地址和本地 N3 地址。真实 USIM、UE 请求、gNB、核心网四者必须一致。安装器的地址替换不等于完成这些参数的配置。

**本次实际发现的缺步**：Release 模板仍为 PLMN `208/95`、TAC `0xa000`，DNS 指向旧实验地址。安装后、启动 NF 前，下面把这三个模板调整为本次已验收的 `262/99`、TAC 1；其他测试卡先修改代码中的参数，并同步 gNB 的 MNC 位数。脚本先核对三份配置、备份原件，再写入，不修改订阅和数据库密码：

```bash
sudo python3 - <<'PY'
from pathlib import Path
import datetime, ipaddress, re, shutil, uuid
root=Path('/etc/sionna-rk-k3/cn5g')
mcc,mnc,tac='262','99',1
primary,secondary='8.8.8.8','1.1.1.1'
assert len(mcc)==3 and mcc.isdigit() and len(mnc) in (2,3) and mnc.isdigit()
assert 0<tac<65536
ipaddress.IPv4Address(primary);ipaddress.IPv4Address(secondary)
changes={}
pattern=r'(?m)^([ \t]*(?:-[ \t]*)?mcc:[ \t]*)208([ \t]*\n[ \t]+mnc:[ \t]*)95(?=[ \t]*(?:#.*)?$)'
for name in ['amf.yaml','smf.yaml','upf.yaml']:
    file=root/name
    if file.is_symlink(): raise SystemExit('Refusing config symlink: '+name)
    text=file.read_text()
    text,count=re.subn(pattern,lambda m:m[1]+mcc+m[2]+mnc,text)
    expected=rf'(?m)mcc:[ \t]*{mcc}\n[ \t]+mnc:[ \t]*{mnc}[ \t]*(?:\n|$)'
    if count!=2 and not (count==0 and len(re.findall(expected,text))>=2):
        raise SystemExit('Unexpected template; inspect before editing: '+name)
    text,tac_count=re.subn(r'(?m)^([ \t]*tac:[ \t]*)(?:0x[0-9a-fA-F]+|[0-9]+)[ \t]*$',lambda m:m[1]+str(tac),text)
    if tac_count!=1: raise SystemExit('Unexpected TAC structure: '+name)
    text=re.sub(r'(?m)^([ \t]+primary_ipv4:[ \t]*)"[^"]+"',lambda m:m[1]+'"'+primary+'"',text)
    text=re.sub(r'(?m)^([ \t]+secondary_ipv4:[ \t]*)"[^"]+"',lambda m:m[1]+'"'+secondary+'"',text)
    changes[file]=text
backup=root.parent/('cn5g-before-profile-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8])
backup.mkdir(mode=0o700)
for file,text in changes.items(): shutil.copy2(file,backup/file.name)
for file,text in changes.items(): file.write_text(text)
print('Profile updated; original files retained at',backup)
PY
```

这一转换按本次 Release 的已核对模板编写；其他版本应先比对结构。完整的新机验收与边界见 [2026-10-30 记录](../../benchmarks/results/k3-20261030/README.md)。

| 接口 | 必须核对 |
|---|---|
| N2 | gNB 到 AMF 的 SCTP/38412 路由与监听 |
| N3 | gNB 和 UPF 的 UDP/2152 地址、路由与防火墙 |
| N4 | SMF–UPF UDP/8805、PFCP association |
| UE 用户面 | UE 网段路由、IPv4 forwarding、出口 NAT 和 DNS |

检查安装器生成的规则再开始用户面验收；不要清空主机现有防火墙。停服务和修改规则只针对选定安装布局。

## 3. 数据库与测试 USIM 订阅

Release 安装会导入 schema，不能把数据库存在理解成已配置自己的 USIM。使用本仓库新增工具先做只读 schema 检查，再在**新安装的测试核心网**插入自己的测试 USIM。IMSI、K、OPc 由测试卡供应商或本地制卡流程提供，OP 与 OPc 不可互换。没有这些值不能进行 AKA 注册。

```bash
cd "$HOME/XSAI_AIRAN-repro"
sudo -v
python3 scripts/provision-test-subscriber.py check
python3 scripts/provision-test-subscriber.py add --apply
```

工具针对现场审阅过的 `oai_db.users` schema，K/OPc 交互隐藏输入，不出现在命令行；已有 IMSI 会拒绝写入，不覆盖密钥或重置 SQN。schema 不同时停止并检查对应核心网版本。SQN 必须与新测试卡匹配，认证失败不可通过反复重置数据库 SQN 掩盖。数据库与本地配置应单独备份，不提交到 GitHub。

## 4. UHD 与真实射频构建

RFsim 构建明确关闭 USRP，不能拿它直接启动 B210。先安装匹配目标架构的 `libuhd-dev`、`uhd-host`，运行 `uhd_find_devices`、`uhd_usrp_probe` 检查固件、FPGA、USB3 与设备序列号；需要镜像时使用 UHD 自带的 `uhd_images_downloader`。记录 UHD 版本和 B210 序列号于本地验收材料。

使用第一个流程准备好的独立 OAI 源码与私有依赖，另建射频构建目录，不覆盖 RFsim 产物：

```bash
export XSAI_REPRO_WORK="$HOME/xsai-repro-20261029"
sudo apt-get install -y libuhd-dev uhd-host
uhd_find_devices
uhd_usrp_probe
cmake -S "$XSAI_REPRO_WORK/oai" -B "$XSAI_REPRO_WORK/build-usrp" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER=/usr/bin/gcc-16 -DCMAKE_CXX_COMPILER=/usr/bin/g++-16 \
  -DASN1C_EXEC="$XSAI_REPRO_WORK/deps/asn1c/bin/asn1c" \
  -DCMAKE_C_FLAGS="-I$XSAI_REPRO_WORK/deps/include -march=rv64gcv_zba_zbb_zbs -mabi=lp64d -mrvv-vector-bits=scalable" \
  -DCMAKE_CXX_FLAGS="-I$XSAI_REPRO_WORK/deps/include -march=rv64gcv_zba_zbb_zbs -mabi=lp64d -mrvv-vector-bits=scalable" \
  -DENABLE_PLUGINS=ON -DENABLE_CUDA=OFF -DENABLE_DGX_OPTIMIZATIONS=OFF \
  -DOAI_SIMU=ON -DOAI_USRP=ON -DAVX2=OFF -DAVX512=OFF
cmake --build "$XSAI_REPRO_WORK/build-usrp" \
  --target nr-softmodem oai_usrpdevif dfts params_libconfig --parallel 4
test -r "$XSAI_REPRO_WORK/build-usrp/liboai_device.so"
ldd "$XSAI_REPRO_WORK/build-usrp/liboai_device.so"
```

这里是 K3 的射频构建配方，本次未重编与实测该分支。旧 `build-oai-native.sh` 已修正为只有 `--usrp` 才要求 UHD/构建设备插件；它仍是旧源码布局辅助脚本，新建独立工作区使用本页显式构建命令。

## 5. 启动与逐级验收

Release 核心网使用 `/opt/sionna-rk-k3/cn5g/scripts/start-cn5g.sh` 和同目录 status/stop 脚本；运行前检查对应 `/etc` 配置。不要用旧源码布局的 `start-full-cn5g-k3.sh` 管理 `/opt` 安装。

gNB 配置从工作区 `oai/targets/PROJECTS/GENERIC-NR-5GC/CONF/` 中的 SA band78 USRP 示例复制到本地私有目录，按照上表填写 PLMN/TAC/AMF/N3、B210 序列号、频率和增益。在自己的获准射频实验环境完成配置后，从 `build-usrp` 目录用 `sudo ./nr-softmodem -O /绝对路径/本机gnb.conf --sa` 启动。不要把 `--phy-test --noS1 --rfsim` 带到真实注册路线。现场 AI 演示脚本还要求专用模型、配置和部署守卫，不能替代新机传统路径验收。

按顺序保存本次证据，每一步通过才进入下一步：

1. `ldd` 无缺库，SCTP 可用，AMF 监听 38412，SMF–UPF PFCP association 成功。
2. gNB 收到 NG Setup Response；仅有进程不算连接成功。
3. UE 注册、AKA 和安全模式成功；密钥错误应回查本地订阅。
4. PDU Session Accept，UE 获得该部署分配的地址，不能要求一定是历史地址 `12.1.1.130`。
5. UE 到 UPF 连通，再检查公网 IP、DNS，最后做带时长、方向、负载和丢包记录的 iperf 测试。
6. 使用这一布局的停止器退出，再次启动复验。保存配置散列、提交、内核、UHD、日志和结果，不对原始数据做覆盖清理。

本页解决缺失前提与错误路径，不把硬件相关配置伪装成通用一键命令。AI/A100、51/106 RB AI 适配、nearRT-RIC、香山 XSAI 仍按项目各自的验证边界处理。
