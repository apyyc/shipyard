#!/usr/bin/env bash
# ============================================================
# kvm_vm/deploy.sh
#
# KVM 虚拟机部署编排器。
#
# 主线:
#   preflight -> install-host -> enable-kvm -> configure-libvirt
#   -> configure-cockpit -> configure-firewall -> configure-network
#   -> prepare-storage -> generate-domain -> define-domain -> start-vm
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./deploy.sh [OPTIONS] [COMMAND]

COMMAND:
  all          执行主线所有阶段（默认）
  host         安装宿主机依赖、KVM 模块、libvirt、Cockpit、防火墙
  vm           配置网络、存储、定义并启动虚拟机
  create       只准备存储、生成并定义 domain
  start        只启动虚拟机
  cloud        使用 cloud-init 自动安装（预检到 cloud-install）
  cloud-install
               只执行 cloud-init 自动安装阶段
  finalize     安装完成后的收尾：弹出 ISO、调整启动顺序、autostart
  destroy      停止并删除虚拟机定义
  status       查看状态
  diagnose     收集诊断信息
  preflight|install-host|enable-kvm|configure-libvirt|configure-cockpit|
  configure-firewall|configure-network|prepare-storage|generate-domain|
  define-domain|start-vm
               只执行指定阶段

OPTIONS:
  --config FILE      配置文件，默认 config/default.conf
  --vm NAME          覆盖配置中的 VM_NAME
  --only PHASE       只执行指定阶段，可重复；与 all/host/vm 搭配
  --from PHASE       从指定阶段开始执行；与 all/host/vm 搭配
  --dry-run          只打印将执行的阶段，不执行修改
  --yes, -y          危险操作或确认提示自动回答 yes
  --verbose, -v      不写日志文件，直接输出到终端
  -h, --help         显示帮助
USAGE
)

