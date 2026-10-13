#!/usr/bin/env bash
# ============================================================
# kvm_vm/lib/common.sh
#
# 公共函数库：配置加载、日志、命令执行、参数解析、基础校验。
# 所有 scripts/*.sh 和 deploy.sh 都通过本文件统一行为。
# ============================================================

set -Eeuo pipefail
export LC_ALL=C

# 防止被重复 source
if [[ -n "${_KVM_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
_KVM_COMMON_SH_LOADED=1

# ------------------------------------------------------------
# 基础路径
# ------------------------------------------------------------

KVM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVM_ROOT="$(cd "$KVM_LIB_DIR/.." && pwd)"
DEFAULT_CONFIG="$KVM_ROOT/config/default.conf"
SCRIPTS_DIR="$KVM_ROOT/scripts"

# ------------------------------------------------------------
# 日志
# ------------------------------------------------------------

log_info()  { printf '[INFO] %s\n' "$*"; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_ok()    { printf '[OK] %s\n' "$*"; }
log_skip()  { printf '[SKIP] %s\n' "$*"; }

die() {
  log_error "$*"
  exit 1
}

# ------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 权限执行（sudo ./deploy.sh ...）。"
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
  done
}

run_cmd() {
  if is_true "${DRY_RUN:-false}"; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

retry() {
  local max="$1" delay="$2"
  shift 2
  local i
  for ((i = 1; i <= max; i++)); do
    if "$@"; then
      return 0
    fi
    if (( i < max )); then
      sleep "$delay"
    fi
  done
  return 1
}

confirm() {
  local prompt="$1"
  if is_true "${ASSUME_YES:-false}"; then
    return 0
  fi
  [[ -t 0 ]] || die "危险操作需要 --yes 才能非交互执行: $prompt"
  local answer
  printf '%s [y/N] ' "$prompt" >&2
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

nearest_existing_dir() {
  local path="$1"
  while [[ ! -d "$path" && "$path" != "/" ]]; do
    path="$(dirname "$path")"
  done
  printf '%s' "$path"
}

# ------------------------------------------------------------
# 参数解析：脚本级通用参数
# ------------------------------------------------------------

# parse_common_args <usage> "$@"
# 支持: --config FILE、--dry-run、--yes/-y、-h/--help
parse_common_args() {
  local usage="$1"
  shift

  CONFIG_FILE="${KVM_CONFIG:-$DEFAULT_CONFIG}"
  DRY_RUN="${KVM_DRY_RUN:-false}"
  ASSUME_YES="${KVM_ASSUME_YES:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config 需要文件路径"
        CONFIG_FILE="$2"
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
      -h|--help)
        printf '%s\n' "$usage"
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done

  KVM_CONFIG="$CONFIG_FILE"
  KVM_DRY_RUN="$DRY_RUN"
  KVM_ASSUME_YES="$ASSUME_YES"
  export KVM_CONFIG KVM_DRY_RUN KVM_ASSUME_YES

  load_config "$CONFIG_FILE"
}

# ------------------------------------------------------------
# 配置加载
# ------------------------------------------------------------

load_config() {
  local cfg="${1:-${KVM_CONFIG:-$DEFAULT_CONFIG}}"

  if [[ "${KVM_CONFIG_LOADED:-false}" == "true" && "$cfg" == "${KVM_LOADED_CONFIG_FILE:-}" ]]; then
    validate_config
    return 0
  fi

  [[ -f "$cfg" ]] || die "配置文件不存在: $cfg（请先复制 config/default.conf.template 为 config/default.conf）"

  # 在子 shell 中 source 配置，避免配置文件里的 set -e 影响主流程。
  set -a
  # shellcheck disable=SC1090
  source "$cfg"
  set +a

  KVM_LOADED_CONFIG_FILE="$cfg"
  KVM_CONFIG_LOADED=true
  export KVM_LOADED_CONFIG_FILE KVM_CONFIG_LOADED

  # ---------- 默认值 ----------
  : "${VM_NAME:=debian13-vm}"
  : "${VM_VCPU:=4}"
  : "${VM_RAM_MB:=4096}"
  : "${VM_DISK_SIZE_GB:=40}"
  : "${VM_DISK_PATH:=}"
  : "${STORAGE_POOL:=default}"

  : "${INSTALL_METHOD:=manual-iso}"
  : "${ISO_PATH:=}"
  : "${OS_VARIANT:=auto}"

  : "${VM_NETWORK:=default}"
  : "${VM_GRAPHICS:=spice}"
  : "${VM_GRAPHICS_PORT:=auto}"
  : "${VM_LISTEN:=127.0.0.1}"
  : "${VM_VIDEO:=auto}"

  : "${VM_FIRMWARE:=bios}"
  : "${VM_MACHINE:=q35}"
  : "${VM_CPU_MODE:=host-passthrough}"
  : "${VM_MAC:=auto}"
  : "${VM_AUTOSTART:=1}"
  : "${VM_GUEST_AGENT:=1}"

  : "${COCKPIT_PORT:=9091}"
  : "${INSTALL_COCKPIT:=1}"
  : "${INSTALL_VIEWER:=1}"
  : "${OPEN_FIREWALL:=none}"
  : "${FIREWALL_ALLOW_CIDR:=}"

  : "${LIBVIRT_URI:=qemu:///system}"
  : "${KVM_STATE_ROOT:=/var/lib/kvm-deploy}"
  : "${KVM_LOCK_TIMEOUT:=30}"
  : "${KVM_LOG_DIR:=/var/log/kvm-deploy}"
  : "${APT_UPDATE_MODE:=auto}"
  : "${FIREWALL_ENABLE:=0}"
  : "${DELETE_DISK:=0}"
  : "${START_TIMEOUT:=90}"

  : "${CLOUD_IMAGE_URL:=}"
  : "${CLOUD_IMAGE_SHA256:=}"
  : "${CLOUD_IMAGE_PATH:=}"
  : "${CLOUD_SSH_PUBKEY:=}"
  : "${CLOUD_SSH_PRIVATE_KEY:=}"
  : "${CLOUD_USER:=debian}"
  : "${CLOUD_WAIT_TIMEOUT:=600}"

  # 派生值必须在 VM_NAME 最终确定之后处理
  if [[ -z "$VM_DISK_PATH" ]]; then
    VM_DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  fi

  export \
    VM_NAME VM_VCPU VM_RAM_MB VM_DISK_SIZE_GB VM_DISK_PATH STORAGE_POOL \
    INSTALL_METHOD ISO_PATH OS_VARIANT \
    VM_NETWORK VM_GRAPHICS VM_GRAPHICS_PORT VM_LISTEN VM_VIDEO \
    VM_FIRMWARE VM_MACHINE VM_CPU_MODE VM_MAC VM_AUTOSTART VM_GUEST_AGENT \
    COCKPIT_PORT INSTALL_COCKPIT INSTALL_VIEWER OPEN_FIREWALL FIREWALL_ALLOW_CIDR \
    LIBVIRT_URI KVM_STATE_ROOT KVM_LOCK_TIMEOUT KVM_LOG_DIR \
    APT_UPDATE_MODE FIREWALL_ENABLE DELETE_DISK START_TIMEOUT \
    CLOUD_IMAGE_URL CLOUD_IMAGE_SHA256 CLOUD_IMAGE_PATH \
    CLOUD_SSH_PUBKEY CLOUD_SSH_PRIVATE_KEY CLOUD_USER CLOUD_WAIT_TIMEOUT

  validate_config
}

# ------------------------------------------------------------
# 配置校验
# ------------------------------------------------------------

validate_config() {
  [[ -n "${VM_NAME:-}" ]] || die "VM_NAME 不能为空"
  [[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "VM_NAME 只能包含字母、数字、下划线、点和短横线: $VM_NAME"

  is_uint "${VM_VCPU:-}" && ((VM_VCPU >= 1)) || die "VM_VCPU 必须是正整数"
  is_uint "${VM_RAM_MB:-}" && ((VM_RAM_MB >= 512)) || die "VM_RAM_MB 必须是大于等于 512 的整数"
  is_uint "${VM_DISK_SIZE_GB:-}" && ((VM_DISK_SIZE_GB >= 5)) || die "VM_DISK_SIZE_GB 必须是大于等于 5 的整数"

  [[ "${VM_DISK_PATH:-}" == /* ]] || die "VM_DISK_PATH 必须是绝对路径: ${VM_DISK_PATH:-}"
  [[ -n "${STORAGE_POOL:-}" ]] || die "STORAGE_POOL 不能为空"

  case "${INSTALL_METHOD:-}" in
    manual-iso|cloud-init) ;;
    *) die "INSTALL_METHOD 只支持 manual-iso 或 cloud-init: ${INSTALL_METHOD:-}" ;;
  esac

  [[ -n "${VM_NETWORK:-}" ]] || die "VM_NETWORK 不能为空"

  case "${VM_GRAPHICS:-}" in
    spice|vnc|none) ;;
    *) die "VM_GRAPHICS 只支持 spice、vnc、none: ${VM_GRAPHICS:-}" ;;
  esac

  if [[ "${VM_GRAPHICS_PORT:-auto}" != "auto" ]]; then
    is_uint "$VM_GRAPHICS_PORT" && ((VM_GRAPHICS_PORT >= 1 && VM_GRAPHICS_PORT <= 65535)) \
      || die "VM_GRAPHICS_PORT 必须是 auto 或 1-65535: $VM_GRAPHICS_PORT"
  fi

  [[ -n "${VM_LISTEN:-}" ]] || die "VM_LISTEN 不能为空"

  case "${VM_FIRMWARE:-}" in
    bios|uefi) ;;
    *) die "VM_FIRMWARE 只支持 bios 或 uefi: ${VM_FIRMWARE:-}" ;;
  esac

  case "${VM_MACHINE:-}" in
    q35|pc) ;;
    *) die "VM_MACHINE 只支持 q35 或 pc: ${VM_MACHINE:-}" ;;
  esac

  [[ -n "${VM_CPU_MODE:-}" ]] || die "VM_CPU_MODE 不能为空"
  [[ -n "${VM_VIDEO:-}" ]] || die "VM_VIDEO 不能为空"

  is_uint "${COCKPIT_PORT:-}" && ((COCKPIT_PORT >= 1 && COCKPIT_PORT <= 65535)) \
    || die "COCKPIT_PORT 必须是 1-65535: ${COCKPIT_PORT:-}"

  case "${OPEN_FIREWALL:-}" in
    none|ufw|firewalld) ;;
    *) die "OPEN_FIREWALL 只支持 none、ufw、firewalld: ${OPEN_FIREWALL:-}" ;;
  esac

  [[ "${LIBVIRT_URI:-}" == qemu:///* ]] || die "LIBVIRT_URI 应以 qemu:/// 开头: ${LIBVIRT_URI:-}"
  [[ "${KVM_STATE_ROOT:-}" == /* ]] || die "KVM_STATE_ROOT 必须是绝对路径: ${KVM_STATE_ROOT:-}"

  if [[ "${INSTALL_METHOD:-}" == "manual-iso" && -z "${ISO_PATH:-}" ]]; then
    die "INSTALL_METHOD=manual-iso 时必须设置 ISO_PATH"
  fi

  if [[ "${INSTALL_METHOD:-}" == "cloud-init" ]]; then
    if [[ -z "${CLOUD_IMAGE_URL:-}" && -z "${CLOUD_IMAGE_PATH:-}" ]]; then
      die "INSTALL_METHOD=cloud-init 时必须设置 CLOUD_IMAGE_URL 或 CLOUD_IMAGE_PATH"
    fi
  fi
}

# ------------------------------------------------------------
# 辅助：OS variant、图形端口、磁盘路径
# ------------------------------------------------------------

detect_os_variant() {
  local candidate

  if [[ "${OS_VARIANT:-auto}" != "auto" && -n "${OS_VARIANT:-}" ]]; then
    printf '%s' "$OS_VARIANT"
    return 0
  fi

  if command -v osinfo-query >/dev/null 2>&1; then
    for candidate in debian13 debian12 debian11; do
      if osinfo-query os 2>/dev/null | awk -v id="$candidate" '$1 == id { found=1 } END { exit !found }'; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  fi

  if command -v virt-install >/dev/null 2>&1; then
    for candidate in debian13 debian12 debian11; do
      if virt-install --osinfo list 2>/dev/null | awk -v id="$candidate" '$1 == id { found=1 } END { exit !found }'; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  fi

  printf 'auto'
}

graphics_port() {
  if [[ "${VM_GRAPHICS_PORT:-auto}" == "auto" ]]; then
    printf 'auto'
  else
    printf '%s' "$VM_GRAPHICS_PORT"
  fi
}

# ------------------------------------------------------------
# 状态与 libvirt 辅助库
# ------------------------------------------------------------

# shellcheck source=state.sh
source "$KVM_LIB_DIR/state.sh"
# shellcheck source=libvirt.sh
source "$KVM_LIB_DIR/libvirt.sh"
