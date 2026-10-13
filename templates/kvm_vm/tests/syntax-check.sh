#!/usr/bin/env bash
# ============================================================
# syntax-check.sh
#
# kvm_vm 模板静态语法检查。
# ============================================================

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

while IFS= read -r -d '' f; do
  if ! bash -n "$f"; then
    echo "[ERROR] bash 语法错误: $f" >&2
    FAIL=1
  fi
done < <(find "$ROOT" -type f \( -name '*.sh' -o -name '*.template' \) -print0 | sort -z)

if [[ "$FAIL" -ne 0 ]]; then
  echo "[ERROR] 语法检查未通过" >&2
  exit 1
fi

echo "[OK] kvm_vm 语法检查通过"
