# KVM 虚拟机部署项目阶段规划

> 文档定位：本文件记录 KVM 虚拟机部署模板的总体设计、阶段划分、当前进度和剩余任务。
> 目标目录：`templates/kvm_vm/`

---

## 1. 项目目标

在 Debian/Ubuntu 宿主机上实现一套可独立执行、也可统一编排的 KVM 虚拟机部署流程，覆盖：

1. 宿主机环境预检
2. KVM/QEMU/libvirt/Cockpit 依赖安装
3. KVM 内核模块加载与 `/dev/kvm` 校验
4. libvirt 服务配置
5. Cockpit 端口配置
6. 防火墙按需配置
7. libvirt 网络配置
8. 存储池与 qcow2 磁盘准备
9. domain XML 生成与定义
10. 虚拟机启动与控制台信息输出
11. 系统安装完成后的收尾
12. 状态查看、销毁和诊断

核心要求：

- 单一职责：一个脚本只做一件事。
- 可独立执行：每个脚本可以单独运行。
- 可统一编排：由 `deploy.sh` 按阶段串联。
- 幂等：重复执行不破坏已有 VM/磁盘/网络。
- 真实状态优先：状态文件只是缓存，实际状态以 libvirt/systemd/磁盘为准。
- 默认安全：图形端口只监听本机，不默认开放防火墙。
- 不写真实密码、token、私钥。

---

## 2. 总体目录结构

```text
templates/kvm_vm/
├── deploy.sh                         # 顶层编排器
├── README.md                         # 使用说明
├── config/
│   ├── default.conf.template         # 配置模板
│   └── default.conf                  # 用户复制后修改，不提交真实敏感信息
├── lib/
│   ├── common.sh                     # 日志、配置加载、参数解析、基础校验
│   ├── state.sh                      # 状态文件、锁
│   └── libvirt.sh                    # virsh 辅助函数
├── scripts/
│   ├── 00-preflight.sh
│   ├── 10-install-host.sh
│   ├── 11-enable-kvm.sh
│   ├── 20-configure-libvirt.sh
│   ├── 21-configure-cockpit.sh
│   ├── 22-configure-firewall.sh
│   ├── 30-configure-network.sh
│   ├── 40-prepare-storage.sh
│   ├── 50-generate-domain.sh
│   ├── 51-define-domain.sh
│   ├── 60-start-vm.sh
│   ├── 70-cloud-install.sh           # 可选：cloud-init 自动安装
│   ├── 80-finalize-vm.sh
│   ├── 90-destroy-vm.sh
│   └── status.sh
├── templates/
│   └── cloud-init/
│       ├── user-data.template
│       └── meta-data.template
└── tests/
    └── syntax-check.sh               # 可选：静态检查入口
```

运行时路径：

```text
/var/lib/kvm-deploy/<vm-name>/state       # 阶段状态
/var/lib/kvm-deploy/<vm-name>/domain.xml  # 生成的 domain XML
/var/log/kvm-deploy/<vm-name>-<时间>.log  # 编排日志
/var/lock 或状态目录内的 lock 文件          # 并发锁
```

---

## 3. 脚本职责

| 脚本 | 职责 | 是否修改系统 |
|---|---|---|
| `00-preflight.sh` | 检查发行版、架构、CPU 虚拟化、`/dev/kvm`、内存、磁盘、ISO、端口 | 否 |
| `10-install-host.sh` | 安装 KVM/QEMU/libvirt/Cockpit 等依赖 | 是 |
| `11-enable-kvm.sh` | 按 CPU 厂商加载 `kvm_intel/kvm_amd`，验证 `/dev/kvm` | 是 |
| `20-configure-libvirt.sh` | 启动并校验 libvirt，兼容 `libvirtd` 和模块化 daemon | 是 |
| `21-configure-cockpit.sh` | 配置 Cockpit 端口并校验监听 | 是 |
| `22-configure-firewall.sh` | 按需开放 Cockpit 端口，不自动启用防火墙 | 是 |
| `30-configure-network.sh` | 确保 libvirt 网络存在、active、autostart | 是 |
| `40-prepare-storage.sh` | 准备存储池和 qcow2 磁盘，不覆盖已有磁盘 | 是 |
| `50-generate-domain.sh` | 用 `virt-install --print-xml` 生成 domain XML | 是，写状态目录 |
| `51-define-domain.sh` | 将 XML 定义到 libvirt，已存在则跳过 | 是 |
| `60-start-vm.sh` | 启动 VM，等待 running，输出控制台地址 | 是 |
| `70-cloud-install.sh` | 可选：cloud-init 自动安装并等待完成 | 是 |
| `80-finalize-vm.sh` | 弹出 ISO、调整启动顺序、设置 autostart | 是 |
| `90-destroy-vm.sh` | 停止并删除 VM 定义，按需删除磁盘 | 是，危险 |
| `status.sh` | 查看宿主机和 VM 状态 | 否 |

