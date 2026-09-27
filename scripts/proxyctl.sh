#!/usr/bin/env bash
# ============================================================
# proxyctl.sh — Clash/mihomo 代理管理脚本（本机/局域网通用）
#
# 前提：Clash 系代理（Clash / Clash Meta / mihomo 等，配置都差不多，
#       同一个 config.yaml 格式）已在某台机器上跑通，本脚本只负责
#       把系统的 http_proxy / https_proxy / all_proxy 指向它。
#
# 功能：
#   start    启动代理    → 写入 /etc/environment（新登录会话/新进程生效）
#   stop     关闭代理    → 从 /etc/environment 移除代理配置
#   enable   永久启动    → start + 写入 /etc/profile.d/proxy.sh（登录 shell 自动带，重启也生效）
#   disable  永久关闭    → 清理上面全部（environment + profile.d）
#   status   查看状态    → 当前配置与代理环境变量
#
# 用法：
#   source ./proxyctl.sh start   # 让【当前 shell】立即生效（推荐：export 只对当前会话有效）
#   ./proxyctl.sh start          # 系统级生效（当前 shell 需重开或 source）
#   ./proxyctl.sh enable         # 永久启动（开机/登录自动带代理）
#   ./proxyctl.sh disable        # 永久关闭
#   ./proxyctl.sh status
# ============================================================

set -euo pipefail

# ---------- 可配置参数（按需修改） ----------
# 代理主机：代理装在本机就留 127.0.0.1；装在别的机器填它的 IP（如 192.168.18.8）
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
# 端口：以代理软件 config.yaml 里配的为准（默认值是本机 mihomo 的常用端口）
MIXED_PORT="${MIXED_PORT:-7893}"      # 混合口 mixed-port：HTTP/HTTPS/SOCKS5 都能走
SOCKS_PORT="${SOCKS_PORT:-7891}"      # SOCKS5 口 socks-port（all_proxy 用）
HTTP_PORT="${HTTP_PORT:-7890}"        # HTTP 代理口 port（备用；一般用混合口即可）
# 直连白名单（本地与内网不走代理）
NO_PROXY_VAL="${NO_PROXY_VAL:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.local}"

# 由上面拼出的代理地址（一般不用改）。
# http/https 统一走混合口：Clash/mihomo 的混合口同时支持 HTTP 与 HTTPS（CONNECT）
PROXY_HTTP="http://${PROXY_HOST}:${MIXED_PORT}"
PROXY_HTTPS="http://${PROXY_HOST}:${MIXED_PORT}"
PROXY_SOCKS="socks5://${PROXY_HOST}:${SOCKS_PORT}"

ENV_FILE="/etc/environment"
PROFILE_D="/etc/profile.d/proxy.sh"
BLOCK_START="# >>> proxyctl start >>>"
BLOCK_END="# <<< proxyctl end <<<"

# 当前是否 root（写系统文件需要）
NEED_ROOT_MSG="需要 root 权限写 ${ENV_FILE}，请用 sudo ./$(basename "$0") 或 sudo -s 后重试。"

# ---------- 工具：写 / 清一个“标记块” ----------
# 把内容写进 开始标记 ~ 结束标记 之间（幂等，重复执行不会叠加）
write_block() {
  local file="$1" block="$2"
  mkdir -p "$(dirname "$file")"
  local tmp; tmp="$(mktemp)"
  # 去掉旧块；grep 无匹配会返回 1，用 || true 避免 set -e 中断
  sed "/^${BLOCK_START}$/,/^${BLOCK_END}$/d" "$file" 2>/dev/null | grep -v '^$' > "$tmp" || true
  # 追加新块
  printf '\n%s\n%s\n%s\n' "$BLOCK_START" "$block" "$BLOCK_END" >> "$tmp"
  mv -f "$tmp" "$file"
}

clear_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tmp; tmp="$(mktemp)"
  sed "/^${BLOCK_START}$/,/^${BLOCK_END}$/d" "$file" 2>/dev/null | grep -v '^$' > "$tmp" || true
  mv -f "$tmp" "$file"
  rm -f "$tmp"
}

# /etc/environment 用 KEY=VALUE（无 export 前缀）
ENV_BLOCK="$(cat <<EOF
http_proxy=${PROXY_HTTP}
https_proxy=${PROXY_HTTPS}
HTTP_PROXY=${PROXY_HTTP}
HTTPS_PROXY=${PROXY_HTTPS}
all_proxy=${PROXY_SOCKS}
ALL_PROXY=${PROXY_SOCKS}
no_proxy=${NO_PROXY_VAL}
NO_PROXY=${NO_PROXY_VAL}
EOF
)"

