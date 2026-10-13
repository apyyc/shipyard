# kvm_vm 模板

在 Debian/Ubuntu 宿主机上部署 KVM 虚拟机的分阶段脚本模板。

当前版本主线支持：

- 宿主机预检
- KVM/QEMU/libvirt/Cockpit 依赖安装
- KVM 内核模块加载
- libvirt 服务配置
- Cockpit 端口配置
- 按需配置防火墙
- libvirt default NAT 网络配置
- qcow2 磁盘准备
- domain XML 生成与定义
- 虚拟机启动
- 安装完成后的收尾
- 状态查看与销毁

cloud-init 自动安装为可选能力，使用 Generic Cloud 镜像 + NoCloud seed.iso。

## 目录结构

```text
kvm_vm/
├── deploy.sh
├── README.md
├── config/
│   └── default.conf.template
├── lib/
│   ├── common.sh
│   ├── state.sh
│   └── libvirt.sh
└── scripts/
    ├── 00-preflight.sh
    ├── 10-install-host.sh
    ├── 11-enable-kvm.sh
    ├── 20-configure-libvirt.sh
    ├── 21-configure-cockpit.sh
    ├── 22-configure-firewall.sh
    ├── 30-configure-network.sh
    ├── 40-prepare-storage.sh
    ├── 50-generate-domain.sh
    ├── 51-define-domain.sh
    ├── 60-start-vm.sh
    ├── 80-finalize-vm.sh
    ├── 90-destroy-vm.sh
    └── status.sh
```

## 前置条件

- Debian 12/13 或 Ubuntu 22.04/24.04
- x86_64 宿主机
- BIOS/UEFI 已开启 Intel VT-x 或 AMD SVM
- 宿主机本身是虚拟机时，已开启嵌套虚拟化
- root 或 sudo 权限
- 有可用的 Debian ISO 镜像
- 预留足够内存和磁盘空间

## 快速开始

在模板目录内执行：

```bash
cp config/default.conf.template config/default.conf
vim config/default.conf
```

至少修改：

```bash
VM_NAME="debian13-vm"
ISO_PATH="/var/lib/libvirt/images/debian-13.iso"
```

然后执行：

```bash
sudo ./deploy.sh preflight
sudo ./deploy.sh all
```

`all` 会执行：

```text
preflight
install-host
enable-kvm
configure-libvirt
configure-cockpit
configure-firewall
configure-network
prepare-storage
generate-domain
define-domain
start-vm
```

执行完成后，脚本会输出 SPICE/VNC 地址。通过 `remote-viewer` 或 Cockpit 控制台完成 Debian 安装。

安装完成后执行收尾：

```bash
sudo ./deploy.sh finalize
```

查看状态：

```bash
sudo ./deploy.sh status
```

销毁虚拟机：

```bash
sudo ./deploy.sh destroy
```

默认只删除 VM 定义，保留磁盘。需要同时删除磁盘时：

```bash
sudo DELETE_DISK=1 ./deploy.sh destroy --yes
```

## cloud-init 自动安装

配置示例：

```bash
INSTALL_METHOD="cloud-init"
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
CLOUD_IMAGE_SHA256=""
# 也可以直接指定本地镜像：
# CLOUD_IMAGE_PATH="/var/lib/libvirt/images/debian-13-genericcloud-amd64.qcow2"
```

执行自动安装：

```bash
sudo ./deploy.sh --config config/debian13-cloud.conf cloud
```

也可以只重新执行 cloud-init 阶段：

```bash
sudo ./deploy.sh --config config/debian13-cloud.conf cloud-install
```

未提供 `CLOUD_SSH_PUBKEY` / `CLOUD_SSH_PRIVATE_KEY` 时，脚本会在状态目录下自动生成一对临时 ed25519 key。

## 常用命令

```bash
sudo ./deploy.sh preflight
sudo ./deploy.sh host
sudo ./deploy.sh vm
sudo ./deploy.sh create
sudo ./deploy.sh start
sudo ./deploy.sh finalize
sudo ./deploy.sh destroy
sudo ./deploy.sh status
```

