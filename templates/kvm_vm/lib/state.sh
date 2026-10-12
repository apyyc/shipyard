#!/usr/bin/env bash
# ============================================================
# kvm_vm/lib/state.sh
#
# 记录每个 VM 的编排状态，仅作为缓存使用；
# 每个脚本仍必须以 libvirt/systemd/磁盘的真实状态为准。
# ============================================================

set -Eeuo pipefail

if [[ -n "${_KVM_STATE_SH_LOADED:-}" ]]; then
  return 0
fi
_KVM_STATE_SH_LOADED=1

kvm_state_dir() {
  printf '%s/%s' "${KVM_STATE_ROOT:-/var/lib/kvm-deploy}" "${VM_NAME:?VM_NAME 未设置}"
}

kvm_state_file() {
  printf '%s/state' "$(kvm_state_dir)"
}

state_init() {
  local dir
  dir="$(kvm_state_dir)"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    chmod 0700 "$dir"
  fi
  local file
  file="$(kvm_state_file)"
  [[ -f "$file" ]] || : > "$file"
  chmod 0600 "$file" 2>/dev/null || true
}

state_set() {
  local key="$1"
  local value="$2"
  state_init

  local file tmp
  file="$(kvm_state_file)"
  tmp="$(mktemp "${file}.XXXXXX")"

  if [[ -s "$file" ]]; then
    awk -v key="$key" 'index($0, key "=") != 1' "$file" > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
  chmod 0600 "$file" 2>/dev/null || true
}

state_get() {
  local key="$1"
  local file
  file="$(kvm_state_file)"
  [[ -f "$file" ]] || return 0
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$file"
}

state_show() {
  local file
  file="$(kvm_state_file)"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    printf '%s\n' "(状态文件不存在)"
  fi
}

state_clear() {
  rm -f "$(kvm_state_file)"
}

# ------------------------------------------------------------
# 锁：只在 deploy.sh 编排器中使用，避免同一 VM 并发部署。
# 子脚本由编排器串行调用，不重复加锁。
# ------------------------------------------------------------

KVM_LOCK_FILE=""

acquire_lock() {
  local name="${1:-deploy}"
  local dir lock
  dir="$(kvm_state_dir)"
  mkdir -p "$dir"
  chmod 0700 "$dir" 2>/dev/null || true

  lock="$dir/${name}.lock"
  exec 9>"$lock" || die "无法创建锁文件: $lock"
  if ! flock -w "${KVM_LOCK_TIMEOUT:-30}" 9; then
    die "获取锁失败，可能有另一个部署流程正在运行: $lock"
  fi
  KVM_LOCK_FILE="$lock"
}
