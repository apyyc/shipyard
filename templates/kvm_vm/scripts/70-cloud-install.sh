#!/usr/bin/env bash
# ============================================================
# 70-cloud-install.sh
#
# 使用 Debian Generic Cloud 镜像 + cloud-init 自动安装虚拟机。
# 需要 INSTALL_METHOD=cloud-init。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

USAGE=$(
  cat <<'USAGE'
用法:
  sudo ./scripts/70-cloud-install.sh [--config FILE] [--dry-run] [--yes]

说明:
  依赖:
    - CLOUD_IMAGE_URL 或 CLOUD_IMAGE_PATH
    - qemu-img、virsh、virt-install
    - cloud-localds，或 genisoimage
  如未提供 SSH key，脚本会在状态目录中自动生成一对临时 ed25519 key。
USAGE
)

parse_common_args "$USAGE" "$@"
require_root
require_cmd virsh qemu-img virt-install ssh

if [[ "$INSTALL_METHOD" != "cloud-init" ]]; then
  die "当前 INSTALL_METHOD=${INSTALL_METHOD}，请设置 INSTALL_METHOD=cloud-init。"
fi

# ------------------------------------------------------------
# 云镜像路径
# ------------------------------------------------------------
if [[ -n "${CLOUD_IMAGE_PATH:-}" ]]; then
  IMAGE_PATH="$CLOUD_IMAGE_PATH"
else
  IMAGE_PATH="/var/lib/libvirt/images/${VM_NAME}-cloud.qcow2"
fi

if [[ ! -f "$IMAGE_PATH" && -z "${CLOUD_IMAGE_URL:-}" ]]; then
  die "云镜像不存在且未设置 CLOUD_IMAGE_URL: $IMAGE_PATH"
fi

if [[ ! -f "$IMAGE_PATH" ]]; then
  require_cmd curl sha256sum
fi

if is_true "${DRY_RUN:-false}"; then
  if [[ ! -f "$IMAGE_PATH" ]]; then
    log_info "[DRY-RUN] curl -fL --retry 3 -o ${IMAGE_PATH}.download ${CLOUD_IMAGE_URL}"
    log_info "[DRY-RUN] mv ${IMAGE_PATH}.download ${IMAGE_PATH}"
  fi
  log_skip "dry-run 模式，跳过云镜像、cloud-init 和 domain 操作"
  exit 0
fi

# ------------------------------------------------------------
# 下载 / 校验云镜像
# ------------------------------------------------------------
if [[ ! -f "$IMAGE_PATH" ]]; then
  run_cmd mkdir -p "$(dirname "$IMAGE_PATH")"
  TMP_IMAGE="${IMAGE_PATH}.download"
  log_info "下载云镜像: $CLOUD_IMAGE_URL"
  run_cmd curl -fL --retry 3 -o "$TMP_IMAGE" "$CLOUD_IMAGE_URL"

  if [[ -n "${CLOUD_IMAGE_SHA256:-}" ]]; then
    log_info "校验云镜像 SHA256"
    if ! echo "${CLOUD_IMAGE_SHA256}  ${TMP_IMAGE}" | sha256sum -c -; then
      rm -f "$TMP_IMAGE"
      die "云镜像 SHA256 校验失败"
    fi
  fi

  mv "$TMP_IMAGE" "$IMAGE_PATH"
  chmod 0660 "$IMAGE_PATH" 2>/dev/null || true
  chown libvirt-qemu:kvm "$IMAGE_PATH" 2>/dev/null || true
fi

if ! qemu-img info "$IMAGE_PATH" >/dev/null 2>&1; then
  die "云镜像不是有效的 qcow2: $IMAGE_PATH"
fi

# ------------------------------------------------------------
# 磁盘扩容：只扩不缩
# ------------------------------------------------------------
ACTUAL_BYTES="$(qemu-img info --output=json "$IMAGE_PATH" | tr -d ' ' | sed -n 's/.*"virtual-size":\([0-9][0-9]*\).*/\1/p' | head -n1)"
DESIRED_BYTES=$((VM_DISK_SIZE_GB * 1024 * 1024 * 1024))
if [[ -n "$ACTUAL_BYTES" ]] && (( ACTUAL_BYTES < DESIRED_BYTES )); then
  log_info "扩容云镜像到 ${VM_DISK_SIZE_GB} GB"
  run_cmd qemu-img resize "$IMAGE_PATH" "${VM_DISK_SIZE_GB}G"
fi

