#!/usr/bin/env bash
# ============================================================
# dev_start.sh
#
# 通用开发环境启动脚本：
#   - 可选启动 MySQL 容器
#   - 可一次启动多个源码进程（后端、前端，或任意配置的命令）
#   - 支持 start/stop/restart/status/logs/tail
#
# 用法：
#   ./dev_start.sh [--config <file>] [--dry-run] <命令> [组件] [选项]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/dev_start.conf"
CONFIG_FILE=""
DRY_RUN=false

usage() {
  cat <<'USAGE'
用法:
  ./dev_start.sh [--config <file>] [--dry-run] <命令> [组件] [选项]

命令:
  start      启动选中的组件
  stop       停止选中的组件（不写组件名则停止全部启用组件）
  restart    重启选中的组件
  status     查看状态
  logs       列出日志
  tail       跟踪日志

组件:
  mysql backend frontend

start/restart 可用选项:
  --no-mysql      跳过 MySQL
  --no-backend    跳过后端
  --no-frontend   跳过前端
  --no-reload     不追加后端热重载参数

通用选项:
  --config <file> 指定配置文件
  --dry-run       只打印动作，不真正执行
  -h, --help      显示帮助
USAGE
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "[ERROR] --config 需要文件路径" >&2; exit 1; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
set -- "${args[@]}"

if [[ -z "$CONFIG_FILE" ]]; then
  if [[ -f "$PWD/dev_start.conf" ]]; then
    CONFIG_FILE="$PWD/dev_start.conf"
  elif [[ -f "$DEFAULT_CONFIG" ]]; then
    CONFIG_FILE="$DEFAULT_CONFIG"
  else
    echo "[ERROR] 未找到 dev_start.conf（可用 --config 指定）" >&2
    exit 1
  fi
fi
[[ -f "$CONFIG_FILE" ]] || { echo "[ERROR] 配置文件不存在: $CONFIG_FILE" >&2; exit 1; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
CONFIG_FILE="$CONFIG_DIR/$(basename "$CONFIG_FILE")"

PROJECT_ROOT=""
LOG_DIR=""
MYSQL_ENABLED=false
MYSQL_RUNTIME="auto"
MYSQL_CONTAINER="example-mysql"
MYSQL_IMAGE="mysql:8.4"
MYSQL_PORT=3306
MYSQL_DATA_DIR=".data/mysql"
MYSQL_CREATE=true
MYSQL_PASSWORD_ENV="MYSQL_ROOT_PASSWORD"
MYSQL_PASSWORD_FILE=""
MYSQL_PASSWORD_KEY="MYSQL_ROOT_PASSWORD"
MYSQL_READY_CMD="SELECT 1"
MYSQL_WAIT_SECS=60
BACKEND_ENABLED=false
BACKEND_DIR="."
BACKEND_PORT=8010
BACKEND_RELOAD=false
BACKEND_LOG="backend.log"
BACKEND_STOP_PATTERN=""
FRONTEND_ENABLED=false
FRONTEND_DIR="./frontend"
FRONTEND_PORT=5174
FRONTEND_LOG="frontend.log"
FRONTEND_STOP_PATTERN=""
declare -a MYSQL_EXTRA_ARGS=()
declare -a BACKEND_CMD=()
declare -a BACKEND_RELOAD_ARGS=()
declare -a FRONTEND_CMD=()

# shellcheck disable=SC1090
source "$CONFIG_FILE"

PROJECT_ROOT="${PROJECT_ROOT:-$CONFIG_DIR}"
case "$PROJECT_ROOT" in
  /*) ;;
  *) PROJECT_ROOT="$CONFIG_DIR/$PROJECT_ROOT" ;;
esac
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"
case "$LOG_DIR" in
  /*) ;;
  *) LOG_DIR="$PROJECT_ROOT/$LOG_DIR" ;;
esac
mkdir -p "$LOG_DIR"
BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-http://127.0.0.1:${BACKEND_PORT}/}"
FRONTEND_HEALTH_URL="${FRONTEND_HEALTH_URL:-http://127.0.0.1:${FRONTEND_PORT}/}"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$PROJECT_ROOT" "$1" ;;
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
  local want="${MYSQL_RUNTIME:-auto}"
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
  die "找不到可用的 podman/docker（可用 MYSQL_RUNTIME 指定）"
}

container_exists() {
  resolve_tool
  "$TOOL" container exists "$1" >/dev/null 2>&1 || "$TOOL" inspect "$1" >/dev/null 2>&1
}

container_running() {
  resolve_tool
  local status
  status="$("$TOOL" inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)"
  [[ "$status" == "true" ]]
}

image_exists() {
  resolve_tool
  "$TOOL" image inspect "$1" >/dev/null 2>&1
}

mysql_password() {
  local v="${!MYSQL_PASSWORD_ENV:-}"
  if [[ -z "$v" && -n "$MYSQL_PASSWORD_FILE" ]]; then
    v="$(grep "^${MYSQL_PASSWORD_KEY}=" "$MYSQL_PASSWORD_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  printf '%s' "$v"
}

mysql_ready() {
  if [[ -n "$MYSQL_READY_CMD" ]]; then
    resolve_tool
    "$TOOL" exec -e "MYSQL_PWD=$(mysql_password)" "$MYSQL_CONTAINER" sh -c "$MYSQL_READY_CMD" >/dev/null 2>&1
  else
    ss -tln 2>/dev/null | grep -q ":${MYSQL_PORT}\b"
  fi
}

wait_mysql() {
  local i
  log "等待 MySQL 就绪（最长 ${MYSQL_WAIT_SECS}s）"
  for ((i=0; i<MYSQL_WAIT_SECS; i++)); do
    if mysql_ready; then
      log "MySQL 已就绪"
      return 0
    fi
    sleep 1
  done
  die "MySQL 未在 ${MYSQL_WAIT_SECS}s 内就绪"
}

start_mysql() {
  resolve_tool
  if container_running "$MYSQL_CONTAINER"; then
    log "[SKIP] MySQL 容器已在运行: $MYSQL_CONTAINER"
    return 0
  fi
  if container_exists "$MYSQL_CONTAINER"; then
    run_cmd "$TOOL" start "$MYSQL_CONTAINER"
  else
    if ! is_true "$MYSQL_CREATE"; then
      die "MySQL 容器不存在且 MYSQL_CREATE=false: $MYSQL_CONTAINER"
    fi
    image_exists "$MYSQL_IMAGE" || die "MySQL 镜像不存在: $MYSQL_IMAGE"
    local data_dir password
    data_dir="$(resolve_path "$MYSQL_DATA_DIR")"
    password="$(mysql_password)"
    mkdir -p "$data_dir"
    local -a run_args=(run -d --name "$MYSQL_CONTAINER" --restart=unless-stopped)
    run_args+=(-p "${MYSQL_PORT}:3306")
    run_args+=(-v "${data_dir}:/var/lib/mysql")
    if [[ -n "$password" ]]; then
      run_args+=(-e "${MYSQL_PASSWORD_ENV}=${password}")
      run_args+=(-e "MYSQL_ROOT_HOST=%")
    else
      warn "MySQL 密码为空，将使用 MYSQL_ALLOW_EMPTY_PASSWORD=yes"
      run_args+=(-e "MYSQL_ALLOW_EMPTY_PASSWORD=yes")
    fi
    run_args+=("${MYSQL_EXTRA_ARGS[@]}")
    run_args+=("$MYSQL_IMAGE")
    run_cmd "$TOOL" "${run_args[@]}"
  fi
  wait_mysql
}

stop_mysql() {
  resolve_tool
  if container_exists "$MYSQL_CONTAINER"; then
    run_cmd "$TOOL" stop "$MYSQL_CONTAINER"
  else
    log "[SKIP] MySQL 容器不存在: $MYSQL_CONTAINER"
  fi
}

status_mysql() {
  resolve_tool
  if container_running "$MYSQL_CONTAINER"; then
    if mysql_ready; then
      log "[OK] MySQL 容器运行中且已就绪: $MYSQL_CONTAINER"
    else
      warn "MySQL 容器运行中，但就绪检查未通过: $MYSQL_CONTAINER"
    fi
  else
    log "[OFF] MySQL 容器未运行: $MYSQL_CONTAINER"
  fi
}

logs_mysql() {
  resolve_tool
  if container_exists "$MYSQL_CONTAINER"; then
    run_cmd "$TOOL" logs --tail 50 "$MYSQL_CONTAINER"
  else
    log "[SKIP] MySQL 容器不存在: $MYSQL_CONTAINER"
  fi
}

tail_mysql() {
  resolve_tool
  if container_exists "$MYSQL_CONTAINER"; then
    run_cmd "$TOOL" logs -f "$MYSQL_CONTAINER"
  else
    log "[SKIP] MySQL 容器不存在: $MYSQL_CONTAINER"
  fi
}

pid_file() { printf '%s/.dev_start_%s.pid' "$LOG_DIR" "$1"; }

read_pid() {
  local f
  f="$(pid_file "$1")"
  if [[ -f "$f" ]]; then
    cat "$f" 2>/dev/null || true
  fi
}

process_running() {
  local p
  p="$(read_pid "$1")"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

start_process() {
  local name="$1" dir="$2" log_file="$3"
  shift 3
  local -a cmd=("$@")
  [[ ${#cmd[@]} -gt 0 ]] || die "$name 启动命令为空"
  local abs_dir abs_log
  abs_dir="$(resolve_path "$dir")"
  abs_log="$(resolve_path "$log_file")"
  [[ -d "$abs_dir" ]] || die "$name 运行目录不存在: $abs_dir"
  mkdir -p "$(dirname "$abs_log")"
  if process_running "$name"; then
    log "[SKIP] $name 已在运行"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] 启动 $name: (cd $abs_dir && ${cmd[*]}) > $abs_log"
    return 0
  fi
  (
    cd "$abs_dir"
    nohup "${cmd[@]}" > "$abs_log" 2>&1 < /dev/null &
    echo $! > "$(pid_file "$name")"
    disown || true
  )
  sleep 1
  if ! process_running "$name"; then
    warn "$name 进程启动后立即退出，详见 $abs_log"
    return 1
  fi
  log "$name 已启动"
}

stop_process() {
  local name="$1" pattern="${2:-}"
  local p
  p="$(read_pid "$name")"
  if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
    log "停止 $name (PID $p)"
    run_cmd kill "$p" 2>/dev/null || true
    local i
    for i in {1..10}; do
      kill -0 "$p" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$p" 2>/dev/null; then
      warn "$name 未退出，强制结束"
      run_cmd kill -9 "$p" 2>/dev/null || true
    fi
  else
    log "[SKIP] $name 未在运行"
  fi
  rm -f "$(pid_file "$name")"
  if [[ -n "$pattern" ]]; then
    run_cmd pkill -f "$pattern" 2>/dev/null || true
  fi
}

status_process() {
  local name="$1" url="$2"
  if process_running "$name"; then
    if [[ -n "$url" ]] && command -v curl >/dev/null 2>&1; then
      if curl -fsS -m 3 "$url" >/dev/null 2>&1; then
        log "[OK] $name 运行中且健康: $url"
      else
        warn "$name 进程在运行，但健康检查未通过: $url"
      fi
    else
      log "[OK] $name 运行中"
    fi
  else
    log "[OFF] $name 未运行"
  fi
}

wait_http() {
  local name="$1" url="$2"
  [[ -n "$url" ]] || return 0
  if ! command -v curl >/dev/null 2>&1; then
    warn "未找到 curl，跳过 $name 健康等待"
    return 0
  fi
  local i
  printf '[INFO] 等待 %s 就绪' "$name"
  for ((i=0; i<30; i++)); do
    if curl -fsS -m 2 "$url" >/dev/null 2>&1; then
      printf ' [OK]\n'
      return 0
    fi
    printf '.'
    sleep 1
  done
  printf ' [WARN]\n'
  return 0
}

start_backend() {
  local -a cmd=("${BACKEND_CMD[@]}")
  if is_true "$BACKEND_RELOAD" && [[ "$NO_RELOAD" != true ]]; then
    cmd+=("${BACKEND_RELOAD_ARGS[@]}")
  fi
  start_process backend "$BACKEND_DIR" "$BACKEND_LOG" "${cmd[@]}"
  wait_http backend "$BACKEND_HEALTH_URL"
}

stop_backend() {
  stop_process backend "$BACKEND_STOP_PATTERN"
}

status_backend() {
  status_process backend "$BACKEND_HEALTH_URL"
}

start_frontend() {
  start_process frontend "$FRONTEND_DIR" "$FRONTEND_LOG" "${FRONTEND_CMD[@]}"
  wait_http frontend "$FRONTEND_HEALTH_URL"
}

stop_frontend() {
  stop_process frontend "$FRONTEND_STOP_PATTERN"
}

status_frontend() {
  status_process frontend "$FRONTEND_HEALTH_URL"
}

enabled_components() {
  local out=()
  is_true "$MYSQL_ENABLED" && out+=(mysql)
  is_true "$BACKEND_ENABLED" && out+=(backend)
  is_true "$FRONTEND_ENABLED" && out+=(frontend)
  [[ ${#out[@]} -eq 0 ]] || printf '%s\n' "${out[@]}"
}

list_logs() {
  log "日志目录: $LOG_DIR"
  if compgen -G "$LOG_DIR/*.log" >/dev/null; then
    ls -lht "$LOG_DIR"/*.log | awk '{print "  " $5 "  " $NF}'
  else
    log "暂无日志文件"
  fi
}

tail_logs() {
  shopt -s nullglob
  local files=("$LOG_DIR"/*.log)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    log "暂无日志文件"
    return 0
  fi
  log "跟踪日志: ${files[*]}（Ctrl+C 退出）"
  tail -f "${files[@]}"
}

CMD="${1:-start}"
[[ $# -gt 0 ]] && shift || true
NO_MYSQL=false
NO_BACKEND=false
NO_FRONTEND=false
NO_RELOAD=false
REQUESTED=()
SELECTED=()

case "$CMD" in
  start|restart)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --no-mysql)    NO_MYSQL=true ;;
        --no-backend)  NO_BACKEND=true ;;
        --no-frontend) NO_FRONTEND=true ;;
        --no-reload)   NO_RELOAD=true ;;
        -h|--help)     usage; exit 0 ;;
        *) die "未知参数: $1" ;;
      esac
      shift
    done
    while IFS= read -r c; do
      [[ -n "$c" ]] || continue
      case "$c" in
        mysql)    [[ "$NO_MYSQL" == true ]] || SELECTED+=("$c") ;;
        backend)  [[ "$NO_BACKEND" == true ]] || SELECTED+=("$c") ;;
        frontend) [[ "$NO_FRONTEND" == true ]] || SELECTED+=("$c") ;;
      esac
    done < <(enabled_components)
    ;;
  stop|status|logs|tail)
    for c in "$@"; do
      case "$c" in
        mysql|backend|frontend) REQUESTED+=("$c") ;;
        *) die "未知组件: $c（可选 mysql/backend/frontend）" ;;
      esac
    done
    if [[ ${#REQUESTED[@]} -gt 0 ]]; then
      SELECTED=("${REQUESTED[@]}")
    else
      while IFS= read -r c; do
        [[ -n "$c" ]] && SELECTED+=("$c")
      done < <(enabled_components)
    fi
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

if [[ "$CMD" != "logs" && "$CMD" != "tail" && ${#SELECTED[@]} -eq 0 ]]; then
  die "没有选中任何组件（请检查配置文件里的 *_ENABLED）"
fi

case "$CMD" in
  start)
    log "启动组件: ${SELECTED[*]}"
    fail=0
    for c in "${SELECTED[@]}"; do
      case "$c" in
        mysql)    start_mysql || fail=1 ;;
        backend)  start_backend || fail=1 ;;
        frontend) start_frontend || fail=1 ;;
      esac
    done
    [[ "$fail" -eq 0 ]] || die "有组件启动失败"
    log "启动完成"
    ;;
  stop)
    log "停止组件: ${SELECTED[*]}"
    for c in "${SELECTED[@]}"; do
      case "$c" in
        mysql)    stop_mysql ;;
        backend)  stop_backend ;;
        frontend) stop_frontend ;;
      esac
    done
    log "停止完成"
    ;;
  restart)
    log "重启组件: ${SELECTED[*]}"
    for c in "${SELECTED[@]}"; do
      case "$c" in
        mysql)    stop_mysql ;;
        backend)  stop_backend ;;
        frontend) stop_frontend ;;
      esac
    done
    sleep 1
    fail=0
    for c in "${SELECTED[@]}"; do
      case "$c" in
        mysql)    start_mysql || fail=1 ;;
        backend)  start_backend || fail=1 ;;
        frontend) start_frontend || fail=1 ;;
      esac
    done
    [[ "$fail" -eq 0 ]] || die "有组件启动失败"
    log "重启完成"
    ;;
  status)
    log "组件状态: ${SELECTED[*]}"
    for c in "${SELECTED[@]}"; do
      case "$c" in
        mysql)    status_mysql ;;
        backend)  status_backend ;;
        frontend) status_frontend ;;
      esac
    done
    ;;
  logs)
    for c in "${SELECTED[@]}"; do
      case "$c" in
        mysql)    logs_mysql ;;
        backend)  log "后端日志: $(resolve_path "$BACKEND_LOG")" ;;
        frontend) log "前端日志: $(resolve_path "$FRONTEND_LOG")" ;;
      esac
    done
    list_logs
    ;;
  tail)
    for c in "${SELECTED[@]}"; do
      case "$c" in
        mysql)    tail_mysql ;;
        backend|frontend) : ;;
      esac
    done
    tail_logs
    ;;
esac
