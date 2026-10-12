#!/usr/bin/env bash
# ============================================================
# kvm_vm/lib/libvirt.sh
#
# libvirt / virsh 辅助函数。
# 所有命令显式使用 qemu:///system，避免 root 与非 root 连接不一致。
# ============================================================

set -Eeuo pipefail

if [[ -n "${_KVM_LIBVIRT_SH_LOADED:-}" ]]; then
  return 0
fi
_KVM_LIBVIRT_SH_LOADED=1

libvirt_uri() {
  printf '%s' "${LIBVIRT_URI:-qemu:///system}"
}

virsh_cmd() {
  virsh --connect "$(libvirt_uri)" "$@"
}

vm_exists() {
  [[ -n "${VM_NAME:-}" ]] || return 1
  virsh_cmd dominfo "$VM_NAME" >/dev/null 2>&1
}

vm_state() {
  vm_exists || return 0
  virsh_cmd domstate "$VM_NAME" 2>/dev/null || true
}

vm_running() {
  [[ "$(vm_state)" == "running" ]]
}

wait_for_vm_state() {
  local expected="$1"
  local timeout="${2:-60}"
  local elapsed=0
  local state
  while (( elapsed < timeout )); do
    state="$(vm_state)"
    if [[ "$state" == "$expected" ]]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

vm_display() {
  vm_exists || return 0
  virsh_cmd domdisplay "$VM_NAME" 2>/dev/null || true
}

vm_autostart_enabled() {
  vm_exists || return 1
  local value
  value="$(virsh_cmd dominfo "$VM_NAME" 2>/dev/null | awk -F: '/^Autostart:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }' || true)"
  [[ "$value" == "enable" ]]
}

set_vm_autostart() {
  local enabled="$1"
  if is_true "$enabled"; then
    run_cmd virsh_cmd autostart "$VM_NAME"
  else
    run_cmd virsh_cmd autostart --disable "$VM_NAME"
  fi
}
