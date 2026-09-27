#!/usr/bin/env bash
# ============================================================
# uninstall-pkg.sh — 一键卸载 dpkg/apt 安装的程序（含残留清理）
#
# 功能：
#   - 自动解析：给「命令名」或「包名」都行（如 clashmi / clash-for-linux）
#   - sudo apt-get remove --purge 彻底卸载（含 dpkg 管理的配置文件）
#   - 清理残留：/etc、/var/lib、/opt、/usr/local 下的配置数据目录
#   - 清理家目录残留：~/.config、~/.cache、~/.local/share、~/.<名>
#   - 清理 systemd 服务文件（系统级 + 用户级）并 daemon-reload
#   - 检查卸载后是否还有孤儿可执行文件残留（手动放置的）
#
# 用法：
#   ./uninstall-pkg.sh <程序名|命令名>      # 一键卸载（有确认提示）
#   ./uninstall-pkg.sh -y <程序名>          # 跳过确认，直接执行
#   ./uninstall-pkg.sh --list <程序名>      # 只查看包信息，不卸载
#   ./uninstall-pkg.sh --dry-run <程序名>   # 只打印将执行的动作，不改任何东西
#   ./uninstall-pkg.sh --help
#
# 示例：
#   ./uninstall-pkg.sh clashmi              # 卸载 clashmi（命令名/包名自动识别）
#   ./uninstall-pkg.sh --dry-run clashmi    # 先看会删什么
#
# 安全保护：拒绝卸载核心系统包（dpkg/apt/bash/systemd/libc6 等）
# ============================================================

set -euo pipefail

# ---------- 参数 ----------
NAME=""
DRY_RUN=false
ASSUME_YES=false
MODE_LIST=false

usage() {
  sed -n '1,40p' "$0" | sed 's/^# //' | grep -v '^$'
}

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n)  DRY_RUN=true ;;
    -y|--yes)      ASSUME_YES=true ;;
    --list|-l)     MODE_LIST=true ;;
    -h|--help|help) usage; exit 0 ;;
    -*) echo "❌ 未知参数: $arg"; usage; exit 1 ;;
    *) NAME="$arg" ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "❌ 用法: $0 <程序名|命令名>  （加 --dry-run 先看会做什么）"
  echo "   示例: $0 clashmi"
  exit 1
fi

# ---------- 安全保护：拒绝卸载核心系统包 ----------
PROTECTED='^(dpkg|apt|apt-get|aptitude|bash|dash|coreutils|systemd|systemd-sysv|libc6|libstdc\+\+|linux-image|linux-headers|grub|sudo|util-linux|passwd|login|openssh|network-manager|dbus)$'
if echo "$NAME" | grep -qiE "$PROTECTED"; then
  echo "❌ 出于安全考虑，拒绝卸载核心系统包: $NAME"
  exit 1
fi

# ---------- 解析包名：命令名 → 所属 dpkg 包 ----------
resolve_pkg() {
  local name="$1"
  # 1) 直接是已安装的包名
  if dpkg -s "$name" >/dev/null 2>&1; then
    echo "$name"; return 0
  fi
  # 2) 是命令 → 找它所属的包
  local bin
  bin="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$bin" ]; then
    local owner
    owner="$(dpkg -S "$bin" 2>/dev/null | head -1 | sed 's/: .*//' || true)"
    if [ -n "$owner" ]; then
      echo "$owner"; return 0
    fi
    echo "__ORPHAN_BIN:$bin" >&2
    return 2
  fi
  return 1
}

PKG=""
ORPHAN_BIN=""
RESOLVE_OUT="$(resolve_pkg "$NAME" 2>&1 || true)"
case "$RESOLVE_OUT" in
  __ORPHAN_BIN:*)
    ORPHAN_BIN="${RESOLVE_OUT#__ORPHAN_BIN:}"
    ;;
  *)
    if dpkg -s "$RESOLVE_OUT" >/dev/null 2>&1; then
      PKG="$RESOLVE_OUT"
    fi
    ;;
esac