# /etc/profile.d 用 export 形式（登录 shell 自动加载）
PROFILE_BLOCK="$(cat <<EOF
export http_proxy='${PROXY_HTTP}'
export https_proxy='${PROXY_HTTPS}'
export HTTP_PROXY='${PROXY_HTTP}'
export HTTPS_PROXY='${PROXY_HTTPS}'
export all_proxy='${PROXY_SOCKS}'
export ALL_PROXY='${PROXY_SOCKS}'
export no_proxy='${NO_PROXY_VAL}'
export NO_PROXY='${NO_PROXY_VAL}'
EOF
)"

require_root() {
  [ "$(id -u)" = "0" ] || { echo "❌ $NEED_ROOT_MSG" >&2; exit 1; }
}

# ---------- 子命令 ----------
cmd_start() {
  require_root
  write_block "$ENV_FILE" "$ENV_BLOCK"
  echo "✅ 已启动代理（写入 $ENV_FILE）："
  echo "   http_proxy = $PROXY_HTTP"
  echo "   https_proxy= $PROXY_HTTPS"
  echo "   all_proxy  = $PROXY_SOCKS"
  echo ""
  echo "   当前 shell 立即生效： source $0 start"
  echo "   新开的登录会话/终端会自动带代理。"
}

cmd_stop() {
  require_root
  clear_block "$ENV_FILE"
  echo "✅ 已关闭代理（已从 $ENV_FILE 移除）。"
  echo "   若当前 shell 仍带代理，执行： unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY"
}

cmd_enable() {
  require_root
  write_block "$ENV_FILE" "$ENV_BLOCK"
  write_block "$PROFILE_D" "$PROFILE_BLOCK"
  echo "✅ 已永久启动代理："
  echo "   - $ENV_FILE（系统级，新进程生效）"
  echo "   - $PROFILE_D（登录 shell 自动加载，重启后仍生效）"
  echo "   生效信息："
  echo "   http_proxy = $PROXY_HTTP / https_proxy = $PROXY_HTTPS / all_proxy = $PROXY_SOCKS"
  echo "   当前 shell 立即生效： source $0 start"
}

cmd_disable() {
  require_root
  clear_block "$ENV_FILE"
  rm -f "$PROFILE_D"
  echo "✅ 已永久关闭代理："
  echo "   - 已从 $ENV_FILE 移除"
  echo "   - 已删除 $PROFILE_D"
  echo "   当前 shell 立即清除： unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY"
}

cmd_status() {
  echo "===== 代理目标（本脚本配置）====="
  echo "  host      = $PROXY_HOST"
  echo "  http      = $PROXY_HTTP"
  echo "  https     = $PROXY_HTTPS"
  echo "  socks     = $PROXY_SOCKS"
  echo ""
  echo "===== 持久配置文件 ====="
  [ -f "$ENV_FILE" ] && grep -q "$BLOCK_START" "$ENV_FILE" && echo "  $ENV_FILE      : ✅ 已启用" || echo "  $ENV_FILE      : （未启用）"
  [ -f "$PROFILE_D" ] && echo "  $PROFILE_D : ✅ 已启用（永久）" || echo "  $PROFILE_D : （未启用）"
  echo ""
  echo "===== 当前 shell 环境变量 ====="
  echo "  http_proxy  = ${http_proxy:-（未设置）}"
  echo "  https_proxy = ${https_proxy:-（未设置）}"
  echo "  all_proxy   = ${all_proxy:-（未设置）}"
  echo "  no_proxy    = ${no_proxy:-（未设置）}"
  echo ""
  echo "===== 连通性测试 ====="
  curl -s -o /dev/null -w "  google  -> HTTP:%{http_code} (%{time_total}s)\n" --max-time 8 https://www.google.com 2>/dev/null || echo "  google  -> 失败/未通"
  curl -s -o /dev/null -w "  baidu   -> HTTP:%{http_code} (%{time_total}s)\n" --max-time 8 https://www.baidu.com 2>/dev/null || echo "  baidu   -> 失败/未通"
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  enable)  cmd_enable ;;
  disable) cmd_disable ;;
  status)  cmd_status ;;
  on)      cmd_start ;;
  off)     cmd_stop ;;
  -h|--help|help)
    sed -n '1,25p' "$0" | sed 's/^# //' | grep -v '^$' ;;
  *)
    echo "用法: $(basename "$0") {start|stop|enable|disable|status|on|off}"
    echo "  start     启动代理（写入 /etc/environment）"
    echo "  stop      关闭代理"
    echo "  enable    永久启动（+ /etc/profile.d/proxy.sh，重启生效）"
    echo "  disable   永久关闭"
    echo "  status    查看状态"
    echo "  当前 shell 立即生效请用： source $(basename "$0") start"
    exit 1 ;;
esac
