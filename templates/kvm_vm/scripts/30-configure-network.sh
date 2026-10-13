#!/usr/bin/env bash
# ============================================================
# 30-configure-network.sh
#
# 确保 libvirt 网络存在、已启动并设置 autostart。
# 默认场景使用 libvirt 的 default NAT 网络。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/30-configure-network.sh [--config FILE] [--dry-run] [--yes]

说明:
  VM_NETWORK=default 时，如果网络不存在会尝试从系统默认 XML 定义。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root
require_cmd virsh

network_active() {
  local net="$1"
  virsh_cmd net-info "$net" 2>/dev/null | awk -F: '
    /^Active:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }
  ' | grep -qx 'yes'
}

network_autostart() {
  local net="$1"
  virsh_cmd net-info "$net" 2>/dev/null | awk -F: '
    /^Autostart:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }
  ' | grep -qx 'yes'
}

if ! virsh_cmd net-info "$VM_NETWORK" >/dev/null 2>&1; then
  if [[ "$VM_NETWORK" != "default" ]]; then
    die "libvirt 网络不存在: $VM_NETWORK。请先手动定义该网络，或改用 default。"
  fi

  DEFAULT_NET_XML="/usr/share/libvirt/networks/default.xml"
  [[ -f "$DEFAULT_NET_XML" ]] || die "找不到 default 网络 XML: $DEFAULT_NET_XML"

  log_warn "libvirt default 网络不存在，尝试从系统 XML 重新定义"
  run_cmd virsh_cmd net-define "$DEFAULT_NET_XML"
  run_cmd virsh_cmd net-start default
  run_cmd virsh_cmd net-autostart default
else
  if ! network_active "$VM_NETWORK"; then
    log_info "启动 libvirt 网络: $VM_NETWORK"
    run_cmd virsh_cmd net-start "$VM_NETWORK"
  else
    log_skip "libvirt 网络已处于 active 状态: $VM_NETWORK"
  fi

  if ! network_autostart "$VM_NETWORK"; then
    log_info "设置 libvirt 网络 autostart: $VM_NETWORK"
    run_cmd virsh_cmd net-autostart "$VM_NETWORK"
  else
    log_skip "libvirt 网络已设置 autostart: $VM_NETWORK"
  fi
fi

if is_true "${DRY_RUN:-false}"; then
  log_skip "dry-run 模式，跳过网络状态校验"
  exit 0
fi

if ! network_active "$VM_NETWORK"; then
  die "libvirt 网络未处于 active 状态: $VM_NETWORK"
fi
if ! network_autostart "$VM_NETWORK"; then
  die "libvirt 网络未设置 autostart: $VM_NETWORK"
fi

state_set "network" "ready:${VM_NETWORK}"
log_ok "libvirt 网络配置完成: $VM_NETWORK"