---

## 4. 配置约定

配置模板：`config/default.conf.template`

主要配置项：

```bash
VM_NAME="debian13-vm"
VM_VCPU=4
VM_RAM_MB=4096
VM_DISK_SIZE_GB=40
VM_DISK_PATH=""                 # 留空自动生成
STORAGE_POOL="default"

INSTALL_METHOD="manual-iso"     # manual-iso / cloud-init
ISO_PATH="/path/to/debian-13.iso"
OS_VARIANT="auto"

VM_NETWORK="default"
VM_GRAPHICS="spice"             # spice / vnc / none
VM_GRAPHICS_PORT="auto"
VM_LISTEN="127.0.0.1"
VM_VIDEO="auto"

VM_FIRMWARE="bios"              # bios / uefi
VM_MACHINE="q35"                # q35 / pc
VM_CPU_MODE="host-passthrough"
VM_MAC="auto"
VM_AUTOSTART=1
VM_GUEST_AGENT=1

COCKPIT_PORT=9091
INSTALL_COCKPIT=1
INSTALL_VIEWER=1
OPEN_FIREWALL="none"            # none / ufw / firewalld
FIREWALL_ALLOW_CIDR=""

LIBVIRT_URI="qemu:///system"
KVM_STATE_ROOT="/var/lib/kvm-deploy"
KVM_LOCK_TIMEOUT=30
```

约定：

- 所有脚本先加载 `lib/common.sh`。
- 每个脚本支持 `--config FILE`。
- 修改类脚本支持 `--dry-run`。
- 危险脚本支持 `--yes`，否则必须交互确认。
- 所有 `virsh` 命令显式使用 `qemu:///system`。
- 输出统一使用 `[INFO]`、`[WARN]`、`[ERROR]`、`[OK]`、`[SKIP]`。

---

## 5. 阶段划分

### Phase 0：文档与骨架

- [x] 创建 `templates/kvm_vm/` 目录
- [x] 创建 `config/default.conf.template`
- [x] 创建 `lib/common.sh`
- [x] 创建 `lib/state.sh`
- [ ] 创建 `lib/libvirt.sh`
- [ ] 在 `common.sh` 末尾加载 `state.sh` 和 `libvirt.sh`
- [ ] 创建 `README.md`

验收：

- `bash -n` 全部通过。
- `lib/common.sh` 可被其他脚本安全 source。
- 无配置文件时执行 `--help` 仍可查看用法。

### Phase 1：预检与宿主安装

- [ ] `scripts/00-preflight.sh`
- [ ] `scripts/10-install-host.sh`
- [ ] `scripts/11-enable-kvm.sh`

验收：

- 能检测 Debian/Ubuntu、x86_64、CPU 虚拟化。
- `/dev/kvm` 缺失时给出明确指引。
- 能按需安装宿主依赖，不重复 apt update/install。
- 能加载 `kvm_intel` 或 `kvm_amd` 并验证 `/dev/kvm`。

### Phase 2：libvirt 与管理面

- [ ] `scripts/20-configure-libvirt.sh`
- [ ] `scripts/21-configure-cockpit.sh`
- [ ] `scripts/22-configure-firewall.sh`

验收：

- 兼容 `libvirtd.service` 和 `virtqemud.socket` 等模块化架构。
- Cockpit 端口配置可重复执行，端口实际监听。
- 默认不自动改防火墙；显式配置时才开放端口。

