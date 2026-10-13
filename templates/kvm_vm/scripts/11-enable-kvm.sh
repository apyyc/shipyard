#!/usr/bin/env bash
# ============================================================
# 11-enable-kvm.sh
#
# 加载 KVM 内核模块并检查 /dev/kvm。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/11-enable-kvm.sh [--config FILE] [--dry-run] [--yes]

说明:
  根据 CPU 厂商加载 kvm_intel 或 kvm_amd，并验证 /dev/kvm。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root

if [[ -c /dev/kvm ]]; then
  log_ok "/dev/kvm 已存在，跳过模块加载"
  state_set "kvm_module" "ready"
  exit 0
fi

if grep -Eqm1 'vmx' /proc/cpuinfo; then
  KVM_MODULE="kvm_intel"
elif grep -Eqm1 'svm' /proc/cpuinfo; then
  KVM_MODULE="kvm_amd"
else
  die "未检测到 vmx/svm，无法加载 KVM 模块。"
fi

if is_true "${DRY_RUN:-false}"; then
  log_info "[DRY-RUN] modprobe kvm"
  log_info "[DRY-RUN] modprobe ${KVM_MODULE}"
  log_skip "dry-run 模式，跳过 /dev/kvm 校验"
  exit 0
fi

log_info "加载 kvm 模块"
if ! modprobe kvm; then
  die "modprobe kvm 失败。"
fi

log_info "加载 ${KVM_MODULE} 模块"
if ! modprobe "$KVM_MODULE"; then
  die "modprobe ${KVM_MODULE} 失败。请检查内核模块是否存在、Secure Boot 是否阻止加载。"
fi

if retry 5 1 test -c /dev/kvm; then
  log_ok "/dev/kvm 已就绪"
  state_set "kvm_module" "ready"
else
  die "/dev/kvm 仍未出现。请检查 BIOS 中的 CPU 虚拟化开关，以及宿主机是否已开启嵌套虚拟化。"
fi
