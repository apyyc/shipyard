#!/usr/bin/env bash
# ============================================================
# 60-start-vm.sh
#
# 启动虚拟机，等待进入 running，并输出控制台连接方式。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/60-start-vm.sh [--config FILE] [--dry-run] [--yes]

说明:
  启动后输出 SPICE/VNC 地址和 remote-viewer 命令。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root
require_cmd virsh

if ! vm_exists; then
  die "虚拟机尚未定义，请先执行 50-generate-domain.sh 和 51-define-domain.sh。"
fi

if vm_running; then
  log_skip "虚拟机已在运行: $VM_NAME"
else
  log_info "启动虚拟机: $VM_NAME"
  run_cmd virsh_cmd start "$VM_NAME"
fi

if is_true "${DRY_RUN:-false}"; then
  log_skip "dry-run 模式，跳过启动状态校验"
  exit 0
fi

if ! wait_for_vm_state "running" "${START_TIMEOUT:-90}"; then
  die "虚拟机未在 ${START_TIMEOUT:-90} 秒内进入 running 状态，请检查: virsh console $VM_NAME"
fi

DISPLAY=""
for _ in 1 2 3 4 5; do
  DISPLAY="$(vm_display)"
  [[ -n "$DISPLAY" ]] && break
  sleep 2
done

STATE_DISPLAY_PORT=""
if [[ "$DISPLAY" =~ :([0-9]+)$ ]]; then
  STATE_DISPLAY_PORT="${BASH_REMATCH[1]}"
fi

state_set "vm_started" "yes"
if [[ -n "$DISPLAY" ]]; then
  state_set "vm_display" "$DISPLAY"
fi

log_ok "虚拟机已启动: $VM_NAME"

echo
echo "============================================================"
echo "虚拟机控制台连接方式"
echo "============================================================"
if [[ -n "$DISPLAY" ]]; then
  echo "显示地址: $DISPLAY"
  case "$VM_GRAPHICS" in
    spice|vnc) echo "本机打开:  remote-viewer '$DISPLAY'" ;;
  esac
else
  echo "未查询到图形显示地址。"
fi
echo
echo "Cockpit:   https://<宿主机IP>:${COCKPIT_PORT}  -> 虚拟机 -> ${VM_NAME} -> 控制台"
if [[ "$VM_GRAPHICS" != "none" && "$VM_LISTEN" == "127.0.0.1" ]]; then
  if [[ -n "$STATE_DISPLAY_PORT" ]]; then
    echo "远程访问建议使用 SSH 隧道，不要直接暴露图形端口："
    echo "  ssh -L ${STATE_DISPLAY_PORT}:127.0.0.1:${STATE_DISPLAY_PORT} <user>@<宿主机IP>"
    if [[ "$VM_GRAPHICS" == "spice" ]]; then
      echo "  然后在本机执行: remote-viewer spice://127.0.0.1:${STATE_DISPLAY_PORT}"
    else
      echo "  然后在本机执行: remote-viewer vnc://127.0.0.1:${STATE_DISPLAY_PORT}"
    fi
  else
    echo "远程访问请使用 SSH 隧道转发实际显示端口。"
  fi
fi
echo
echo "接下来请在控制台完成 Debian 安装。"
echo "安装完成后执行：sudo ./deploy.sh finalize"
echo "============================================================"
