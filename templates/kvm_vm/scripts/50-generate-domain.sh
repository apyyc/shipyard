#!/usr/bin/env bash
# ============================================================
# 50-generate-domain.sh
#
# 只生成 libvirt domain XML，不定义、不启动。
# 使用 virt-install --print-xml，避免手写 XML。
# 当前版本主线支持 manual-iso；cloud-init 路径后续单独实现。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/50-generate-domain.sh [--config FILE] [--dry-run] [--yes]

说明:
  生成 XML 并写入状态目录，由 51-define-domain.sh 负责 virsh define。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root
require_cmd virt-install

if [[ "$INSTALL_METHOD" != "manual-iso" ]]; then
  die "50-generate-domain.sh 只处理 manual-iso；cloud-init 请使用 70-cloud-install.sh 或 ./deploy.sh cloud。"
fi

[[ -f "$ISO_PATH" && -r "$ISO_PATH" ]] || die "ISO 不存在或不可读: $ISO_PATH"
[[ -f "$VM_DISK_PATH" ]] || die "磁盘不存在，请先执行 40-prepare-storage.sh: $VM_DISK_PATH"

XML_DIR="$(kvm_state_dir)"
XML_FILE="$XML_DIR/domain.xml"
run_cmd mkdir -p "$XML_DIR"

ARGS=(
  --name "$VM_NAME"
  --memory "$VM_RAM_MB"
  --vcpus "$VM_VCPU"
  --cpu "$VM_CPU_MODE"
  --machine "$VM_MACHINE"
  --disk "path=${VM_DISK_PATH},format=qcow2,bus=virtio"
  --cdrom "$ISO_PATH"
  --noautoconsole
  --print-xml
)

# 网络与 MAC
NET_OPT="network=${VM_NETWORK},model=virtio"
if [[ "$VM_MAC" != "auto" && -n "$VM_MAC" ]]; then
  NET_OPT+=",mac=${VM_MAC}"
fi
ARGS+=(--network "$NET_OPT")

# 图形控制台
if [[ "$VM_GRAPHICS" == "none" ]]; then
  ARGS+=(--graphics none --console "pty,target_type=serial")
else
  GFX="${VM_GRAPHICS},listen=${VM_LISTEN}"
  if [[ "$(graphics_port)" != "auto" ]]; then
    GFX+=",port=$(graphics_port)"
  fi
  ARGS+=(--graphics "$GFX")
fi


# 视频设备
VIDEO="$VM_VIDEO"
if [[ "$VIDEO" == "auto" ]]; then
  case "$VM_GRAPHICS" in
    spice) VIDEO="qxl" ;;
    vnc) VIDEO="vga" ;;
    none) VIDEO="none" ;;
  esac
fi
if [[ "$VIDEO" != "none" ]]; then
  ARGS+=(--video "$VIDEO")
fi

# 固件
if [[ "$VM_FIRMWARE" == "uefi" ]]; then
  ARGS+=(--boot uefi)
fi

# os-variant
OS_VARIANT_DETECTED="$(detect_os_variant)"
if [[ "$OS_VARIANT_DETECTED" != "auto" && -n "$OS_VARIANT_DETECTED" ]]; then
  ARGS+=(--os-variant "$OS_VARIANT_DETECTED")
fi

# guest agent channel
if is_true "${VM_GUEST_AGENT:-0}"; then
  if virt-install --help 2>&1 | grep -q -- '--channel'; then
    ARGS+=(--channel "unix,target_type=virtio,name=org.qemu.guest_agent.0")
  else
    log_warn "当前 virt-install 不支持 --channel，跳过 guest agent channel 配置。"
  fi
fi

if is_true "${DRY_RUN:-false}"; then
  log_info "[DRY-RUN] virt-install ${ARGS[*]}"
  log_skip "dry-run 模式，跳过 domain XML 生成"
  exit 0
fi

TMP_XML="$(mktemp "$XML_DIR/domain.xml.XXXXXX")"
if ! virt-install "${ARGS[@]}" > "$TMP_XML"; then
  rm -f "$TMP_XML"
  die "virt-install --print-xml 失败"
fi

if [[ ! -s "$TMP_XML" ]]; then
  rm -f "$TMP_XML"
  die "virt-install 未输出 XML"
fi

mv "$TMP_XML" "$XML_FILE"
chmod 0600 "$XML_FILE"
state_set "domain_xml" "$XML_FILE"
log_ok "domain XML 已生成: $XML_FILE"
