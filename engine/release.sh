#!/usr/bin/env bash
# ============================================================
# shipyard 通用发布引擎
#
# 读取项目自己的清单（推荐放在项目根目录）和 engine/config.json，
# 按 test -> build -> upload -> deploy -> health 顺序执行。
#
# 用法:
#   ./engine/release.sh <project> [--manifest <file>] --env <name> [--tag <version>]
#   ./engine/release.sh --manifest /path/to/project/shipyard.json --env prod
#
# 常用参数:
#   --manifest <file>   项目清单路径；不传时读取 manifests/<project>.json
#   --repo-root <dir>   项目根目录；不传时使用清单里的 repo_root
#   --env <name>        环境名，必填
#   --tag <version>     覆盖版本号
#   --skip-tests        跳过测试
#   --no-build          跳过构建
#   --no-upload         跳过上传
#   --no-deploy         跳过部署
#   --dry-run           只预览
# ============================================================

set -euo pipefail

SHIPYARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PARSER="$SHIPYARD_DIR/engine/lib/manifest.py"
ENGINE_CONFIG="$SHIPYARD_DIR/engine/config.json"

usage() {
  cat <<'USAGE'
用法:
  ./engine/release.sh <project> [--manifest <file>] --env <name> [--tag <version>]
  ./engine/release.sh --manifest /path/to/project/shipyard.json --env prod

常用参数:
  --manifest <file>   项目清单路径；不传时读取 manifests/<project>.json
  --repo-root <dir>   项目根目录；不传时使用清单里的 repo_root
  --env <name>        环境名，必填
  --tag <version>     覆盖版本号
  --skip-tests        跳过测试
  --no-build          跳过构建
  --no-upload         跳过上传
  --no-deploy         跳过部署
  --dry-run           只预览
  --help              显示本帮助
USAGE
}

PROJECT=""
MANIFEST_PATH=""
REPO_ROOT_OVERRIDE=""
ENV=""
TAG=""
DO_TEST=true
DO_BUILD=true
DO_UPLOAD=true
DO_DEPLOY=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)  shift; MANIFEST_PATH="${1:-}" ;;
    --repo-root) shift; REPO_ROOT_OVERRIDE="${1:-}" ;;
    --env)       shift; ENV="${1:-}" ;;
    --tag)       shift; TAG="${1:-}" ;;
    --skip-tests) DO_TEST=false ;;
    --no-build)   DO_BUILD=false ;;
    --no-upload)  DO_UPLOAD=false ;;
    --no-deploy)  DO_DEPLOY=false ;;
    --dry-run|-n) DRY_RUN=true ;;
    -h|--help|help) usage; exit 0 ;;
    -*) echo "[ERROR] 未知参数: $1" >&2; usage >&2; exit 1 ;;
    *)  PROJECT="$1" ;;
  esac
  shift
done

[[ -n "$ENV" ]] || { echo "[ERROR] --env 必填" >&2; exit 1; }
[[ -n "$PROJECT" || -n "$MANIFEST_PATH" ]] || { echo "[ERROR] 需要项目名或 --manifest" >&2; exit 1; }

resolve_abs() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$PWD" "$1" ;;
  esac
}

if [[ -n "$MANIFEST_PATH" ]]; then
  MANIFEST="$(resolve_abs "$MANIFEST_PATH")"
else
  MANIFEST="$SHIPYARD_DIR/manifests/${PROJECT}.json"
fi
[[ -f "$MANIFEST" ]] || { echo "[ERROR] 找不到清单: $MANIFEST" >&2; exit 1; }
MANIFEST_DIR="$(cd "$(dirname "$MANIFEST")" && pwd)"

if ! CFG_OUT="$(python3 "$MANIFEST_PARSER" "$MANIFEST" "$ENV" --config "$ENGINE_CONFIG")"; then
  exit 1
fi
eval "$CFG_OUT"
PROJECT="${CFG_PROJECT}"
TITLE="${CFG_TITLE:-$PROJECT}"

# repo_root 优先级: --repo-root > 清单 repo_root > 清单所在目录
if [[ -n "$REPO_ROOT_OVERRIDE" ]]; then
  REPO_ROOT="$(resolve_abs "$REPO_ROOT_OVERRIDE")"
