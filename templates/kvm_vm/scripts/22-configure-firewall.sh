#!/usr/bin/env bash
# ============================================================
# 22-configure-firewall.sh
#
# 按配置开放 Cockpit 端口。默认 OPEN_FIREWALL=none，不修改防火墙。
# 不会自动启用 ufw/firewalld，避免意外切断 SSH。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/22-configure-firewall.sh [--config FILE] [--dry-run] [--yes]

说明:
  OPEN_FIREWALL=none|ufw|firewalld。
  防火墙未运行时默认只警告，不主动启用。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root

case "$OPEN_FIREWALL" in
  none)
    log_skip "OPEN_FIREWALL=none，跳过防火墙配置"
    exit 0
    ;;
  ufw)
    require_cmd ufw
    UFW_STATUS="$(ufw status 2>/dev/null || true)"
    if ! grep -q '^Status: active' <<< "$UFW_STATUS"; then
      if ! is_true "${FIREWALL_ENABLE:-0}"; then
        log_warn "ufw 当前未启用。为避免误锁 SSH，本脚本不自动启用。"
        log_warn "如确认安全，可设置 FIREWALL_ENABLE=1 后重试，或手动执行：sudo ufw enable"
        exit 0
      fi
      run_cmd ufw --force enable
    fi

    if [[ -n "${FIREWALL_ALLOW_CIDR:-}" ]]; then
      log_info "允许 ${FIREWALL_ALLOW_CIDR} 访问 Cockpit 端口 ${COCKPIT_PORT}"
      run_cmd ufw allow from "$FIREWALL_ALLOW_CIDR" to any port "$COCKPIT_PORT" proto tcp
    else
      log_warn "未设置 FIREWALL_ALLOW_CIDR，将允许任意来源访问 ${COCKPIT_PORT}/tcp。"
      run_cmd ufw allow "${COCKPIT_PORT}/tcp"
    fi
    state_set "firewall" "ufw:${COCKPIT_PORT}"
    ;;
  firewalld)
    require_cmd firewall-cmd
    if ! systemctl is-active --quiet firewalld; then
      if ! is_true "${FIREWALL_ENABLE:-0}"; then
        log_warn "firewalld 当前未运行。为避免误锁服务，本脚本不自动启动。"
        log_warn "如确认安全，可设置 FIREWALL_ENABLE=1 后重试。"
        exit 0
      fi
      run_cmd systemctl enable --now firewalld
    fi

    if [[ -n "${FIREWALL_ALLOW_CIDR:-}" ]]; then
      log_info "允许 ${FIREWALL_ALLOW_CIDR} 访问 Cockpit 端口 ${COCKPIT_PORT}"
      run_cmd firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${FIREWALL_ALLOW_CIDR} port protocol=tcp port=${COCKPIT_PORT} accept"
    else
      log_warn "未设置 FIREWALL_ALLOW_CIDR，将允许任意来源访问 ${COCKPIT_PORT}/tcp。"
      run_cmd firewall-cmd --permanent --add-port="${COCKPIT_PORT}/tcp"
    fi
    run_cmd firewall-cmd --reload
    state_set "firewall" "firewalld:${COCKPIT_PORT}"
    ;;
esac

log_ok "防火墙配置完成"
