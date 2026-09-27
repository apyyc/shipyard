#!/usr/bin/env bash
# ============================================================
# gitflow.sh — 一键 Git 工作流（全自动，配置全部写在脚本顶部）
#
# 流程：git init(如需要) → 身份 → .gitignore → 远程 → 暂存 → 提交 → 推送
# 全程零交互：所有值都在下面「配置区」填好，改完直接 ./gitflow.sh 跑。
#
# 用法：
#   ./gitflow.sh                     # 全自动跑完整流程
#   ./gitflow.sh "修复 xxx"           # 用命令行参数覆盖提交说明（优先级最高）
#   ./gitflow.sh --dry-run           # 只预览将执行的动作，不改任何东西
#   ./gitflow.sh status              # 查看状态 + 最近提交 + 远程
#   ./gitflow.sh --help
# ============================================================

set -euo pipefail

# ╔═════════════════════════════════════════════════════════════╗
#                           配 置 区
# ╚═════════════════════════════════════════════════════════════╝

# 提交者姓名（自动写入本仓库配置）
GIT_NAME="apyyc"                       
# 提交者邮箱
GIT_EMAIL="2479511984@qq.com"            
# 远程仓库 URL，如 https://github.com/xxx/repo.git（留空 = 不配置远程，提交后不推送） 
GIT_REMOTE="https://github.com/apyyc/debian13-workspace-sh.git"                          
# 主分支名（新仓库初始化用）
BRANCH="main"                          
# 暂存范围：all=全部改动 / paths=只暂存下面列出的路径
STAGE_MODE="paths"                      
# STAGE_MODE=paths 时生效（空格分隔多个路径）
STAGE_PATHS="README.md .gitignore ./gitflow.sh ./proxyctl.sh ./uninstall-pkg.sh"           

COMMIT_MESSAGE=""                      # 提交说明：留空则自动生成 "chore: 自动提交 <时间>"
                                       #   （命令行参数优先级更高：./gitflow.sh "xxx"）

AUTO_PUSH=true                         # true=提交后自动 git push（需已配置 GIT_REMOTE）
SECRET_GUARD="warn"                    # 密钥保护：warn=告警但继续 / block=发现密钥即中止 / off=关闭

# ╚═════════════════════════════════════════════════════════════╝
# （以下一般不用动）
# ============================================================

DRY_RUN=false
CLI_MSG=""

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=true ;;
    -h|--help|help) sed -n '1,32p' "$0" | sed 's/^# //' | grep -v '^$'; exit 0 ;;
    -*) echo "❌ 未知参数: $arg"; exit 1 ;;
    *) CLI_MSG="$arg" ;;
  esac
done

is_repo() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
gitq() { git "$@" 2>/dev/null || true; }

# ---------- 1. 初始化仓库 ----------
ensure_repo() {
  if is_repo; then
    echo "✅ 已是 git 仓库"
    return 0
  fi
  # 现代 git 直接 -b 建分支；老 git 不认 -b 时退化为 init + 改名
  git init -b "$BRANCH" >/dev/null 2>&1 || git init >/dev/null
  [ "$(git symbolic-ref --short HEAD 2>/dev/null || true)" = "$BRANCH" ] \
    || git checkout -b "$BRANCH" >/dev/null 2>&1 || true
  git config pull.rebase false
  echo "  ✅ 已 git init（分支 $BRANCH）"
}

# ---------- 2. 身份配置 ----------
ensure_identity() {
  [ -n "$GIT_NAME" ] && git config user.name "$GIT_NAME"
  [ -n "$GIT_EMAIL" ] && git config user.email "$GIT_EMAIL"
  local n e
  n="$(gitq config user.name)"; e="$(gitq config user.email)"
  if [ -n "$n" ] && [ -n "$e" ]; then
    echo "  ✅ 身份: $n <$e>"
  else
    echo "  ⚠️ 身份不完整（请填 GIT_NAME / GIT_EMAIL），提交会失败"
  fi
}

# ---------- 3. .gitignore ----------
ensure_gitignore() {
  [ -f .gitignore ] && { echo "  .gitignore 已存在，跳过"; return 0; }
  cat > .gitignore <<'EOF'
# ── Python ──
__pycache__/
*.py[cod]
.venv/
venv/
.env
*.egg-info/

# ── Node ──
node_modules/
dist/
build/

# ── 运行时数据 / 产物（不入库）──
logs/
*.log
uploads/
outputs/
downloads/
models/
temp/
workspace/
*.tar
*.tar.gz

# ── 系统 / 编辑器 ──
.DS_Store
.idea/
.vscode/
EOF
  echo "  已生成 .gitignore（按需编辑后重跑）"
}

# ---------- 4. 远程仓库 ----------
ensure_remote() {
  [ -n "$GIT_REMOTE" ] || { echo "  （GIT_REMOTE 为空，不配置远程）"; return 0; }
  local cur
  cur="$(gitq remote get-url origin 2>/dev/null || true)"
  if [ "$cur" = "$GIT_REMOTE" ]; then
    echo "  ✅ 远程已存在: origin = $GIT_REMOTE"
  else
    gitq remote remove origin
    git remote add origin "$GIT_REMOTE"
    echo "  ✅ 已配置远程: origin = $GIT_REMOTE"
  fi
}

