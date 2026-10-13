#!/usr/bin/env bash
# ============================================================
# 10-install-host.sh
#
# 安装 Debian/Ubuntu 宿主机必需的 KVM/QEMU/libvirt 软件包。
# 已安装的软件包不会重复处理；apt update 默认按需执行。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/10-install-host.sh [--config FILE] [--dry-run] [--yes]

说明:
  默认按需安装宿主机依赖，不会自动重启系统。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root

log_info "开始安装/检查宿主机虚拟化依赖"

# ---------- 基础包 ----------
PKGS=(
  qemu-system-x86
  qemu-utils
  libvirt-daemon-system
  libvirt-clients
  virtinst
  ovmf
  dnsmasq-base
)

if is_true "${INSTALL_COCKPIT:-1}"; then
  PKGS+=(cockpit cockpit-machines)
fi

if is_true "${INSTALL_VIEWER:-1}"; then
  PKGS+=(virt-viewer)
fi

if [[ "${INSTALL_METHOD:-manual-iso}" == "cloud-init" ]]; then
  PKGS+=(cloud-image-utils genisoimage curl openssh-client)
fi

# ---------- 检查已安装情况 ----------
MISSING=()
for pkg in "${PKGS[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    MISSING+=("$pkg")
  fi
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  log_skip "所需软件包均已安装"
else
  log_info "待安装软件包: ${MISSING[*]}"
fi

# ---------- apt update ----------
APT_UPDATE_MODE="${APT_UPDATE_MODE:-auto}"
NEED_UPDATE=false
case "$APT_UPDATE_MODE" in
  always|true|yes|1) NEED_UPDATE=true ;;
  auto) [[ ${#MISSING[@]} -gt 0 ]] && NEED_UPDATE=true ;;
  never|false|no|0) NEED_UPDATE=false ;;
  *) die "APT_UPDATE_MODE 只支持 auto/always/never: $APT_UPDATE_MODE" ;;
esac

if [[ "$NEED_UPDATE" == "true" ]]; then
  log_info "执行 apt-get update"
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
else
  log_skip "跳过 apt-get update"
fi

# ---------- 安装缺失包 ----------
if [[ ${#MISSING[@]} -gt 0 ]]; then
  log_info "安装软件包"
  run_cmd env DEBIAN_FRONTEND=noninteractive \
    apt-get -o DPkg::Lock::Timeout=300 install -y "${MISSING[@]}"
else
  log_skip "没有需要安装的软件包"
fi

# ---------- 校验工具 ----------
if is_true "${DRY_RUN:-false}"; then
  log_skip "dry-run 模式，跳过安装结果校验"
else
  require_cmd virsh qemu-img virt-install
  log_ok "libvirt/QEMU/virt-install 工具可用"
fi

state_set "host_packages" "done"
log_ok "宿主机依赖处理完成"