# 没找到包：提示常见排错
if [ -z "$PKG" ]; then
  echo "❌ 找不到包或命令: $NAME"
  if [ -n "$ORPHAN_BIN" ]; then
    echo "   可执行文件存在但不是 dpkg 包所有（可能手动安装）: $ORPHAN_BIN"
    echo "   该场景 dpkg 无法卸载，需手动清理："
    echo "     rm -f $ORPHAN_BIN"
    echo "     并删除其配置/数据目录（如 /etc/、/opt/、~/.config/ 下同名目录）"
  fi
  echo ""
  echo "   可尝试："
  echo "     dpkg -l | grep -i ${NAME}"            # 找相近包名
  echo "     apt-cache search ${NAME}"             # 找包
  echo "     command -v ${NAME}"                   # 找命令真实路径
  exit 1
fi

# ---------- 收集残留（卸载前先摸清家底）----------
# 包内文件（用于提示规模）
PKG_FILES="$(dpkg -L "$PKG" 2>/dev/null | grep -v '^\.$' || true)"
PKG_FILES_COUNT="$(echo "$PKG_FILES" | grep -c . || true)"
INSTALLED_KB="$(dpkg-query -W -f='${Installed-Size}' "$PKG" 2>/dev/null || echo "?")"

# 服务文件（系统 + 用户）
SVC_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && SVC_FILES+=("$f")
done < <(find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system \
            "$HOME/.config/systemd/user" \
            -maxdepth 1 -type f -iname "*${NAME}*.service" 2>/dev/null || true)

# 常见残留配置/数据目录
LEFTOVER_DIRS=()
for d in "/etc/${PKG}" "/etc/${NAME}" \
         "/var/lib/${PKG}" "/var/log/${PKG}" \
         "/opt/${PKG}" "/opt/${NAME}" \
         "/usr/local/share/${PKG}" "/usr/local/share/${NAME}" \
         "${HOME}/.config/${PKG}" "${HOME}/.config/${NAME}" \
         "${HOME}/.cache/${PKG}" "${HOME}/.cache/${NAME}" \
         "${HOME}/.local/share/${PKG}" "${HOME}/.local/share/${NAME}" \
         "${HOME}/.${PKG}" "${HOME}/.${NAME}"; do
  if [ -e "$d" ]; then
    case " ${LEFTOVER_DIRS[*]} " in
      *" $d "*) ;;   # 去重
      *) LEFTOVER_DIRS+=("$d") ;;
    esac
  fi
done

# ---------- 展示计划 ----------
echo ""
echo "═══════════════════════════════════════════"
echo "📦 包名:        $PKG"
echo "   状态:        $(dpkg -s "$PKG" | awk -F': ' '/^Status/{print $2}')"
echo "   版本:        $(dpkg -s "$PKG" | awk -F': ' '/^Version/{print $2}')"
echo "   占用:        ${INSTALLED_KB} KB（${PKG_FILES_COUNT} 个文件）"
echo "───────────────────────────────────────────"
if [ "${#SVC_FILES[@]}" -gt 0 ]; then
  echo "🛑 systemd 服务文件:"
  for s in "${SVC_FILES[@]}"; do echo "   $s"; done
else
  echo "🛑 systemd 服务文件: （无）"
fi
if [ "${#LEFTOVER_DIRS[@]}" -gt 0 ]; then
  echo "🗑  残留目录（卸载后清理）:"
  for d in "${LEFTOVER_DIRS[@]}"; do echo "   $d"; done
else
  echo "🗑  残留目录: （无）"
fi
echo "═══════════════════════════════════════════"

if [ "$MODE_LIST" = true ]; then
  echo "（--list 模式：仅展示，不卸载）"
  exit 0
fi

# ---------- dry-run ----------
if [ "$DRY_RUN" = true ]; then
  echo "▶ dry-run：将执行以下动作（未做任何修改）"
  echo "   sudo apt-get remove --purge -y $PKG"
  for s in "${SVC_FILES[@]}"; do echo "   rm -f $s"; done
  for d in "${LEFTOVER_DIRS[@]}"; do echo "   rm -rf $d"; done
  [ -n "$ORPHAN_BIN" ] && echo "   rm -f $ORPHAN_BIN"
  echo "   sudo systemctl daemon-reload"
  exit 0
