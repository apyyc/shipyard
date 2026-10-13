#!/usr/bin/env bash
# ============================================================
# 20-configure-libvirt.sh
#
# 启动并校验 libvirt 服务。
# 兼容传统 libvirtd.service 与模块化 virtqemud.socket 等新架构。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/20-configure-libvirt.sh [--config FILE] [--dry-run] [--yes]

说明:
  自动识别 libvirtd 或模块化 libvirt 守护进程并启动。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root
require_cmd systemctl

UNITS=()
if systemctl cat libvirtd.service >/dev/null 2>&1; then
  UNITS=(libvirtd.service)
else
  for unit in virtqemud.socket virtnetworkd.socket virtstoraged.socket virtnodedevd.socket virtsecretd.socket virtinterfaced.socket; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      UNITS+=("$unit")
    fi
  done
fi

if [[ ${#UNITS[@]} -eq 0 ]]; then
  die "未找到 libvirtd.service 或模块化 libvirt socket，请先执行 10-install-host.sh。"
fi

log_info "启用 libvirt 服务单元: ${UNITS[*]}"
run_cmd systemctl enable --now "${UNITS[@]}"

if is_true "${DRY_RUN:-false}"; then
  log_skip "dry-run 模式，跳过服务与 virsh 校验"
  exit 0
fi

for unit in "${UNITS[@]}"; do
  if ! systemctl is-active --quiet "$unit"; then
    die "服务未处于 active 状态: $unit"
  fi
done
log_ok "libvirt 服务单元已启动"

require_cmd virsh
if virsh_cmd list >/dev/null 2>&1; then
  log_ok "virsh 可连接 $(libvirt_uri)"
else
  die "virsh 无法连接 $(libvirt_uri)"
fi

state_set "libvirt_service" "ready"