# ------------------------------------------------------------
# SSH key：未提供时自动生成
# ------------------------------------------------------------
KEY_DIR="$(kvm_state_dir)/cloud-init"
run_cmd mkdir -p "$KEY_DIR"

if [[ -z "${CLOUD_SSH_PUBKEY:-}" && -z "${CLOUD_SSH_PRIVATE_KEY:-}" ]]; then
  GEN_KEY="$KEY_DIR/id_ed25519"
  if [[ ! -f "$GEN_KEY" ]]; then
    if ! command -v ssh-keygen >/dev/null 2>&1; then
      die "未提供 SSH key 且找不到 ssh-keygen，无法自动生成。"
    fi
    ssh-keygen -q -t ed25519 -N '' -f "$GEN_KEY"
  fi
  CLOUD_SSH_PUBKEY="$(cat "$GEN_KEY.pub")"
  CLOUD_SSH_PRIVATE_KEY="$GEN_KEY"
elif [[ -z "${CLOUD_SSH_PUBKEY:-}" || -z "${CLOUD_SSH_PRIVATE_KEY:-}" ]]; then
  die "CLOUD_SSH_PUBKEY 和 CLOUD_SSH_PRIVATE_KEY 必须同时提供，或同时留空自动生成。"
fi

[[ -f "$CLOUD_SSH_PRIVATE_KEY" ]] || die "SSH 私钥文件不存在: $CLOUD_SSH_PRIVATE_KEY"

# ------------------------------------------------------------
# cloud-init user-data / meta-data
# ------------------------------------------------------------
USER_DATA="$KEY_DIR/user-data"
META_DATA="$KEY_DIR/meta-data"

cat > "$USER_DATA" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
ssh_pwauth: false
ssh_authorized_keys:
  - ${CLOUD_SSH_PUBKEY}
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ sh, -c, "growpart /dev/vda 1 || growpart /dev/sda 1 || true" ]
  - [ sh, -c, "resize2fs /dev/vda1 || resize2fs /dev/sda1 || true" ]
EOF

cat > "$META_DATA" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

chmod 0600 "$USER_DATA" "$META_DATA"

# ------------------------------------------------------------
# seed.iso
# ------------------------------------------------------------
SEED_ISO="$(dirname "$IMAGE_PATH")/${VM_NAME}-seed.iso"
if [[ -f "$SEED_ISO" ]]; then
  run_cmd rm -f "$SEED_ISO"
fi

if command -v cloud-localds >/dev/null 2>&1; then
  log_info "生成 cloud-init seed.iso: $SEED_ISO"
  run_cmd cloud-localds "$SEED_ISO" "$USER_DATA" "$META_DATA"
elif command -v genisoimage >/dev/null 2>&1; then
  log_info "生成 cloud-init seed.iso（genisoimage）: $SEED_ISO"
  run_cmd genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock "$USER_DATA" "$META_DATA"
else
  die "未找到 cloud-localds 或 genisoimage，请先执行 10-install-host.sh。"
fi
chmod 0644 "$SEED_ISO" 2>/dev/null || true
chown libvirt-qemu:kvm "$SEED_ISO" 2>/dev/null || true

# ------------------------------------------------------------
# 生成并定义 domain
# ------------------------------------------------------------
XML_DIR="$(kvm_state_dir)"
XML_FILE="$XML_DIR/domain.xml"
run_cmd mkdir -p "$XML_DIR"

