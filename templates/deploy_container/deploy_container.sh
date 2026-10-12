#!/usr/bin/env bash
# ============================================================
# deploy_container.sh
#
# 通用多容器部署模板。按配置顺序创建/更新多个容器。
# 不包含任何具体项目名、业务字段、账号或密钥。
#
# 用法:
#   ./deploy_container.sh [--config <file>] [--only <name>]... [--dry-run]
#                         [--no-systemd] [deploy|stop|rm|status|logs]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/deploy_container.conf"
CONFIG_FILE=""
DRY_RUN=false
NO_SYSTEMD=false
ONLY=()

usage() {
  cat <<'USAGE'
用法:
  ./deploy_container.sh [--config <file>] [--only <name>]... [--dry-run]
                        [--no-systemd] [deploy|stop|rm|status|logs]

说明:
  不传命令时默认为 deploy。
  --only 可重复，用于只处理指定服务。
USAGE
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "[ERROR] --config 需要文件路径" >&2; exit 1; }
      CONFIG_FILE="$2"; shift 2 ;;
    --only)
      [[ $# -ge 2 ]] || { echo "[ERROR] --only 需要服务名" >&2; exit 1; }
      ONLY+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-systemd) NO_SYSTEMD=true; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
CMD="${1:-deploy}"
[[ $# -gt 0 ]] && shift || true
[[ $# -eq 0 ]] || { echo "[ERROR] 未知参数: $*" >&2; exit 1; }

if [[ -z "$CONFIG_FILE" ]]; then
  if [[ -f "$PWD/deploy_container.conf" ]]; then
    CONFIG_FILE="$PWD/deploy_container.conf"
  elif [[ -f "$DEFAULT_CONFIG" ]]; then
    CONFIG_FILE="$DEFAULT_CONFIG"
  else
    echo "[ERROR] 未找到 deploy_container.conf（可用 --config 指定）" >&2
    exit 1
  fi
fi
[[ -f "$CONFIG_FILE" ]] || { echo "[ERROR] 配置文件不存在: $CONFIG_FILE" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
CONFIG_FILE="$CONFIG_DIR/$(basename "$CONFIG_FILE")"

DEPLOY_RUNTIME="auto"
SYSTEMD_ENABLE=false
declare -a CONTAINER_ORDER=()
declare -A CONTAINER_IMAGE=()
declare -A CONTAINER_NETWORK=()
declare -A CONTAINER_PORTS=()
declare -A CONTAINER_VOLUMES=()
declare -A CONTAINER_ENV_FILES=()
declare -A CONTAINER_ENV_VARS=()
declare -A CONTAINER_RESTART=()
declare -A CONTAINER_HEALTH_URL=()
declare -A CONTAINER_HEALTH_RETRIES=()
declare -A CONTAINER_RUN_ARGS=()
declare -A CONTAINER_PRE_DEPLOY_CMD=()
declare -A CONTAINER_POST_DEPLOY_CMD=()

# shellcheck disable=SC1090
source "$CONFIG_FILE"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

TOOL=""
resolve_tool() {
  local want="${DEPLOY_RUNTIME:-auto}"
  if [[ "$want" != "auto" ]]; then
    command -v "$want" >/dev/null 2>&1 || die "容器工具不存在: $want"
    TOOL="$want"
    return 0
  fi
  local t
  for t in podman docker; do
    if command -v "$t" >/dev/null 2>&1 && "$t" info >/dev/null 2>&1; then
      TOOL="$t"
      return 0
    fi
  done
  die "找不到可用的 podman/docker"
}

container_exists() {
  "$TOOL" container exists "$1" >/dev/null 2>&1 || "$TOOL" inspect "$1" >/dev/null 2>&1
}

container_running() {
  local status
  status="$("$TOOL" inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)"
  [[ "$status" == "true" ]]
}

image_exists() {
  "$TOOL" image inspect "$1" >/dev/null 2>&1
}

run_hook() {
  local name="$1" phase="$2" cmd="$3"
  [[ -n "$cmd" ]] || return 0
  log "[$name] $phase hook"
  ( cd "$CONFIG_DIR" && bash -c "$cmd" )
}

wait_health() {
  local name="$1" url="${CONTAINER_HEALTH_URL[$name]:-}"
  [[ -n "$url" ]] || return 0
  local retries="${CONTAINER_HEALTH_RETRIES[$name]:-30}"
  command -v curl >/dev/null 2>&1 || { warn "未找到 curl，跳过 $name 健康检查"; return 0; }
  local i
  printf '[INFO] 等待 %s 健康检查' "$name"
  for ((i=0; i<retries; i++)); do
    if curl -fsS -m 3 "$url" >/dev/null 2>&1; then
      printf ' [OK]\n'
      return 0
    fi
    printf '.'
    sleep 1
  done
  printf ' [WARN]\n'
  return 0
}

selected_services() {
  local s found
  if [[ ${#ONLY[@]} -gt 0 ]]; then
    for s in "${ONLY[@]}"; do
      found=false
      for x in "${CONTAINER_ORDER[@]}"; do
        [[ "$x" == "$s" ]] && found=true
      done
      [[ "$found" == true ]] || die "未知服务: $s"
      printf '%s\n' "$s"
    done
  else
    printf '%s\n' "${CONTAINER_ORDER[@]}"
  fi
}

deploy_one() {
  local name="$1" image network restart value
  image="${CONTAINER_IMAGE[$name]:-}"
  [[ -n "$image" ]] || die "服务 $name 缺少 CONTAINER_IMAGE"
  image_exists "$image" || die "服务 $name 镜像不存在: $image"
  run_hook "$name" "pre-deploy" "${CONTAINER_PRE_DEPLOY_CMD[$name]:-}"

  local -a run_args=(run -d --name "$name")
  restart="${CONTAINER_RESTART[$name]:-unless-stopped}"
  run_args+=(--restart="$restart")

  network="${CONTAINER_NETWORK[$name]:-}"
  if [[ "$network" == "host" ]]; then
    run_args+=(--network=host)
  elif [[ -n "$network" ]]; then
    run_args+=(--network "$network")
  fi

  value="${CONTAINER_PORTS[$name]:-}"
  if [[ -n "$value" ]]; then
    local -a parts=()
    read -r -a parts <<< "$value"
    local p
    for p in "${parts[@]}"; do run_args+=(-p "$p"); done
  fi

  value="${CONTAINER_VOLUMES[$name]:-}"
  if [[ -n "$value" ]]; then
    local -a parts=()
    read -r -a parts <<< "$value"
    local v src
    for v in "${parts[@]}"; do
      src="${v%%:*}"
      [[ "$src" == /* ]] && mkdir -p "$src"
      run_args+=(-v "$v")
    done
  fi

  value="${CONTAINER_ENV_FILES[$name]:-}"
  if [[ -n "$value" ]]; then
    local -a parts=()
    read -r -a parts <<< "$value"
    local f
    for f in "${parts[@]}"; do run_args+=(--env-file "$f"); done
  fi

  value="${CONTAINER_ENV_VARS[$name]:-}"
  if [[ -n "$value" ]]; then
    local -a parts=()
    read -r -a parts <<< "$value"
    local e
    for e in "${parts[@]}"; do run_args+=(-e "$e"); done
  fi

  value="${CONTAINER_RUN_ARGS[$name]:-}"
  if [[ -n "$value" ]]; then
    local -a parts=()
    read -r -a parts <<< "$value"
    run_args+=("${parts[@]}")
  fi

  run_cmd "$TOOL" rm -f "$name" >/dev/null 2>&1 || true
  run_args+=("$image")
  log "部署服务: $name -> $image"
  run_cmd "$TOOL" "${run_args[@]}"
  [[ "$DRY_RUN" == true ]] && return 0

  if [[ "$NO_SYSTEMD" != true ]] && is_true "$SYSTEMD_ENABLE"; then
    if [[ "$TOOL" == "podman" ]] && command -v systemctl >/dev/null 2>&1 \
       && systemctl --user show-environment >/dev/null 2>&1; then
      local unit_dir="${HOME}/.config/systemd/user"
      mkdir -p "$unit_dir"
      ( cd "$unit_dir" && podman generate systemd --name "$name" --new --files --restart-policy=always ) \
        >/dev/null 2>&1 || warn "生成 systemd 服务失败: $name"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      systemctl --user enable "container-${name}.service" >/dev/null 2>&1 || true
      podman rm -f "$name" >/dev/null 2>&1 || true
      systemctl --user restart "container-${name}.service"
      log "已启用 systemd 服务: container-${name}.service"
    else
      warn "跳过 systemd 自启（仅 podman 且 systemd --user 可用时支持）"
    fi
  fi

  wait_health "$name"
  run_hook "$name" "post-deploy" "${CONTAINER_POST_DEPLOY_CMD[$name]:-}"
}

stop_one() {
  local name="$1"
  if [[ "$NO_SYSTEMD" != true ]] && is_true "$SYSTEMD_ENABLE"; then
    systemctl --user stop "container-${name}.service" >/dev/null 2>&1 || true
  fi
  if container_exists "$name"; then
    run_cmd "$TOOL" stop "$name"
  else
    log "[SKIP] 服务不存在: $name"
  fi
}

rm_one() {
  local name="$1"
  if [[ "$NO_SYSTEMD" != true ]] && is_true "$SYSTEMD_ENABLE"; then
    systemctl --user stop "container-${name}.service" >/dev/null 2>&1 || true
    systemctl --user disable "container-${name}.service" >/dev/null 2>&1 || true
    rm -f "${HOME}/.config/systemd/user/container-${name}.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  run_cmd "$TOOL" rm -f "$name" >/dev/null 2>&1 || true
  log "已删除容器（数据卷保留）: $name"
}

status_one() {
  local name="$1" status
  status="$("$TOOL" inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
  if container_running "$name"; then
    log "[OK] $name 运行中"
  else
    log "[OFF] $name 状态: ${status:-不存在}"
  fi
}

logs_one() {
  local name="$1"
  if container_exists "$name"; then
    run_cmd "$TOOL" logs --tail 50 "$name"
  else
    log "[SKIP] 服务不存在: $name"
  fi
}

[[ ${#CONTAINER_ORDER[@]} -gt 0 ]] || die "配置未定义 CONTAINER_ORDER"
resolve_tool
mapfile -t SERVICES < <(selected_services)
[[ ${#SERVICES[@]} -gt 0 ]] || die "没有选中任何服务"

case "$CMD" in
  deploy)
    for name in "${SERVICES[@]}"; do deploy_one "$name"; done
    log "部署完成: ${SERVICES[*]}"
    ;;
  stop)
    for name in "${SERVICES[@]}"; do stop_one "$name"; done
    log "停止完成: ${SERVICES[*]}"
    ;;
  rm)
    for name in "${SERVICES[@]}"; do rm_one "$name"; done
    log "删除完成: ${SERVICES[*]}"
    ;;
  status)
    for name in "${SERVICES[@]}"; do status_one "$name"; done
    ;;
  logs)
    for name in "${SERVICES[@]}"; do logs_one "$name"; done
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
