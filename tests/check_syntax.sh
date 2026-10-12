#!/usr/bin/env bash
# ============================================================
# check_syntax.sh
#
# 基础自检:
#   - bash 脚本与 bash 配置模板语法
#   - Python 语法
#   - JSON 合法性
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "[INFO] 检查根目录: $ROOT"

while IFS= read -r -d '' f; do
  if ! bash -n "$f"; then
    echo "[ERROR] bash 语法错误: $f"
    FAIL=1
  fi
done < <(find "$ROOT" -type f \( -name '*.sh' -o -name '*.template' \) -not -path '*/.git/*' -print0)

while IFS= read -r -d '' f; do
  if ! python3 -m py_compile "$f"; then
    echo "[ERROR] Python 语法错误: $f"
    FAIL=1
  fi
done < <(find "$ROOT" -type f -name '*.py' -not -path '*/.git/*' -print0)

while IFS= read -r -d '' f; do
  if ! python3 -m json.tool "$f" >/dev/null 2>&1; then
    echo "[ERROR] JSON 格式错误: $f"
    FAIL=1
  fi
done < <(find "$ROOT" -type f -name '*.json' -not -path '*/.git/*' -print0)

if [[ "$FAIL" -ne 0 ]]; then
  echo "[ERROR] 自检未通过"
  exit 1
fi

echo "[OK] 自检通过"
