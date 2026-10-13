#!/usr/bin/env bash
# ============================================================
# diagnose.sh
#
# 收集 KVM/libvirt/VM 诊断信息，输出为文本和 tar.gz。
# 只读，不修改系统。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/diagnose.sh [--config FILE]

说明:
  收集系统、libvirt、网络、存储池和虚拟机信息。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root

OUT_DIR="${KVM_LOG_DIR:-/var/log/kvm-deploy}"
mkdir -p "$OUT_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_TXT="$OUT_DIR/${VM_NAME}-diagnose-${STAMP}.txt"
OUT_TAR="$OUT_DIR/${VM_NAME}-diagnose-${STAMP}.tar.gz"

{
  echo "KVM VM diagnose"
  echo "VM_NAME=${VM_NAME}"
  echo "CONFIG=${KVM_CONFIG:-}"
  echo "DATE=$(date -Is)"
  echo "============================================================"
  echo "## uname"
  uname -a || true
  echo
  echo "## os-release"
  cat /etc/os-release 2>/dev/null || true
  echo
  echo "## lscpu"
  lscpu 2>/dev/null || true
  echo
  echo "## memory"
  free -m 2>/dev/null || true
  echo
  echo "## disk"
  df -h 2>/dev/null || true
  echo
  echo "## /dev/kvm"
  ls -l /dev/kvm 2>&1 || true
  echo
  echo "## virsh version"
  virsh --connect "$(libvirt_uri)" version 2>&1 || true
  echo
  echo "## virsh list"
  virsh --connect "$(libvirt_uri)" list --all 2>&1 || true
  echo
  echo "## networks"
  virsh --connect "$(libvirt_uri)" net-list --all 2>&1 || true
  echo
  echo "## pools"
  virsh --connect "$(libvirt_uri)" pool-list --all 2>&1 || true
  echo
  echo "## systemctl libvirt/cockpit"
  systemctl status libvirtd.service --no-pager 2>&1 || true
  systemctl status virtqemud.socket --no-pager 2>&1 || true
  systemctl status cockpit.socket --no-pager 2>&1 || true
  echo
  if command -v virsh >/dev/null 2>&1 && virsh --connect "$(libvirt_uri)" dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "## VM dumpxml"
    virsh --connect "$(libvirt_uri)" dumpxml "$VM_NAME" 2>&1 || true
    echo
    echo "## VM blklist"
    virsh --connect "$(libvirt_uri)" domblklist "$VM_NAME" 2>&1 || true
    echo
    echo "## VM display"
    virsh --connect "$(libvirt_uri)" domdisplay "$VM_NAME" 2>&1 || true
    echo
    echo "## VM ifaddr"
    virsh --connect "$(libvirt_uri)" domifaddr "$VM_NAME" 2>&1 || true
  else
    echo "## VM not defined or virsh unavailable"
  fi
  echo
  echo "============================================================"
  echo "state file:"
  state_show || true
} > "$OUT_TXT" 2>&1

tar -czf "$OUT_TAR" -C "$OUT_DIR" "$(basename "$OUT_TXT")" 2>/dev/null || true

log_ok "诊断文本: $OUT_TXT"
if [[ -f "$OUT_TAR" ]]; then
  log_ok "诊断压缩包: $OUT_TAR"
fi
