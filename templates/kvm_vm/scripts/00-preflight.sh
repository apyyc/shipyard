#!/usr/bin/env bash
# ============================================================
# 00-preflight.sh
#
# 只读预检：
#   - 发行版、架构
#   - CPU 虚拟化标志、/dev/kvm
#   - 内存、磁盘空间、端口
#   - ISO 文件
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/00-preflight.sh [--config FILE] [--dry-run] [--yes]

说明:
  只读检查，不修改系统。
  /dev/kvm 不存在时先给出警告，由 11-enable-kvm.sh 尝试加载模块。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root

log_info "开始预检虚拟机配置: ${VM_NAME}"

# ---------- 发行版与架构 ----------
[[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，当前系统可能不受支持。"

OS_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-unknown}")"
OS_VER="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-unknown}")"

case "$OS_ID" in
  debian|ubuntu) log_info "宿主机系统: ${OS_ID} ${OS_VER}" ;;
  *) die "仅支持 Debian/Ubuntu 宿主机，当前检测到: ${OS_ID}" ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) log_info "CPU 架构: ${ARCH}" ;;
  *) die "当前模板仅面向 x86_64，检测到: ${ARCH}" ;;
esac

# ---------- 基础命令 ----------
for cmd in apt-get systemctl awk sed grep; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少基础命令: $cmd"
done
log_ok "基础命令可用"

# ---------- CPU 虚拟化 ----------
if grep -Eqm1 'vmx|svm' /proc/cpuinfo; then
  log_ok "CPU 支持硬件虚拟化（Intel VT-x 或 AMD SVM）"
else
  die "未检测到 vmx/svm。请在 BIOS/UEFI 中开启 CPU 虚拟化；若宿主机本身是虚拟机，还需开启嵌套虚拟化。"
fi

if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT_TYPE="$(systemd-detect-virt || true)"
  if [[ -n "$VIRT_TYPE" && "$VIRT_TYPE" != "none" ]]; then
    log_warn "当前系统运行在虚拟化环境中（${VIRT_TYPE}），请确认已开启嵌套虚拟化。"
  fi
fi

if [[ -c /dev/kvm ]]; then
  log_ok "/dev/kvm 存在"
else
  log_warn "/dev/kvm 不存在，稍后由 11-enable-kvm.sh 尝试加载 kvm 模块；如果加载失败，请检查 BIOS 或嵌套虚拟化。"
fi

# ---------- 内存与 CPU ----------
MEM_TOTAL_KB="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
if (( MEM_TOTAL_MB < VM_RAM_MB + 512 )); then
  die "宿主机内存不足：总内存约 ${MEM_TOTAL_MB} MB，计划分配 ${VM_RAM_MB} MB（建议至少再留 512 MB）。"
fi
log_ok "内存检查通过: 总内存约 ${MEM_TOTAL_MB} MB，计划分配 ${VM_RAM_MB} MB"

CPU_COUNT="$(nproc 2>/dev/null || echo 1)"
if (( VM_VCPU > CPU_COUNT )); then
  log_warn "VM_VCPU=${VM_VCPU} 超过宿主机可见 CPU 数 ${CPU_COUNT}，可能引起争用。"
else
  log_ok "vCPU 检查通过: ${VM_VCPU} / ${CPU_COUNT}"
fi

# ---------- 磁盘空间 ----------
DISK_PARENT="$(nearest_existing_dir "$(dirname "$VM_DISK_PATH")")"
DISK_AVAIL_KB="$(df -Pk "$DISK_PARENT" | awk 'NR==2 { print $4 }')"
DISK_AVAIL_GB=$((DISK_AVAIL_KB / 1024 / 1024))
if (( DISK_AVAIL_GB < VM_DISK_SIZE_GB + 5 )); then
  log_warn "磁盘可用空间约 ${DISK_AVAIL_GB} GB，小于建议值 $((VM_DISK_SIZE_GB + 5)) GB。qcow2 是精简置备，但实际使用时会继续增长。"
else
  log_ok "磁盘检查通过: 可用约 ${DISK_AVAIL_GB} GB"
fi
if (( DISK_AVAIL_GB < 5 )); then
  die "磁盘可用空间不足 5 GB: $DISK_PARENT"
fi

# ---------- ISO ----------
if [[ "$INSTALL_METHOD" == "manual-iso" ]]; then
  if [[ -f "$ISO_PATH" && -r "$ISO_PATH" ]]; then
    ISO_SIZE_MB="$(du -m "$ISO_PATH" | awk '{print $1}')"
    log_ok "ISO 可用: ${ISO_PATH} (约 ${ISO_SIZE_MB} MB)"
  else
    die "ISO 镜像不存在或不可读: ${ISO_PATH}"
  fi
else
  log_skip "INSTALL_METHOD=${INSTALL_METHOD}，跳过 ISO 检查"
fi

# ---------- 端口检查 ----------
if command -v ss >/dev/null 2>&1; then
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${COCKPIT_PORT}$"; then
    log_warn "端口 ${COCKPIT_PORT} 已被占用，Cockpit 修改端口前请确认冲突。"
  else
    log_ok "Cockpit 端口 ${COCKPIT_PORT} 当前空闲"
  fi

  if [[ "$(graphics_port)" != "auto" ]]; then
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$(graphics_port)$"; then
      log_warn "图形端口 $(graphics_port) 已被占用。"
    else
      log_ok "图形端口 $(graphics_port) 当前空闲"
    fi
  fi
else
  log_skip "未找到 ss，跳过端口检查"
fi

# ---------- 官方虚拟化自检（如果已安装） ----------
if command -v virt-host-validate >/dev/null 2>&1; then
  log_info "执行 virt-host-validate qemu"
  if virt-host-validate qemu; then
    log_ok "virt-host-validate 检查通过"
  else
    log_warn "virt-host-validate 报告了问题；如果只是 KVM 模块尚未加载，可继续执行 11-enable-kvm.sh。"
  fi
else
  log_skip "virt-host-validate 尚未安装，跳过（宿主安装后会再次检查）"
fi

log_ok "预检完成"