CONFIG_FILE="${KVM_CONFIG:-$DEFAULT_CONFIG}"
DRY_RUN="${KVM_DRY_RUN:-false}"
ASSUME_YES="${KVM_ASSUME_YES:-false}"
VERBOSE=false
ONLY=()
FROM=""
VM_OVERRIDE=""
CLI_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config 需要文件路径"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --vm)
      [[ $# -ge 2 ]] || die "--vm 需要虚拟机名称"
      VM_OVERRIDE="$2"
      shift 2
      ;;
    --only)
      [[ $# -ge 2 ]] || die "--only 需要阶段名"
      ONLY+=("$2")
      shift 2
      ;;
    --from)
      [[ $# -ge 2 ]] || die "--from 需要阶段名"
      FROM="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      printf '%s\n' "$USAGE"
      exit 0
      ;;
    -*)
      die "未知参数: $1"
      ;;
    *)
      CLI_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#CLI_ARGS[@]} -gt 1 ]]; then
  die "未知参数: ${CLI_ARGS[*]}"
fi

CMD="${CLI_ARGS[0]:-all}"

KVM_CONFIG="$CONFIG_FILE"
KVM_DRY_RUN="$DRY_RUN"
KVM_ASSUME_YES="$ASSUME_YES"
export KVM_CONFIG KVM_DRY_RUN KVM_ASSUME_YES

load_config "$CONFIG_FILE"

# --vm 覆盖：同时处理默认磁盘路径
if [[ -n "$VM_OVERRIDE" ]]; then
  OLD_VM_NAME="$VM_NAME"
  VM_NAME="$VM_OVERRIDE"
  if [[ "$VM_DISK_PATH" == "/var/lib/libvirt/images/${OLD_VM_NAME}.qcow2" ]]; then
    VM_DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  fi
  export VM_NAME VM_DISK_PATH
  validate_config
fi

require_root
require_cmd flock
acquire_lock "$VM_NAME"

# ---------- 日志 ----------
if [[ "$VERBOSE" != true ]]; then
  LOG_DIR="${KVM_LOG_DIR:-/var/log/kvm-deploy}"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/${VM_NAME}-$(date +%Y%m%d-%H%M%S).log"
  # shellcheck disable=SC2094
  exec > >(tee -a "$LOG_FILE") 2>&1
  log_info "日志文件: $LOG_FILE"
fi

log_info "配置文件: $CONFIG_FILE"
log_info "虚拟机: ${VM_NAME}"

# ---------- 阶段定义 ----------
declare -A PHASE_SCRIPT=(
  [preflight]="$SCRIPT_DIR/scripts/00-preflight.sh"
  [install-host]="$SCRIPT_DIR/scripts/10-install-host.sh"
  [enable-kvm]="$SCRIPT_DIR/scripts/11-enable-kvm.sh"
  [configure-libvirt]="$SCRIPT_DIR/scripts/20-configure-libvirt.sh"
  [configure-cockpit]="$SCRIPT_DIR/scripts/21-configure-cockpit.sh"
  [configure-firewall]="$SCRIPT_DIR/scripts/22-configure-firewall.sh"
  [configure-network]="$SCRIPT_DIR/scripts/30-configure-network.sh"
  [prepare-storage]="$SCRIPT_DIR/scripts/40-prepare-storage.sh"
  [generate-domain]="$SCRIPT_DIR/scripts/50-generate-domain.sh"
  [define-domain]="$SCRIPT_DIR/scripts/51-define-domain.sh"
  [start-vm]="$SCRIPT_DIR/scripts/60-start-vm.sh"
  [cloud-install]="$SCRIPT_DIR/scripts/70-cloud-install.sh"
  [finalize]="$SCRIPT_DIR/scripts/80-finalize-vm.sh"
  [destroy]="$SCRIPT_DIR/scripts/90-destroy-vm.sh"
  [status]="$SCRIPT_DIR/scripts/status.sh"
  [diagnose]="$SCRIPT_DIR/scripts/diagnose.sh"
)

ALL_PHASES=(
  preflight
  install-host
  enable-kvm
  configure-libvirt
  configure-cockpit
  configure-firewall
  configure-network
  prepare-storage
  generate-domain
  define-domain
  start-vm
)

HOST_PHASES=(
  install-host
  enable-kvm
  configure-libvirt
  configure-cockpit
  configure-firewall
)

VM_PHASES=(
  configure-network
  prepare-storage
  generate-domain
  define-domain
  start-vm
)

CLOUD_PHASES=(
  preflight
  install-host
  enable-kvm
  configure-libvirt
  configure-cockpit
  configure-firewall
  configure-network
  cloud-install
)

run_phase() {
  local phase="$1"
  local script="${PHASE_SCRIPT[$phase]:-}"
  [[ -n "$script" ]] || die "未知阶段: $phase"
  [[ -f "$script" ]] || die "阶段脚本不存在: $script"

  log_info "===== 阶段: $phase ====="
  if is_true "$DRY_RUN"; then
    log_info "[DRY-RUN] bash $script"
    return 0
  fi
  bash "$script"
}

run_phases() {
  local -a phases=("$@")
  local -a selected=()

  if [[ ${#ONLY[@]} -gt 0 ]]; then
    selected=("${ONLY[@]}")
  elif [[ -n "$FROM" ]]; then
    local found=false
    local p
    for p in "${phases[@]}"; do
      if [[ "$p" == "$FROM" ]]; then
        found=true
      fi
      if [[ "$found" == true ]]; then
        selected+=("$p")
      fi
    done
    [[ "$found" == true ]] || die "--from 指定的阶段不存在: $FROM"
  else
    selected=("${phases[@]}")
  fi

  [[ ${#selected[@]} -gt 0 ]] || die "没有选中任何阶段"

  local phase
  for phase in "${selected[@]}"; do
    [[ -n "${PHASE_SCRIPT[$phase]:-}" ]] || die "未知阶段: $phase"
    run_phase "$phase"
  done
}

case "$CMD" in
  all)
    run_phases "${ALL_PHASES[@]}"
    ;;
  host)
    run_phases "${HOST_PHASES[@]}"
    ;;
  vm)
    run_phases "${VM_PHASES[@]}"
    ;;
  create)
    run_phases prepare-storage generate-domain define-domain
    ;;
  cloud|autoinstall)
    run_phases "${CLOUD_PHASES[@]}"
    ;;
  cloud-install)
    run_phase cloud-install
    ;;
  start)
    run_phase start-vm
    ;;
  finalize)
    run_phase finalize
    ;;
  destroy)
    run_phase destroy
    ;;
  status)
    run_phase status
    ;;
  diagnose)
    run_phase diagnose
    ;;
  preflight|install-host|enable-kvm|configure-libvirt|configure-cockpit|configure-firewall|configure-network|prepare-storage|generate-domain|define-domain|start-vm|cloud-install)
    run_phase "$CMD"
    ;;
  *)
    printf '%s\n' "$USAGE" >&2
    die "未知命令: $CMD"
    ;;
esac

log_ok "执行完成"