只执行单个阶段：

```bash
sudo ./deploy.sh configure-network
sudo ./deploy.sh prepare-storage
sudo ./deploy.sh generate-domain
sudo ./deploy.sh define-domain
sudo ./deploy.sh start-vm
```

使用自定义配置：

```bash
sudo ./deploy.sh --config config/debian13-vm1.conf all
```

覆盖 VM 名称：

```bash
sudo ./deploy.sh --vm test-vm all
```

从某个阶段开始：

```bash
sudo ./deploy.sh --from configure-network all
```

只执行指定阶段：

```bash
sudo ./deploy.sh --only prepare-storage --only define-domain all
```

dry-run：

```bash
sudo ./deploy.sh --dry-run all
```

注意：编排器级 `--dry-run` 只打印阶段脚本，不直接执行子脚本。单个子脚本也支持 `--dry-run`。

## 子脚本说明

| 脚本 | 作用 |
|---|---|
| `00-preflight.sh` | 只读预检 |
| `10-install-host.sh` | 安装宿主依赖 |
| `11-enable-kvm.sh` | 加载 KVM 模块并校验 `/dev/kvm` |
| `20-configure-libvirt.sh` | 启动 libvirt |
| `21-configure-cockpit.sh` | 配置 Cockpit 端口 |
| `22-configure-firewall.sh` | 按需配置防火墙 |
| `30-configure-network.sh` | 配置 libvirt default 网络 |
| `40-prepare-storage.sh` | 创建存储池和 qcow2 磁盘 |
| `50-generate-domain.sh` | 生成 domain XML |
| `51-define-domain.sh` | 定义 domain |
| `60-start-vm.sh` | 启动 VM |
| `70-cloud-install.sh` | cloud-init 自动安装 |
| `80-finalize-vm.sh` | 弹出 ISO、设置启动顺序、autostart |
| `90-destroy-vm.sh` | 删除 VM 定义，可选删除磁盘 |
| `status.sh` | 查看状态 |
| `diagnose.sh` | 收集系统/libvirt/VM 诊断信息 |

所有子脚本都支持：

```bash
--config FILE
--dry-run
--yes / -y
--help
```

## 状态与日志

运行时目录：

```text
/var/lib/kvm-deploy/<vm-name>/state
/var/lib/kvm-deploy/<vm-name>/domain.xml
/var/log/kvm-deploy/<vm-name>-<时间>.log
```

状态文件只是缓存，实际状态仍以 `virsh`、`systemctl`、磁盘和网络为准。

## 安全说明

- 图形控制台默认只监听 `127.0.0.1`。
- 默认不修改防火墙；需要时显式设置 `OPEN_FIREWALL`。
- 不会自动启用 `ufw` 或 `firewalld`，避免锁死 SSH。
- 销毁 VM 默认保留磁盘。
- `DELETE_DISK=1` 时必须二次确认或使用 `--yes`。
- 配置文件中不要写明文密码、token、私钥。

## 自检与诊断

语法检查：

```bash
./tests/syntax-check.sh
```

收集诊断包：

```bash
sudo ./scripts/diagnose.sh --config config/default.conf
```

诊断输出默认位于：

```text
/var/log/kvm-deploy/<vm-name>-diagnose-<时间>.txt
/var/log/kvm-deploy/<vm-name>-diagnose-<时间>.tar.gz
```

## 常见排错

预检通过但 `/dev/kvm` 不存在：

```bash
sudo ./deploy.sh enable-kvm
ls -l /dev/kvm
```

libvirt 连不上：

```bash
sudo systemctl status libvirtd
# 或模块化 libvirt：
systemctl status virtqemud.socket
sudo virsh -c qemu:///system list --all
```

Cockpit 端口未监听：

```bash
systemctl status cockpit.socket
ss -lntp | grep 9091
journalctl -u cockpit.socket --no-pager -n 50
```

查看 VM 控制台地址：

```bash
sudo virsh -c qemu:///system domdisplay <vm-name>
```

查看 VM 磁盘：

```bash
sudo virsh -c qemu:///system domblklist <vm-name>
```
