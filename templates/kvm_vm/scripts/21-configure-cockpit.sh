#!/usr/bin/env bash
# ============================================================
# 21-configure-cockpit.sh
#
# 配置 Cockpit 监听端口（默认 9091），并启动 cockpit.socket。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/21-configure-cockpit.sh [--config FILE] [--dry-run] [--yes]

说明:
  COCKPIT_PORT=9090 时移除本脚本管理的自定义端口配置。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root

if ! is_true "${INSTALL_COCKPIT:-1}"; then
  log_skip "INSTALL_COCKPIT=0，跳过 Cockpit 配置"
  exit 0
fi

require_cmd systemctl
systemctl cat cockpit.socket >/dev/null 2>&1 || die "cockpit.socket 不存在，请先执行 10-install-host.sh。"

DROPIN_DIR="/etc/systemd/system/cockpit.socket.d"
DROPIN="$DROPIN_DIR/10-kvm-deploy-listen.conf"

CHANGED=false

if [[ "$COCKPIT_PORT" == "9090" ]]; then
  if [[ -f "$DROPIN" ]]; then
    run_cmd rm -f "$DROPIN"
    CHANGED=true
    log_info "已移除自定义 Cockpit 端口配置，恢复默认 9090"
  else
    log_skip "Cockpit 使用默认端口 9090"
  fi
else
  CONTENT="# Managed by kvm_vm deploy. Do not edit manually.
[Socket]
ListenStream=
ListenStream=${COCKPIT_PORT}
"
  if [[ ! -f "$DROPIN" ]] || ! printf '%s' "$CONTENT" | cmp -s - "$DROPIN"; then
    run_cmd mkdir -p "$DROPIN_DIR"
    printf '%s' "$CONTENT" | run_cmd tee "$DROPIN" >/dev/null
    CHANGED=true
    log_info "设置 Cockpit 监听端口为 ${COCKPIT_PORT}"
  else
    log_skip "Cockpit 端口配置已存在且一致"
  fi
fi

if [[ "$CHANGED" == "true" ]]; then
  run_cmd systemctl daemon-reload
fi

run_cmd systemctl enable --now cockpit.socket

if is_true "${DRY_RUN:-false}"; then
  log_skip "dry-run 模式，跳过 Cockpit 端口校验"
  exit 0
fi

if ! systemctl is-active --quiet cockpit.socket; then
  die "cockpit.socket 未处于 active 状态"
fi

if command -v ss >/dev/null 2>&1; then
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${COCKPIT_PORT}$"; then
    log_ok "Cockpit 正在监听 ${COCKPIT_PORT}"
  else
    die "Cockpit 未监听 ${COCKPIT_PORT}，请检查 systemctl status cockpit.socket 和 journalctl -u cockpit.socket"
  fi
fi

state_set "cockpit_port" "$COCKPIT_PORT"
log_ok "Cockpit 配置完成"
