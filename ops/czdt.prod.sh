#!/usr/bin/env bash
# czdt 生产环境部署脚本 —— 由 shipyard 引擎 ssh 到目标机执行
# 可用环境变量：REMOTE_TAR_DIR（远程 tar 目录）、PROJECT、VERSION
# ⚠️ 下面的「重启应用容器」段是目标机专属的，按实际部署方式填写。

set -euo pipefail

echo "==> 加载镜像 ..."
for t in "${REMOTE_TAR_DIR}"/*.tar; do
  [ -e "$t" ] || continue
  echo "  load: $t"
  podman load -i "$t"
done

echo "==> 重启应用容器 ..."
# ⚠️ 改我：按目标机实际部署方式写重启命令，例如：
#   systemctl --user restart container-czdt-app
#   podman restart czdt-app
podman restart czdt-app 2>/dev/null || true

echo "✅ 部署完成（$PROJECT $VERSION → prod）"