if ! vm_exists; then
  ARGS=(
    --name "$VM_NAME"
    --memory "$VM_RAM_MB"
    --vcpus "$VM_VCPU"
    --cpu "$VM_CPU_MODE"
    --machine "$VM_MACHINE"
    --import
    --disk "path=${IMAGE_PATH},format=qcow2,bus=virtio"
    --disk "path=${SEED_ISO},device=cdrom"
    --noautoconsole
    --print-xml
  )

  NET_OPT="network=${VM_NETWORK},model=virtio"
  if [[ "$VM_MAC" != "auto" && -n "$VM_MAC" ]]; then
    NET_OPT+=",mac=${VM_MAC}"
  fi
  ARGS+=(--network "$NET_OPT")

  if [[ "$VM_GRAPHICS" == "none" ]]; then
    ARGS+=(--graphics none --console "pty,target_type=serial")
  else
    GFX="${VM_GRAPHICS},listen=${VM_LISTEN}"
    if [[ "$(graphics_port)" != "auto" ]]; then
      GFX+=",port=$(graphics_port)"
    fi
    ARGS+=(--graphics "$GFX")
  fi

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

  if [[ "$VM_FIRMWARE" == "uefi" ]]; then
    ARGS+=(--boot uefi)
  else
    ARGS+=(--boot hd)
  fi

  OS_VARIANT_DETECTED="$(detect_os_variant)"
  if [[ "$OS_VARIANT_DETECTED" != "auto" && -n "$OS_VARIANT_DETECTED" ]]; then
    ARGS+=(--os-variant "$OS_VARIANT_DETECTED")
  fi

  if is_true "${VM_GUEST_AGENT:-0}"; then
    if virt-install --help 2>&1 | grep -q -- '--channel'; then
      ARGS+=(--channel "unix,target_type=virtio,name=org.qemu.guest_agent.0")
    fi
  fi

  TMP_XML="$(mktemp "$XML_DIR/domain.xml.XXXXXX")"
  if ! virt-install "${ARGS[@]}" > "$TMP_XML"; then
    rm -f "$TMP_XML"
    die "virt-install --print-xml 失败"
  fi
  mv "$TMP_XML" "$XML_FILE"
  chmod 0600 "$XML_FILE"
  run_cmd virsh_cmd define "$XML_FILE"
  state_set "domain_xml" "$XML_FILE"
fi

if ! vm_exists; then
  die "virsh define 后仍找不到虚拟机: $VM_NAME"
fi
state_set "domain_defined" "yes"

# ------------------------------------------------------------
# 启动
# ------------------------------------------------------------
if ! vm_running; then
  log_info "启动虚拟机: $VM_NAME"
  run_cmd virsh_cmd start "$VM_NAME"
fi

if ! wait_for_vm_state "running" "${START_TIMEOUT:-90}"; then
  die "虚拟机未进入 running 状态: $VM_NAME"
fi
state_set "vm_started" "yes"

# ------------------------------------------------------------
# 等待 SSH / cloud-init
# ------------------------------------------------------------
if [[ -n "${CLOUD_SSH_PRIVATE_KEY:-}" ]]; then
  log_info "等待虚拟机 SSH 和 cloud-init 完成（最长 ${CLOUD_WAIT_TIMEOUT:-600} 秒）"
  WAIT_ELAPSED=0
  CLOUD_READY=false

  while (( WAIT_ELAPSED < ${CLOUD_WAIT_TIMEOUT:-600} )); do
    VM_IP="$(vm_ip || true)"
    if [[ -n "$VM_IP" ]]; then
      if ssh -i "$CLOUD_SSH_PRIVATE_KEY" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o IdentitiesOnly=yes \
        "${CLOUD_USER:-debian}@${VM_IP}" \
        'cloud-init status --wait' >/dev/null 2>&1; then
        CLOUD_READY=true
        state_set "vm_ip" "$VM_IP"
        break
      fi
    fi
    sleep 5
    WAIT_ELAPSED=$((WAIT_ELAPSED + 5))
  done

  if [[ "$CLOUD_READY" != "true" ]]; then
    log_warn "等待 cloud-init 超时。可稍后手动检查："
    log_warn "  virsh -c $(libvirt_uri) domifaddr $VM_NAME --source lease"
    log_warn "  ssh -i $CLOUD_SSH_PRIVATE_KEY ${CLOUD_USER:-debian}@<vm-ip>"
  else
    log_ok "cloud-init 已完成，SSH 可用: ${CLOUD_USER:-debian}@${VM_IP}"
  fi
fi

# ------------------------------------------------------------
# 弹出 seed.iso、设置 autostart
# ------------------------------------------------------------
if [[ "${CLOUD_READY:-false}" == "true" ]]; then
  SEED_TARGET="$(virsh_cmd domblklist "$VM_NAME" 2>/dev/null | awk -v iso="$SEED_ISO" '$2 == iso { print $1; exit }')"
  if [[ -n "$SEED_TARGET" ]]; then
    log_info "弹出 cloud-init seed.iso"
    run_cmd virsh_cmd change-media "$VM_NAME" "$SEED_TARGET" --eject --live --config || true
  fi
else
  log_warn "cloud-init 尚未确认完成，保留 seed.iso 以便重跑 cloud-install。"
fi

if is_true "${VM_AUTOSTART:-0}"; then
  run_cmd virsh_cmd autostart "$VM_NAME"
fi

state_set "cloud_install" "done"
log_ok "cloud-init 自动安装流程完成: $VM_NAME"