fi

# ---------- 确认 ----------
if [ "$ASSUME_YES" = false ]; then
  echo ""
  read -r -p "⚠️  即将彻底卸载 $PKG 并清理上述残留。继续？[y/N] " ANS
  case "$ANS" in
    y|Y|yes|YES) ;;
    *) echo "已取消。"; exit 0 ;;
  esac
fi

# ---------- 执行卸载 ----------
echo ""
echo "➤ [1/4] 卸载软件包 $PKG ..."
if [ "$(id -u)" = "0" ]; then
  RUN_SUDO=()
else
  RUN_SUDO=(sudo)
fi
if apt-get remove --purge -y "$PKG" >/tmp/uninstall-pkg-apt.log 2>&1; then
  echo "   ✅ apt-get remove --purge 完成"
else
  echo "   ⚠️ apt 卸载退出码非 0（可能是局部安装包），改用 dpkg -P 强删 ..."
  "${RUN_SUDO[@]}" dpkg -P "$PKG" || { echo "   ❌ 卸载失败，见 /tmp/uninstall-pkg-apt.log"; tail -20 /tmp/uninstall-pkg-apt.log; exit 1; }
fi

# 验证是否已彻底移除
if dpkg -s "$PKG" >/dev/null 2>&1; then
  echo "   ⚠️ $PKG 仍被 dpkg 记录（rc=仅剩配置），再次 dpkg -P ..."
  "${RUN_SUDO[@]}" dpkg -P "$PKG" 2>/dev/null || true
fi
echo "   ✅ 包已移除"

echo ""
echo "➤ [2/4] 清理残留目录 ..."
for d in "${LEFTOVER_DIRS[@]}"; do
  if [ -e "$d" ]; then
    if "${RUN_SUDO[@]}" rm -rf "$d"; then
      echo "   ✅ 已删除 $d"
    else
      echo "   ⚠️ 删除失败 $d（权限不足？）"
    fi
  fi
done

echo ""
echo "➤ [3/4] 清理 systemd 服务文件 ..."
CHANGED=false
for s in "${SVC_FILES[@]}"; do
  if [ -e "$s" ]; then
    "${RUN_SUDO[@]}" rm -f "$s"
    echo "   ✅ 已删除 $s"
    CHANGED=true
  fi
done
if [ "$CHANGED" = true ]; then
  "${RUN_SUDO[@]}" systemctl daemon-reload 2>/dev/null || true
  echo "   ✅ systemctl daemon-reload 完成"
else
  echo "   （无服务文件需删除）"
fi

echo ""
echo "➤ [4/4] 检查孤儿可执行文件 ..."
if [ -n "$ORPHAN_BIN" ] && [ -e "$ORPHAN_BIN" ]; then
  echo "   ⚠️ 发现手动放置的可执行文件（非 dpkg 管理）: $ORPHAN_BIN"
  if [ "$ASSUME_YES" = true ]; then
    rm -f "$ORPHAN_BIN" && echo "   ✅ 已删除"
  else
    read -r -p "      是否一并删除？[y/N] " ANS2
    case "$ANS2" in
      y|Y|yes|YES) rm -f "$ORPHAN_BIN" && echo "   ✅ 已删除" ;;
      *) echo "   （保留）" ;;
    esac
  fi
else
  # 卸载后重新查一次命令是否还在（可能不在 /usr/bin 等标准路径）
  LEFT="$(command -v "$NAME" 2>/dev/null || true)"
  if [ -n "$LEFT" ]; then
    echo "   ⚠️ 卸载后命令仍存在: $LEFT"
    echo "      该文件可能手动放置，可自行删除: rm -f '$LEFT'"
  else
    echo "   ✅ 命令已不存在，清理干净"
  fi
fi

echo ""
echo "🎉 完成。最终确认："
dpkg -l 2>/dev/null | grep -i "$NAME" | grep -E '^ii' && echo "⚠️ 仍存在未卸载项（见上）" || echo "✅ dpkg 记录中已无 $NAME（${PKG}）"