### Phase 3：网络与存储

- [ ] `scripts/30-configure-network.sh`
- [ ] `scripts/40-prepare-storage.sh`

验收：

- default 网络缺失时能尝试定义并启动。
- 网络 active 且 autostart。
- 磁盘已存在时不覆盖，容量不足时只扩容。
- 优先使用 `virsh vol-create-as` 处理 owner/permission/security label。

### Phase 4：定义并启动 VM

- [ ] `scripts/50-generate-domain.sh`
- [ ] `scripts/51-define-domain.sh`
- [ ] `scripts/60-start-vm.sh`

验收：

- 使用 `virt-install --print-xml` 生成 XML。
- VM 已存在时不覆盖。
- 启动后等待 running，并输出 `virsh domdisplay` 实际地址。
- 图形端口支持 auto，不写死 `5901`。

### Phase 5：收尾、销毁、状态

- [ ] `scripts/80-finalize-vm.sh`
- [ ] `scripts/90-destroy-vm.sh`
- [ ] `scripts/status.sh`

验收：

- 能弹出 ISO 并校验。
- 能设置硬盘优先启动。
- 能设置 autostart。
- 销毁默认保留磁盘，`DELETE_DISK=1` 时才删除。
- 状态脚本只读，不修改系统。

### Phase 6：编排器

- [ ] `deploy.sh`
- [ ] 支持 `all`
- [ ] 支持 `host`
- [ ] 支持 `vm`
- [ ] 支持 `create`
- [ ] 支持 `start`
- [ ] 支持 `finalize`
- [ ] 支持 `destroy`
- [ ] 支持 `status`
- [ ] 支持单阶段执行
- [ ] 支持 `--config`
- [ ] 支持 `--dry-run`
- [ ] 支持 `--yes`
- [ ] 支持 `--only`
- [ ] 支持 `--from`

验收：

- `./deploy.sh --help` 可用。
- `./deploy.sh preflight` 可单独执行。
- `./deploy.sh all` 按主线顺序执行。
- `--dry-run` 不产生实际修改。

### Phase 7：文档与集成

- [ ] `templates/kvm_vm/README.md`
- [ ] 更新 `docs/templates.md`
- [ ] 更新根 `README.md`
- [ ] 可选：`tests/syntax-check.sh`
- [ ] 可选：`scripts/diagnose.sh`

验收：

- 新用户能根据 README 完成配置和部署。
- 模板索引能找到 `kvm_vm`。
- 静态检查命令可复现。

### Phase 8：cloud-init 自动安装（可选）

- [ ] `scripts/70-cloud-install.sh`
- [ ] `templates/cloud-init/user-data.template`
- [ ] `templates/cloud-init/meta-data.template`
- [ ] 支持 Debian Generic Cloud 镜像
- [ ] 支持 checksum 校验
- [ ] 支持 `cloud-localds` 生成 seed.iso
- [ ] 支持 SSH key
- [ ] 支持等待 cloud-init 完成

验收：

- 无人值守安装可用。
- 安装完成后自动进入可 SSH 状态。
- 不依赖明文密码。

---

## 6. 当前实际进度

截至本次更新，主线文件已完成：

```text
templates/kvm_vm/
├── deploy.sh
├── README.md
├── config/default.conf.template
├── lib/
│   ├── common.sh
│   ├── state.sh
│   └── libvirt.sh
├── templates/cloud-init/
│   ├── user-data.template
│   └── meta-data.template
├── tests/syntax-check.sh
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
    ├── 70-cloud-install.sh
    ├── 80-finalize-vm.sh
    ├── 90-destroy-vm.sh
    ├── diagnose.sh
    └── status.sh
```

已完成：

- 全部脚本 `bash -n` 语法检查。
- `common.sh` 可正常 source `state.sh` 和 `libvirt.sh`。
- `deploy.sh --help`、子脚本 `--help` 可用。
- 使用临时配置测试了 `load_config` 和派生磁盘路径。
- cloud-init 自动安装脚本和参考模板。
- `diagnose.sh` 和 `tests/syntax-check.sh`。

