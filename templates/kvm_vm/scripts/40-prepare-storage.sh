#!/usr/bin/env bash
# ============================================================
# 40-prepare-storage.sh
#
# 准备 libvirt 存储池和 qcow2 磁盘。
# 已存在的磁盘不会被覆盖；如果容量小于配置值则尝试扩容。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/40-prepare-storage.sh [--config FILE] [--dry-run] [--yes]

说明:
  默认使用 STORAGE_POOL，默认 default。
  磁盘存在但容量不足时只扩容，不缩小、不覆盖。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root
require_cmd virsh qemu-img

pool_state() {
  local pool="$1"
  virsh_cmd pool-info "$pool" 2>/dev/null | awk -F: '
    /^State:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }
  '
}

pool_autostart() {
  local pool="$1"
  virsh_cmd pool-info "$pool" 2>/dev/null | awk -F: '
    /^Autostart:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }
  ' | grep -qx 'yes'
}

# ---------- 存储池 ----------
if ! virsh_cmd pool-info "$STORAGE_POOL" >/dev/null 2>&1; then
  if [[ "$STORAGE_POOL" != "default" ]]; then
    die "存储池不存在: $STORAGE_POOL。请先定义该存储池，或使用 default。"
  fi

  POOL_TARGET="$(dirname "$VM_DISK_PATH")"
  log_warn "存储池 default 不存在，尝试按磁盘目录定义: $POOL_TARGET"
  run_cmd virsh_cmd pool-define-as "$STORAGE_POOL" dir --target "$POOL_TARGET"
  run_cmd virsh_cmd pool-build "$STORAGE_POOL"
  run_cmd virsh_cmd pool-start "$STORAGE_POOL"
  run_cmd virsh_cmd pool-autostart "$STORAGE_POOL"
else
  if [[ "$(pool_state "$STORAGE_POOL")" != "running" ]]; then
    log_info "启动存储池: $STORAGE_POOL"
    run_cmd virsh_cmd pool-start "$STORAGE_POOL"
  else
    log_skip "存储池已运行: $STORAGE_POOL"
  fi

  if ! pool_autostart "$STORAGE_POOL"; then
    log_info "设置存储池 autostart: $STORAGE_POOL"
    run_cmd virsh_cmd pool-autostart "$STORAGE_POOL"
  else
    log_skip "存储池已设置 autostart: $STORAGE_POOL"
  fi
fi

if is_true "${DRY_RUN:-false}"; then
  log_skip "dry-run 模式，跳过存储池校验与磁盘创建"
  exit 0
fi

if [[ "$(pool_state "$STORAGE_POOL")" != "running" ]]; then
  die "存储池未处于 running 状态: $STORAGE_POOL"
fi

# ---------- 磁盘 ----------
DISK_DIR="$(dirname "$VM_DISK_PATH")"

if [[ -e "$VM_DISK_PATH" ]]; then
  [[ -f "$VM_DISK_PATH" ]] || die "磁盘路径存在但不是普通文件: $VM_DISK_PATH"

  if ! qemu-img info "$VM_DISK_PATH" >/dev/null 2>&1; then
    die "文件已存在但不是有效的 qcow2 镜像: $VM_DISK_PATH（不会自动覆盖，请手动确认）"
  fi

  ACTUAL_BYTES="$(qemu-img info --output=json "$VM_DISK_PATH" | tr -d ' ' | sed -n 's/.*"virtual-size":\([0-9][0-9]*\).*/\1/p' | head -n1)"
  DESIRED_BYTES=$((VM_DISK_SIZE_GB * 1024 * 1024 * 1024))

  if [[ -z "$ACTUAL_BYTES" ]]; then
    log_warn "无法解析磁盘虚拟容量，跳过容量检查: $VM_DISK_PATH"
  elif (( ACTUAL_BYTES < DESIRED_BYTES )); then
    log_warn "磁盘容量小于配置值：当前 $((ACTUAL_BYTES / 1024 / 1024 / 1024)) GB，目标 ${VM_DISK_SIZE_GB} GB，尝试扩容。"
    run_cmd qemu-img resize "$VM_DISK_PATH" "${VM_DISK_SIZE_GB}G"
  else
    log_skip "磁盘已存在且容量满足要求: $VM_DISK_PATH"
  fi
else
  log_info "创建 qcow2 磁盘: $VM_DISK_PATH（${VM_DISK_SIZE_GB} GB）"
  run_cmd mkdir -p "$DISK_DIR"

  POOL_TARGET="$(virsh_cmd pool-dumpxml "$STORAGE_POOL" 2>/dev/null | sed -n 's#.*<path>\(.*\)</path>.*#\1#p' | head -n1)"
  if [[ -n "$POOL_TARGET" && "$DISK_DIR" == "$POOL_TARGET" ]]; then
    # 优先交给 libvirt 创建，自动处理属主/权限/security label。
    run_cmd virsh_cmd vol-create-as "$STORAGE_POOL" "$(basename "$VM_DISK_PATH")" "${VM_DISK_SIZE_GB}G" --format qcow2
  else
    run_cmd qemu-img create -f qcow2 -o preallocation=metadata "$VM_DISK_PATH" "${VM_DISK_SIZE_GB}G"
    if ! is_true "${DRY_RUN:-false}"; then
      # 自定义目录不在 libvirt 存储池内时，尽量设置正确的属主和权限。
      chown libvirt-qemu:kvm "$VM_DISK_PATH" 2>/dev/null || true
      chmod 0660 "$VM_DISK_PATH" 2>/dev/null || true
    fi
  fi
fi

if ! qemu-img info "$VM_DISK_PATH" >/dev/null 2>&1; then
  die "磁盘最终校验失败: $VM_DISK_PATH"
fi

state_set "storage" "ready:${VM_DISK_PATH}"
log_ok "存储准备完成"