# ---------- 5. 密钥检查（提交前，非交互）----------
check_secrets() {
  [ "$SECRET_GUARD" = "off" ] && return 0
  local hit
  hit="$(git diff --cached 2>/dev/null | grep -iE "api[_-]?key|access[_-]?token|secret|password|passwd|BEGIN (RSA|OPENSSH|EC |PRIVATE)" \
        | grep -vE '^[+-]{3}' | head -5 || true)"
  [ -z "$hit" ] && return 0
  echo ""
  echo "⚠️  暂存内容疑似包含密钥/密码："
  echo "$hit" | sed 's/^/    /'
  if [ "$SECRET_GUARD" = "block" ]; then
    echo "❌ 已按配置中止（SECRET_GUARD=block）。处理完密钥再重跑。"
    return 1
  fi
  echo "⚠️  已按配置继续提交（SECRET_GUARD=warn）。"
  return 0
}

# ---------- 6. 提交 ----------
resolve_message() {
  [ -n "$CLI_MSG" ] && { echo "$CLI_MSG"; return 0; }
  [ -n "$COMMIT_MESSAGE" ] && { echo "$COMMIT_MESSAGE"; return 0; }
  echo "chore: 自动提交 $(date '+%Y-%m-%d %H:%M')"
}

stage_changes() {
  if [ "$STAGE_MODE" = "paths" ] && [ -n "$STAGE_PATHS" ]; then
    git add $STAGE_PATHS
    echo "  📁 已暂存指定路径: $STAGE_PATHS"
  else
    git add -A
    echo "  📁 已暂存全部改动"
  fi
}

maybe_push() {
  local remote
  remote="$(gitq remote get-url origin 2>/dev/null || true)"
  [ -n "$remote" ] || { echo "  （未配置远程，跳过推送）"; return 0; }
  if [ "$AUTO_PUSH" != true ]; then
    echo "  （AUTO_PUSH=false，跳过推送）"
    return 0
  fi
  local branch
  branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo "$BRANCH")"
  git push -u origin "$branch" && echo "  ✅ 已推送 origin/$branch"
}

# ---------- 完整流程 ----------
cmd_full() {
  echo "════════════ Git 一键流程 ════════════"
  echo "  身份 : $GIT_NAME <$GIT_EMAIL>"
  echo "  远程 : ${GIT_REMOTE:-（未配置）}"
  echo "  分支 : $BRANCH"
  echo ""

  if [ "$DRY_RUN" = true ]; then
    echo "▶ dry-run：将执行以下动作（未做任何修改）"
    is_repo || echo "   - git init（分支 $BRANCH）"
    echo "   - 设置 user.name/email = $GIT_NAME <$GIT_EMAIL>"
    [ -f .gitignore ] || echo "   - 生成 .gitignore"
    [ -n "$GIT_REMOTE" ] && echo "   - git remote add origin $GIT_REMOTE"
    if is_repo && [ -z "$(git status --porcelain 2>/dev/null || true)" ]; then
      echo "   - （工作区干净，无需提交）"
    else
      [ "$STAGE_MODE" = "paths" ] && echo "   - git add $STAGE_PATHS" || echo "   - git add -A"
      echo "   - git commit -m \"$(resolve_message)\""
      [ -n "$GIT_REMOTE" ] && [ "$AUTO_PUSH" = true ] && echo "   - git push -u origin $BRANCH"
    fi
    exit 0
  fi

  ensure_repo
  echo "➤ 身份 ...";  ensure_identity
  echo "➤ .gitignore ..."; ensure_gitignore
  echo "➤ 远程 ...";   ensure_remote

  # 无改动
  if [ -z "$(git status --porcelain 2>/dev/null || true)" ]; then
    echo ""
    echo "✅ 工作区干净，没有需要提交的改动"
    echo "最近提交："
    git log --oneline -5 2>/dev/null || echo "  （还没有任何提交）"
    return 0
  fi

  echo ""
  echo "===== 当前改动 ====="
  git status --short
  echo ""
  echo "➤ 暂存 ...";  stage_changes
  echo ""
  echo "===== 已暂存（预览）====="
  git diff --cached --stat 2>/dev/null || true
  [ -z "$(git diff --cached --name-only 2>/dev/null || true)" ] && { echo "  （没有暂存内容，取消）"; return 1; }

  check_secrets || return 1

  echo "➤ 提交 ..."
  git commit -m "$(resolve_message)"
  echo "  ✅ 已提交"

  echo "➤ 推送 ..."
  maybe_push
  echo ""
  echo "✅ 完成。"
}

# ---------- status ----------
cmd_status() {
  if ! is_repo; then echo "❌ 不是 git 仓库（先跑 ./gitflow.sh）"; return 1; fi
  echo "===== 状态 ====="
  if [ -z "$(git status --porcelain 2>/dev/null || true)" ]; then
    echo "✅ 工作区干净"
  else
    git status --short
  fi
  echo ""
  echo "===== 最近提交 ====="
  git log --oneline -8 2>/dev/null || echo "（还没有任何提交）"
  echo ""
  echo "===== 远程 ====="
  if [ -n "$(gitq remote -v)" ]; then
    git remote -v
  else
    echo "（未配置远程）"
  fi
}

# ---------- 入口 ----------
case "${1:-}" in
  status) cmd_status ;;
  *)      cmd_full ;;
esac
