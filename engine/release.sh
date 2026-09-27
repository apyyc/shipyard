#!/usr/bin/env bash
# ============================================================
# shipyard — 通用发布引擎（应用层：编排，领域校验交给 lib/manifest.py）
#
# 读取 manifests/<project>.json 清单 + engine/config.json 全局配置，
# 按 test → build → upload → deploy → health 顺序执行，任一步失败即中止。
# 引擎不写死任何项目，新项目接入 = 新增一份清单 + ops/ 部署脚本。
#
# 用法：
#   ./release.sh <project> --env <staging|prod> [--tag X]
#     --env 必填（staging / prod 之一，强制指定防误发）
#     --tag X        覆盖版本号（默认从清单 tag_source 自动读）
#     --skip-tests   跳过测试闸门（应急）
#     --no-build     跳过构建（用已有产物发布）
#     --no-upload    跳过上传
#     --no-deploy    跳过远程部署
#     --dry-run      只预览动作，不改任何东西
#     --help
#
# 依赖：python3、rsync、ssh、curl；构建/测试随清单
# ============================================================

set -euo pipefail

# shipyard 项目根（脚本上两级）；仓库根 = 其上两级（app_dir 等相对仓库根）
SHIPYARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${SHIPYARD_DIR}/.." && pwd)"

# ---------- 参数 ----------
PROJECT=""
ENV=""
TAG=""
DO_TEST=true
DO_BUILD=true
DO_UPLOAD=true
DO_DEPLOY=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        shift; ENV="${1:-}" ;;
    --tag)        shift; TAG="${1:-}" ;;
    --skip-tests) DO_TEST=false ;;
    --no-build)   DO_BUILD=false ;;
    --no-upload)  DO_UPLOAD=false ;;
    --no-deploy)  DO_DEPLOY=false ;;
    --dry-run|-n) DRY_RUN=true ;;
    -h|--help|help)
      sed -n '1,25p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^$'; exit 0 ;;
    -*) echo "❌ 未知参数: $1（--help 查看帮助）"; exit 1 ;;
    *)  PROJECT="$1" ;;
  esac
  shift
done

[ -n "$PROJECT" ] || { echo "❌ 缺少项目名（--help 查看帮助）"; exit 1; }
[ -n "$ENV" ]     || { echo "❌ --env 必填（staging / prod，强制指定防误发）"; exit 1; }
MANIFEST="${SHIPYARD_DIR}/manifests/${PROJECT}.json"
[ -f "$MANIFEST" ] || { echo "❌ 找不到清单: $MANIFEST"; exit 1; }

# ---------- 领域层：解析 + 严格校验清单，导出 CFG_*/ENGINE_* ----------
CFG_OUT="$(python3 "${SHIPYARD_DIR}/engine/lib/manifest.py" "$MANIFEST" "$ENV" \
           --config "${SHIPYARD_DIR}/engine/config.json" || echo "__PARSE_FAIL__")"
if [[ "$CFG_OUT" == *__PARSE_FAIL__* ]]; then
  echo "$CFG_OUT" | grep -v '__PARSE_FAIL__' || true
  exit 1
fi
eval "$CFG_OUT"

