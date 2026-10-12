#!/usr/bin/env bash
# ============================================================
# shipyard 远程部署脚本模板
#
# 由 release.sh 通过 ssh 送到目标机执行，可读取:
#   REMOTE_TAR_DIR  远程产物目录
#   PROJECT         项目名
#   VERSION         版本号
#
# 使用方式:
#   把本文件复制为项目自己的 ops/deploy.sh，
#   再按目标机实际情况修改“加载镜像后”的重启部分。
# ============================================================

set -euo pipefail

: "${REMOTE_TAR_DIR:?缺少 REMOTE_TAR_DIR}"
: "${PROJECT:?缺少 PROJECT}"
: "${VERSION:?缺少 VERSION}"

RUNTIME="${RUNTIME:-podman}"
RESTART_CMD="${RESTART_CMD:-}"

echo "[INFO] 部署 $PROJECT $VERSION"
echo "[INFO] 产物目录: $REMOTE_TAR_DIR"

if [[ -d "$REMOTE_TAR_DIR" ]]; then
  for tar in "$REMOTE_TAR_DIR"/*.tar; do
    [[ -e "$tar" ]] || continue
    echo "[INFO] 加载镜像: $tar"
    "$RUNTIME" load -i "$tar"
  done
else
  echo "[WARN] 产物目录不存在，跳过镜像加载: $REMOTE_TAR_DIR"
fi

if [[ -n "$RESTART_CMD" ]]; then
  echo "[INFO] 重启命令: $RESTART_CMD"
  bash -c "$RESTART_CMD"
else
  echo "[SKIP] 未设置 RESTART_CMD，跳过重启"
fi

echo "[OK] 部署完成: $PROJECT $VERSION"