elif [[ -n "${CFG_REPO_ROOT:-}" ]]; then
  case "$CFG_REPO_ROOT" in
    /*) REPO_ROOT="$CFG_REPO_ROOT" ;;
    *)  REPO_ROOT="$MANIFEST_DIR/$CFG_REPO_ROOT" ;;
  esac
else
  REPO_ROOT="$MANIFEST_DIR"
fi
[[ -d "$REPO_ROOT" ]] || { echo "[ERROR] repo_root 目录不存在: $REPO_ROOT" >&2; exit 1; }
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

path_from_repo() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$REPO_ROOT" "$1" ;;
  esac
}

FULL_APP_DIR="$(path_from_repo "$CFG_APP_DIR")"
FULL_UPLOAD_SOURCE="$(path_from_repo "$CFG_UPLOAD_SOURCE")"
[[ -d "$FULL_APP_DIR" ]] || { echo "[ERROR] app_dir 不存在: $FULL_APP_DIR" >&2; exit 1; }

resolve_tag() {
  [[ -n "$TAG" ]] && { printf '%s' "$TAG"; return 0; }
  if [[ -n "${CFG_TAG_FILE:-}" && -n "${CFG_TAG_PATTERN:-}" ]]; then
    local f
    case "$CFG_TAG_FILE" in
      /*) f="$CFG_TAG_FILE" ;;
      *)  f="$FULL_APP_DIR/$CFG_TAG_FILE" ;;
    esac
    if [[ -f "$f" ]]; then
      local v
      v="$(python3 -c 'import re,sys
try:
    s=open(sys.argv[2],encoding="utf-8",errors="ignore").read()
    m=re.search(sys.argv[1],s,re.M)
    print(m.group(1) if m and m.groups() else "")
except Exception:
    print("")' "$CFG_TAG_PATTERN" "$f")"
      [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    fi
  fi
  printf '%s' "0.0.0"
}
VERSION="$(resolve_tag)"

# ---------- remote ----------
REMOTE="${CFG_ENV_REMOTE:-}"
[[ "$REMOTE" == *@*:*:* ]] || { echo "[ERROR] remote 格式应为 user@host:port:dir: $REMOTE" >&2; exit 1; }
REMOTE_USER="${REMOTE%%@*}"
REST="${REMOTE#*@}"
REMOTE_HOST="${REST%%:*}"
REST2="${REST#*:}"
REMOTE_PORT="${REST2%%:*}"
REMOTE_DIR="${REST2#*:}"

# ---------- ssh key ----------
SSH_KEYFILE=""
if [[ -n "${CFG_ENV_SSH_KEY:-}" ]]; then
  SSH_KEYFILE="${!CFG_ENV_SSH_KEY:-}"
  [[ -n "$SSH_KEYFILE" ]] || SSH_KEYFILE="$CFG_ENV_SSH_KEY"
  [[ -f "$SSH_KEYFILE" ]] || { echo "[ERROR] ssh_key 指向的文件不存在: $SSH_KEYFILE" >&2; exit 1; }
fi
SSH_BASE_ARGS=(-o "ConnectTimeout=${ENGINE_ssh_timeout}")
[[ -n "$SSH_KEYFILE" ]] && SSH_BASE_ARGS+=(-i "$SSH_KEYFILE")
SSH_CMD=(ssh -p "$REMOTE_PORT" "${SSH_BASE_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}")

RSYNC_SSH="ssh -p ${REMOTE_PORT} -o ConnectTimeout=${ENGINE_ssh_timeout}"
if [[ -n "$SSH_KEYFILE" ]]; then
  printf -v _ssh_key_q '%q' "$SSH_KEYFILE"
  RSYNC_SSH+=" -i ${_ssh_key_q}"
fi
BWARG=""
if [[ "${ENGINE_rsync_bwlimit}" -gt 0 ]] 2>/dev/null; then
  BWARG="--bwlimit=${ENGINE_rsync_bwlimit}"
fi

# ---------- log ----------
LOG_DIR="${SHIPYARD_LOG_DIR:-$SHIPYARD_DIR/${ENGINE_log_dir}}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/release-${PROJECT}-${ENV}-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- steps ----------
step_test() {
  [[ "$DO_TEST" == true ]] || { echo "[SKIP] 测试（--skip-tests）"; return 0; }
  [[ "$CFG_TEST_ENABLED" == "True" ]] || { echo "[SKIP] 测试（test.enabled=false）"; return 0; }
  echo "[STEP] 测试: $CFG_TEST_CMD"
  ( cd "$FULL_APP_DIR" && eval "$CFG_TEST_CMD" )
}

step_build() {
  [[ "$DO_BUILD" == true ]] || { echo "[SKIP] 构建（--no-build）"; return 0; }
  [[ "$CFG_BUILD_ENABLED" == "True" ]] || { echo "[SKIP] 构建（build.enabled=false）"; return 0; }
  local script="$FULL_APP_DIR/$CFG_BUILD_SCRIPT"
  [[ -x "$script" ]] || { echo "[ERROR] 构建脚本不存在或不可执行: $script" >&2; return 1; }
  local -a cmd=("./$CFG_BUILD_SCRIPT")
  local -a extra=()
  if [[ -n "${CFG_BUILD_ARGS:-}" ]]; then
    read -r -a extra <<< "$CFG_BUILD_ARGS"
    cmd+=("${extra[@]}")
  fi
  [[ -n "${CFG_BUILD_TAG_ARG:-}" ]] && cmd+=("$CFG_BUILD_TAG_ARG")
  cmd+=("$VERSION")
  echo "[STEP] 构建: (cd $FULL_APP_DIR && ${cmd[*]})"
  ( cd "$FULL_APP_DIR" && "${cmd[@]}" )
}

step_upload() {
  [[ "$DO_UPLOAD" == true ]] || { echo "[SKIP] 上传（--no-upload）"; return 0; }
  [[ "$CFG_UPLOAD_ENABLED" == "True" ]] || { echo "[SKIP] 上传（upload.enabled=false）"; return 0; }
  [[ -d "$FULL_UPLOAD_SOURCE" ]] || { echo "[ERROR] 上传目录不存在: $FULL_UPLOAD_SOURCE" >&2; return 1; }
  local -a extra=()
  local -a tmp=()
  if [[ -n "${CFG_UPLOAD_ARGS:-}" ]]; then
    read -r -a tmp <<< "$CFG_UPLOAD_ARGS"
    extra+=("${tmp[@]}")
  fi
  if [[ -n "${CFG_UPLOAD_EXCLUDE:-}" ]]; then
    read -r -a tmp <<< "$CFG_UPLOAD_EXCLUDE"
    local x
    for x in "${tmp[@]}"; do extra+=(--exclude "$x"); done
  fi
  echo "[STEP] 上传: $FULL_UPLOAD_SOURCE/ -> ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
  # shellcheck disable=SC2086
  rsync -avzP ${BWARG:-} "${extra[@]}" -e "$RSYNC_SSH" -- \
    "${FULL_UPLOAD_SOURCE}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
}

step_deploy() {
  [[ "$DO_DEPLOY" == true ]] || { echo "[SKIP] 部署（--no-deploy）"; return 0; }
  [[ -n "${CFG_ENV_DEPLOY_CMD:-}" ]] || { echo "[SKIP] 部署（未配置 deploy_cmd）"; return 0; }
  local script
  script="$(path_from_repo "$CFG_ENV_DEPLOY_CMD")"
  [[ -f "$script" ]] || { echo "[ERROR] 部署脚本不存在: $script" >&2; return 1; }
  echo "[STEP] 部署: ${REMOTE_USER}@${REMOTE_HOST} <- $CFG_ENV_DEPLOY_CMD"
  {
    echo "set -euo pipefail"
    printf 'REMOTE_TAR_DIR=%q\n' "$REMOTE_DIR"
    printf 'PROJECT=%q\n' "$PROJECT"
    printf 'VERSION=%q\n' "$VERSION"
    cat "$script"
  } | "${SSH_CMD[@]}" 'bash -s'
}

step_health() {
  [[ -n "${CFG_ENV_HEALTH:-}" ]] || { echo "[SKIP] 健康检查（health_url 为空）"; return 0; }
  local i
  echo -n "[STEP] 健康检查: $CFG_ENV_HEALTH"
  for i in $(seq 1 "$ENGINE_health_retries"); do
    if curl -fsS -m 5 "$CFG_ENV_HEALTH" >/dev/null 2>&1; then
      echo " [OK]"
      return 0
    fi
    echo -n "."
    sleep "$ENGINE_health_interval"
  done
  echo " [ERROR]"
  return 1
}

# ---------- main ----------
echo "============================================"
echo "shipyard 通用发布引擎"
echo "  项目    : $PROJECT（$TITLE）"
echo "  环境    : $ENV"
echo "  清单    : $MANIFEST"
echo "  项目根  : $REPO_ROOT"
echo "  版本    : $VERSION"
echo "  日志    : $LOG_FILE"
echo "  步骤    : test=$([ "$CFG_TEST_ENABLED" = True ] && echo on || echo off) build=$([ "$CFG_BUILD_ENABLED" = True ] && echo on || echo off) upload=$([ "$CFG_UPLOAD_ENABLED" = True ] && echo on || echo off) deploy=$([ -n "$CFG_ENV_DEPLOY_CMD" ] && echo on || echo off) health=$([ -n "$CFG_ENV_HEALTH" ] && echo on || echo off)"
echo "============================================"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY-RUN] 将执行以下动作（未做任何修改）"
  echo "  [1] test  : $CFG_TEST_CMD"
  echo "  [2] build : ./$CFG_BUILD_SCRIPT $CFG_BUILD_ARGS $CFG_BUILD_TAG_ARG $VERSION"
  echo "  [3] upload: rsync $FULL_UPLOAD_SOURCE/ -> ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
  echo "  [4] deploy: ssh ${REMOTE_USER}@${REMOTE_HOST} 执行 $CFG_ENV_DEPLOY_CMD"
  echo "  [5] health: curl $CFG_ENV_HEALTH"
  exit 0
fi

step_test
step_build
step_upload
step_deploy
step_health
echo ""
echo "[OK] 发布完成: $PROJECT -> $ENV (版本 $VERSION)"