# ---------- 路径：app_dir / source_dir 支持相对仓库根或绝对路径 ----------
abs_or_join() { case "$1" in /*) echo "$1" ;; *) echo "${REPO_ROOT}/$1" ;; esac; }
FULL_APP_DIR="$(abs_or_join "$CFG_APP_DIR")"
FULL_UPLOAD_SOURCE="$(abs_or_join "$CFG_UPLOAD_SOURCE")"

# ---------- 版本号：--tag > tag_source 自动读 > 0.0.0 ----------
resolve_tag() {
  [ -n "$TAG" ] && { echo "$TAG"; return; }
  if [ -n "$CFG_TAG_FILE" ] && [ -n "$CFG_TAG_PATTERN" ]; then
    local f="$(abs_or_join "${CFG_APP_DIR}/${CFG_TAG_FILE}")"
    [ -f "$f" ] || { echo "0.0.0"; return; }
    local v
    v="$(python3 -c 'import re,sys
p, fn = sys.argv[1], sys.argv[2]
try:
    s = open(fn, encoding="utf-8", errors="ignore").read()
    m = re.search(p, s, re.M)
    print(m.group(1) if m else "")
except Exception:
    print("")' "$CFG_TAG_PATTERN" "$f")"
    [ -n "$v" ] && { echo "$v"; return; }
  fi
  echo "0.0.0"
}
VERSION="$(resolve_tag)"

# ---------- remote: user@host:port:dir ----------
REMOTE_USER="${CFG_ENV_REMOTE%%@*}"; REST="${CFG_ENV_REMOTE#*@}"
REMOTE_HOST="${REST%%:*}"; REST2="${REST#*:}"
REMOTE_PORT="${REST2%%:*}"; REMOTE_DIR="${REST2#*:}"

# ---------- ssh 密钥：清单 ssh_key 是环境变量名，取环境变量值作为密钥文件路径 ----------
SSH_KEYFILE=""
if [ -n "$CFG_ENV_SSH_KEY" ]; then
  SSH_KEYFILE="${!CFG_ENV_SSH_KEY:-}"
  [ -n "$SSH_KEYFILE" ] || SSH_KEYFILE="$CFG_ENV_SSH_KEY"
  [ -f "$SSH_KEYFILE" ] || { echo "❌ ssh_key 指向的文件不存在: $SSH_KEYFILE"; exit 1; }
fi
SSH_BASE_ARGS=(-o ConnectTimeout="${ENGINE_ssh_timeout}")
[ -n "$SSH_KEYFILE" ] && SSH_BASE_ARGS+=(-i "$SSH_KEYFILE")
RSYNC_SSH="ssh -p ${REMOTE_PORT} ${SSH_BASE_ARGS[*]}"
BWARG=""; [ "${ENGINE_rsync_bwlimit}" -gt 0 ] 2>/dev/null && BWARG="--bwlimit=${ENGINE_rsync_bwlimit}"

# ---------- 日志 ----------
LOG_DIR="${SHIPYARD_DIR}/${ENGINE_log_dir}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/release-${CFG_PROJECT}-${ENV}-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- 步骤 ----------
step_test() {
  [ "$CFG_TEST_ENABLED" = "True" ] || { echo "   （跳过，test.enabled=false）"; return 0; }
  echo "  ( cd \"$FULL_APP_DIR\" && eval \"$CFG_TEST_CMD\" )"
  ( cd "$FULL_APP_DIR" && eval "$CFG_TEST_CMD" )
}

step_build() {
  [ "$CFG_BUILD_ENABLED" = "True" ] || { echo "   （跳过，build.enabled=false）"; return 0; }
  local src="${FULL_APP_DIR}/${CFG_BUILD_SCRIPT}"
  [ -x "$src" ] || { echo "❌ 构建脚本不存在或不可执行: $src"; return 1; }
  # shellcheck disable=SC2086
  ( cd "$FULL_APP_DIR" && ./"$CFG_BUILD_SCRIPT" $CFG_BUILD_ARGS "$CFG_BUILD_TAG_ARG" "$VERSION" )
}

step_upload() {
  [ "$CFG_UPLOAD_ENABLED" = "True" ] || { echo "   （跳过，upload.enabled=false）"; return 0; }
  local src="$FULL_UPLOAD_SOURCE"
  [ -d "$src" ] || { echo "❌ 上传目录不存在: $src"; return 1; }
  # shellcheck disable=SC2086
  rsync -avzP $BWARG -e "${RSYNC_SSH}" \
    "${src}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
}

step_deploy() {
  [ -n "$CFG_ENV_DEPLOY_CMD" ] || { echo "   （跳过，未配置 deploy_cmd）"; return 0; }
  local script="$(abs_or_join "$CFG_ENV_DEPLOY_CMD")"
  [ -f "$script" ] || { echo "❌ 部署脚本不存在: $script"; return 1; }
  {
    echo "set -euo pipefail"
    echo "REMOTE_TAR_DIR=${REMOTE_DIR@Q}"
    echo "PROJECT=${CFG_PROJECT@Q}"
    echo "VERSION=${VERSION@Q}"
    cat "$script"
  } | ssh -p "$REMOTE_PORT" "${SSH_BASE_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" 'bash -s'
}

step_health() {
  [ -n "$CFG_ENV_HEALTH" ] || { echo "   （跳过，health_url 为空）"; return 0; }
  local i
  for i in $(seq 1 "${ENGINE_health_retries}"); do
    curl -fsS -m 5 "$CFG_ENV_HEALTH" >/dev/null 2>&1 && { echo "   ✅ 服务已恢复: $CFG_ENV_HEALTH"; return 0; }
    echo -n "."; sleep "${ENGINE_health_interval}"
  done
  echo " ✗ 健康检查超时: $CFG_ENV_HEALTH"
  return 1
}

# ---------- 主流程 ----------
echo "═══════════ shipyard 通用发布引擎 ═══════════"
echo "  项目     : $CFG_PROJECT（$CFG_TITLE）"
echo "  环境     : $ENV（${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}${REMOTE_DIR}）"
echo "  版本     : $VERSION（schema $CFG_SCHEMA_VERSION）"
echo "  日志     : $LOG_FILE"
echo "  步骤     : test=$([ "$CFG_TEST_ENABLED" = True ] && echo on || echo off)"
echo "           build=$([ "$CFG_BUILD_ENABLED" = True ] && echo on || echo off)"
echo "           upload=$([ "$CFG_UPLOAD_ENABLED" = True ] && echo on || echo off)"
echo "           deploy=$([ -n "$CFG_ENV_DEPLOY_CMD" ] && echo on || echo off)"
echo "           health=$([ -n "$CFG_ENV_HEALTH" ] && echo on || echo off)"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "▶ dry-run：将执行以下动作（未做任何修改）"
  echo "   [1] test  : $CFG_TEST_CMD（在 $FULL_APP_DIR 下）"
  echo "   [2] build : ./$CFG_BUILD_SCRIPT $CFG_BUILD_ARGS $CFG_BUILD_TAG_ARG $VERSION"
  echo "   [3] upload: rsync $FULL_UPLOAD_SOURCE/ → ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
  echo "   [4] deploy: ssh ${REMOTE_USER}@${REMOTE_HOST} 执行 $CFG_ENV_DEPLOY_CMD"
  echo "   [5] health: curl $CFG_ENV_HEALTH"
  exit 0
fi

echo "➤ [1/5] 测试闸门 ...";   step_test
echo "➤ [2/5] 构建闸门 ...";   step_build
echo "➤ [3/5] 上传 ...";       step_upload
echo "➤ [4/5] 部署 ...";       step_deploy
echo "➤ [5/5] 健康检查 ...";   step_health
echo ""
echo "✅ 发布完成（$CFG_PROJECT → $ENV，版本 $VERSION）"
