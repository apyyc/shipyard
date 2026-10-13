#!/usr/bin/env bash
# ============================================================
# status.sh
#
# 查看宿主机与虚拟机的当前状态，只读。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/status.sh [--config FILE]

说明:
  只读状态检查，不修改系统。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root

echo "============================================================"
echo "KVM VM 状态: ${VM_NAME}"
echo "============================================================"

if [[ -c /dev/kvm ]]; then
  echo "[OK]   /dev/kvm 存在"
else
  echo "[WARN] /dev/kvm 不存在"
fi

if command -v virsh >/dev/null 2>&1; then
  if virsh_cmd uri >/dev/null 2>&1; then
    echo "[OK]   libvirt URI 可连接: $(libvirt_uri)"
  else
    echo "[WARN] libvirt URI 不可连接: $(libvirt_uri)"
  fi

  if virsh_cmd net-info "$VM_NETWORK" >/dev/null 2>&1; then
    echo "[OK]   网络存在: $VM_NETWORK"
  else
    echo "[WARN] 网络不存在: $VM_NETWORK"
  fi

  if virsh_cmd pool-info "$STORAGE_POOL" >/dev/null 2>&1; then
    echo "[OK]   存储池存在: $STORAGE_POOL"
  else
    echo "[WARN] 存储池不存在: $STORAGE_POOL"
  fi

  if vm_exists; then
    STATE="$(vm_state)"
    echo "[OK]   虚拟机已定义: $VM_NAME，状态: ${STATE:-unknown}"
    if [[ "$STATE" == "running" ]]; then
      DISPLAY="$(vm_display || true)"
      [[ -n "$DISPLAY" ]] && echo "[INFO] 显示地址: $DISPLAY"
    fi
  else
    echo "[SKIP] 虚拟机未定义: $VM_NAME"
  fi
else
  echo "[WARN] virsh 未安装"
fi

if [[ -f "$VM_DISK_PATH" ]]; then
  if command -v qemu-img >/dev/null 2>&1 && qemu-img info "$VM_DISK_PATH" >/dev/null 2>&1; then
    echo "[OK]   磁盘存在且有效: $VM_DISK_PATH"
  else
    echo "[WARN] 磁盘存在但无法识别: $VM_DISK_PATH"
  fi
else
  echo "[WARN] 磁盘不存在: $VM_DISK_PATH"
fi

if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${COCKPIT_PORT}$"; then
  echo "[OK]   Cockpit 端口监听: ${COCKPIT_PORT}"
else
  echo "[WARN] Cockpit 端口未监听或无法检查: ${COCKPIT_PORT}"
fi

echo
echo "状态文件: $(kvm_state_file)"
state_show | sed 's/^/  /'
