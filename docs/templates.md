# 模板索引

所有模板都采用“脚本 + 配置模板 + README”的结构，复制到项目根目录后使用。

## build_image

- 脚本：build_image.sh
- 配置：build_image.conf
- 用途：构建镜像并导出 tar。

## dev_start

- 脚本：dev_start.sh
- 配置：dev_start.conf
- 用途：启动 MySQL 容器、后端进程、前端进程。

## deploy_container

- 脚本：deploy_container.sh
- 配置：deploy_container.conf
- 用途：按顺序部署多个容器。

## sync_artifacts

- 脚本：sync_artifacts.sh
- 配置：sync_artifacts.conf
- 用途：同步产物到远程目录。

## 通用约定

- 支持 --help。
- 涉及远程或容器操作的脚本支持 --dry-run。
- 不写密码、token、私钥。
- 输出使用 [INFO]、[WARN]、[ERROR]、[OK]、[SKIP]。
