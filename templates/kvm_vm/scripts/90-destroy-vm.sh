#!/usr/bin/env bash
# ============================================================
# 90-destroy-vm.sh
#
# 停止并删除虚拟机定义；磁盘默认保留。
# 必须通过 --yes 或交互确认。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/90-destroy-vm.sh [--config FILE] [--dry-run] [--yes]

环境变量:
  DELETE_DISK=1  同时删除磁盘（默认 0，只删除定义）

说明:
  默认只 undefine 虚拟机，保留 qcow2 磁盘。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root
require_cmd virsh

DELETE_DISK="${DELETE_DISK:-0}"

if ! is_true "${DRY_RUN:-false}"; then
  if ! confirm "确定要停止并删除虚拟机定义 ${VM_NAME} 吗？"; then
    die "用户取消操作"
  fi
fi

if vm_exists; then
  if vm_running; then
    log_info "强制停止虚拟机: $VM_NAME"
    run_cmd virsh_cmd destroy "$VM_NAME"
  else
    log_skip "虚拟机未运行: $VM_NAME"
  fi

  log_info "删除虚拟机定义: $VM_NAME"
  run_cmd virsh_cmd undefine "$VM_NAME"
else
  log_skip "虚拟机定义不存在: $VM_NAME"
fi

if is_true "$DELETE_DISK"; then
  if [[ "$VM_DISK_PATH" != *.qcow2 ]]; then
    die "拒绝删除非 qcow2 文件: $VM_DISK_PATH"
  fi
  if [[ "$VM_DISK_PATH" == "/" || -z "$VM_DISK_PATH" ]]; then
    die "拒绝删除危险路径: $VM_DISK_PATH"
  fi
  if ! is_true "${DRY_RUN:-false}"; then
    if ! confirm "确定要删除磁盘 ${VM_DISK_PATH} 吗？该操作不可恢复！"; then
      die "用户取消删除磁盘"
    fi
  fi
  log_warn "删除磁盘: $VM_DISK_PATH"
  run_cmd rm -f "$VM_DISK_PATH"
else
  log_skip "保留磁盘: $VM_DISK_PATH"
fi

if is_true "${DRY_RUN:-false}"; then
  log_skip "dry-run 模式，跳过状态清理"
  exit 0
fi

state_clear
rm -rf "$(kvm_state_dir)" 2>/dev/null || true
log_ok "虚拟机销毁完成: $VM_NAME"
