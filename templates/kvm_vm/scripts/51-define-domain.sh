#!/usr/bin/env bash
# ============================================================
# 51-define-domain.sh
#
# 将 50-generate-domain.sh 生成的 XML 定义到 libvirt。
# VM 已存在时默认不覆盖，保证幂等。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/51-define-domain.sh [--config FILE] [--dry-run] [--yes]

说明:
  VM 已定义时不覆盖；如需重建请先执行 90-destroy-vm.sh。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root
require_cmd virsh

if vm_exists; then
  log_skip "虚拟机已定义，跳过: $VM_NAME"
  state_set "domain_defined" "yes"
  exit 0
fi

XML_FILE="$(state_get "domain_xml")"
[[ -n "$XML_FILE" ]] || XML_FILE="$(kvm_state_dir)/domain.xml"
[[ -f "$XML_FILE" ]] || die "domain XML 不存在，请先执行 50-generate-domain.sh: $XML_FILE"

run_cmd virsh_cmd define "$XML_FILE"

if is_true "${DRY_RUN:-false}"; then
  log_skip "dry-run 模式，跳过 domain 定义校验"
  exit 0
fi

if ! vm_exists; then
  die "virsh define 后仍找不到虚拟机: $VM_NAME"
fi

state_set "domain_defined" "yes"
log_ok "虚拟机已定义: $VM_NAME"