尚未完成：

- 真实 Debian/Ubuntu 宿主机验收。
- `shellcheck` 静态检查（当前环境未安装）。
- 多 VM 并发、端口自动分配等增强测试。
- BIOS/UEFI、SPICE/VNC、桥接网络等矩阵测试。

## 7. 剩余任务优先级

### P0：主线必须完成

1. `lib/libvirt.sh`
2. `common.sh` 加载 `state.sh` / `libvirt.sh`
3. `00-preflight.sh`
4. `10-install-host.sh`
5. `11-enable-kvm.sh`
6. `20-configure-libvirt.sh`
7. `21-configure-cockpit.sh`
8. `22-configure-firewall.sh`
9. `30-configure-network.sh`
10. `40-prepare-storage.sh`
11. `50-generate-domain.sh`
12. `51-define-domain.sh`
13. `60-start-vm.sh`
14. `80-finalize-vm.sh`
15. `90-destroy-vm.sh`
16. `status.sh`
17. `deploy.sh`
18. `README.md`

### P1：质量与集成

1. 更新 `docs/templates.md`
2. 更新根 `README.md`
3. 全量 `bash -n`
4. `shellcheck`
5. `--help` 无配置测试
6. `--dry-run all` 测试
7. 可选 `diagnose.sh`

### P2：增强

1. cloud-init 自动安装
2. 多 VM 配置示例
3. 静态 MAC + DHCP 租约
4. 快照/备份
5. 桥接网络
6. CPU 绑核、hugepages 等高级配置

---

## 8. 实施顺序

```text
1. 补 lib/libvirt.sh
2. 补 common.sh 对 state/libvirt 的加载
3. 补 00-preflight.sh
4. 补 10-install-host.sh
5. 补 11-enable-kvm.sh
6. 补 20-configure-libvirt.sh
7. 补 21-configure-cockpit.sh
8. 补 22-configure-firewall.sh
9. 补 30-configure-network.sh
10. 补 40-prepare-storage.sh
11. 补 50-generate-domain.sh
12. 补 51-define-domain.sh
13. 补 60-start-vm.sh
14. 补 80-finalize-vm.sh
15. 补 90-destroy-vm.sh
16. 补 status.sh
17. 补 deploy.sh
18. 补 README.md
19. 更新 docs/templates.md / 根 README.md
20. 静态检查和 dry-run 验证
21. 可选 cloud-init
```

---

## 9. 关键风险

1. Debian 13 / 新 libvirt 可能使用模块化 daemon，不能只依赖 `libvirtd.service`。
2. 图形端口不能写死，否则多 VM 冲突。
3. 预创建 qcow2 时必须考虑 `libvirt-qemu` 属主、AppArmor、SELinux。
4. `virtual size` 与 `file size` 不同，磁盘扩容只能扩容不能缩小。
5. 修改 Cockpit/防火墙端口有锁死 SSH 的风险，默认不自动改防火墙。
6. 状态文件不是真实状态，必须以 `virsh`、`systemctl`、磁盘、网络实际状态为准。
7. 手动 ISO 安装不能做成阻塞编排阶段，否则不适合非交互执行。
8. `virt-install --print-xml`、`virsh change-media`、`virt-xml --boot` 的语法需要按实际版本验证。

---

## 10. 验收清单

- [ ] 全新 Debian 12/13 宿主机可以完成 `./deploy.sh all`
- [ ] Ubuntu 22.04/24.04 可完成主线
- [ ] BIOS 与 UEFI 模式至少各验证一次
- [ ] 重复执行 `./deploy.sh all` 不破坏已有 VM
- [ ] 同名 VM 已存在时不会重复创建
- [ ] 磁盘已存在时不会覆盖
- [ ] VM 启动后可获得正确的 SPICE/VNC 地址
- [ ] `./deploy.sh finalize` 后 ISO 弹出、启动顺序为硬盘优先
- [ ] `./deploy.sh destroy` 默认保留磁盘
- [ ] `DELETE_DISK=1` 时才删除磁盘
- [ ] `shellcheck` 无高危告警
