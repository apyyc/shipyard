#!/usr/bin/env bash
# ============================================================
# 80-finalize-vm.sh
#
# 安装完成后的收尾：
#   - 弹出 ISO
#   - 调整启动顺序为硬盘优先
#   - 设置 autostart
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/80-finalize-vm.sh [--config FILE] [--dry-run] [--yes]

说明:
  建议在虚拟机内完成系统安装后执行。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root
require_cmd virsh

if ! vm_exists; then
  die "虚拟机不存在: $VM_NAME"
fi

# ---------- 弹出 ISO ----------
if [[ "$INSTALL_METHOD" == "manual-iso" && -n "${ISO_PATH:-}" ]]; then
  TARGET="$(virsh_cmd domblklist "$VM_NAME" 2>/dev/null | awk -v iso="$ISO_PATH" '$2 == iso { print $1; exit }')"
  if [[ -n "$TARGET" ]]; then
    log_info "从 $TARGET 弹出 ISO: $ISO_PATH"
    if vm_running; then
      run_cmd virsh_cmd change-media "$VM_NAME" "$TARGET" --eject --live --config
    else
      run_cmd virsh_cmd change-media "$VM_NAME" "$TARGET" --eject --config
    fi
  else
    log_skip "未在 domblklist 中找到 ISO，可能已经弹出"
  fi
fi

# ---------- 设置硬盘优先启动 ----------
if command -v virt-xml >/dev/null 2>&1; then
  log_info "设置启动顺序: hd,cdrom"
  if ! run_cmd virt-xml -c "$(libvirt_uri)" --edit "$VM_NAME" --boot hd,cdrom; then
    log_warn "virt-xml 设置启动顺序失败，请手动检查: virsh dumpxml $VM_NAME"
  fi
else
  log_warn "未找到 virt-xml，跳过启动顺序调整；通常弹出 ISO 后仍可从硬盘引导。"
fi

# ---------- autostart ----------
if is_true "${VM_AUTOSTART:-0}"; then
  log_info "设置虚拟机 autostart: $VM_NAME"
  run_cmd virsh_cmd autostart "$VM_NAME"
else
  run_cmd virsh_cmd autostart --disable "$VM_NAME" || true
fi

if is_true "${DRY_RUN:-false}"; then
  log_skip "dry-run 模式，跳过收尾校验"
  exit 0
fi

# ---------- 校验 ----------
if [[ "$INSTALL_METHOD" == "manual-iso" && -n "${ISO_PATH:-}" ]]; then
  if virsh_cmd domblklist "$VM_NAME" 2>/dev/null | awk '$2 != "" { print $2 }' | grep -Fqx "$ISO_PATH"; then
    log_warn "ISO 仍在虚拟机中，请检查 virsh domblklist $VM_NAME"
  else
    log_ok "ISO 已弹出"
  fi
fi

if is_true "${VM_AUTOSTART:-0}"; then
  if vm_autostart_enabled; then
    log_ok "虚拟机已设置 autostart"
  else
    die "虚拟机 autostart 设置失败: $VM_NAME"
  fi
fi

state_set "finalized" "yes"
log_ok "虚拟机收尾完成: $VM_NAME"
