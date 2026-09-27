# scripts — 项目脚本总览

本目录集中了本仓库（Debian13_project）日常会用到的全部运维与开发脚本。按用途分成五类：开发环境（dev）、镜像构建（build）、部署上线（deploy，含 staging 与 prod）、Git 版本控制、系统维护工具。

## 开发环境（dev）

这一类负责在开发机上以「源码模式」把服务跑起来，不经过容器，适合日常开发、调试和自测。共三个脚本。

`dev_start_mysql.sh` 管理 czdt 的 MySQL 容器（`mysql-czdtdb`，mysql:8.4 LTS，host 网络，端口 3306，systemd Quadlet 托管）。数据放在卷 `mysql-czdtdb` 里，stop 不丢数据，容器内置生产种子（超管 + 测试号 + 33 分类）。用法：`start` 启动、`status` 查看状态（含 users / categories 计数）、`stop` 停止、`restart` / `logs` / `tail` 对应重启 / 看日志 / 跟日志。可用环境变量 `MYSQL_PORT` 改端口（默认 3306），`CZDT_MYSQL_PWD` 指定密码（默认读 `/etc/czdt/mysql-container.env`）。

`dev_start_headless.sh` 在无图形 / SSH 环境下后台启动 czdt 的前端（vite dev，端口 5174）与后端（uvicorn，端口 8010），各自写日志到 `logs/`。默认前后端一起启，`--no-frontend` 只启后端。端口可被环境变量 `CZDT_BACKEND_PORT` / `CZDT_FRONTEND_PORT` 覆盖（默认 8010 / 5174；本机 8000 被 collab 占用所以避让）。端口被占时它只清理本项目残留进程，绝不误杀其它项目。

`start.sh` 是一个多项目聚合启动器，用一个入口统一管理多个项目的启停。要增删项目只需编辑脚本顶部的 `SERVICES` 数组。默认启用的项目有 carryvideo、collab、artifactdepot、upload-video，每个项目都要自带自己的 `dev_start_headless.sh`。用法：`start` 后台启动全部、`status` / `stop` / `restart` / `logs` / `tail` 对应各状态操作，`start --no-frontend` 会把参数透传给子脚本。

## 镜像构建（build）

通用构建脚本模板在 `shipyard/templates/build_image/`：`build_image.sh` 是通用引擎，`build_image.conf.template` 是项目配置模板。每个项目根目录放一份 `build_image.sh`（与模板一致）和一份 `build_image.conf`（项目差异）。

统一用法：

```bash
./build_image.sh                       # 构建全部默认镜像
./build_image.sh --image <id>          # 只构建指定镜像
./build_image.sh --tag <版本>          # 覆盖 dynamic tag
./build_image.sh --no-cache            # 禁用构建缓存
./build_image.sh --no-save             # 只构建，不导出
./build_image.sh --save <目录>         # 指定导出目录
./build_image.sh --images              # 列出配置里的镜像
```

默认导出目录由 `build_image.conf` 的 `SAVE_DIR` 控制，常见为 `../podman/`。`--save` 固定表示目录，不再是单个 tar 文件。容器工具默认按 `TOOL_PREFERENCE` 探测，也可用 `FORCE=podman|docker` 强制指定。已迁移项目：czdt、collab、ArtifactDepot、carryvideo。

## 部署上线（deploy：staging / prod）

这一类把做好的产物送上门去——要么部署到本机长期运行，要么推到远程服务器。

`deploy_container.sh` 从已有镜像创建 ArtifactDepot 容器（默认 `localhost/artifactdepot:0.6.1`）、运行并配置 systemd 开机自启。数据卷默认挂载 `~/SERVER/artifactdepot/...` 到容器内 `/data/depot`；仓库 token 与 DataHub 地址通过环境变量或卷挂载的 config.json 注入。默认走 host 网络（同机连 DataHub 最稳），`--data-dir` 指定挂载位置，`--token` / `--datahub-url` 注入密钥与地址，`--no-systemd` 只建容器不配自启，`--stop` / `--rm` 分别停止和删除（数据卷保留）。若希望「不登录也后台运行」，部署后执行 `sudo loginctl enable-linger <用户名>`。

`rsync.sh` 把 `ArtifactDepot/podman/` 下的镜像 tar 通过 rsync 推送到远程服务器，支持多目标、带宽限速，每次同步生成带时间戳的日志。目标写在脚本顶部的 `REMOTE_DESTINATIONS` 数组里，格式是 `用户名@主机:SSH端口:远程目录`，以 `#` 开头的行跳过。当前启用的目标是生产主机 `root@120.26.29.177:22:/srv/docker/czdt-production`；仓库里还保留着注释掉的预发主机示例 `root@103.236.99.177:50488:/docker/czdt-staging`，需要时取消注释即可。同步完成后在目标机上先 `podman load` 镜像 tar，再启动 ArtifactDepot 容器（默认 host 网络）。

## Git 版本控制

`gitflow.sh` 把 Git 主干流程自动化：git init（如需要）→ 设置身份 → 生成 .gitignore → 配置远程 → 暂存 → 提交 → 推送，全程零交互。所有配置写在脚本顶部的「配置区」：提交者姓名 / 邮箱、远程仓库 URL、主分支名、暂存范围、提交说明、是否自动推送、密钥保护开关。内置密钥扫描（SECRET_GUARD），暂存内容疑似含 API key / password 时按配置告警或中止。用法：不带参数跑全自动流程，`./gitflow.sh "修复 xxx"` 用命令行参数覆盖提交说明，`--dry-run` 只预览动作不改任何东西，`status` 查看状态加最近提交加远程。

## 系统维护工具

这一类与具体项目无关，属于机器级别的日常维护，共两个脚本。

`proxyctl.sh` 把系统的 `http_proxy` / `https_proxy` / `all_proxy` 指向已跑通的 Clash 系代理，本机或局域网其它机器都行。它写 `/etc/environment`（系统级，新进程生效）和 `/etc/profile.d/proxy.sh`（登录 shell 自动加载）。想让当前 shell 立即生效用 `source ./proxyctl.sh start`；`enable` 永久启动（开机 / 登录自动带代理），`disable` 永久关闭，`status` 查看配置加连通性测试。默认端口对应本机 mihomo 的常用配置（混合口 7893 / socks 7891 / http 7890），host 和端口都可用环境变量覆盖。

`uninstall-pkg.sh` 一键彻底卸载 dpkg / apt 安装的程序：`apt-get remove --purge` 之后清理 `/etc`、`/var/lib`、`/opt`、`/usr/local` 和家目录下的残留配置，删除 systemd 服务文件并 daemon-reload。内置安全保护，拒绝卸载 dpkg / apt / bash / systemd / libc6 等核心系统包。用法：直接给程序名或命令名即可，`--dry-run` 先看会删什么，`--list` 只查包信息，`-y` 跳过确认直接执行。

## 附注

`scripts/gitflow.sh` 与项目根目录的 `gitflow.sh` 内容完全相同（备份副本）。`dev_start_headless.sh`、`dev_start_mysql.sh`、`rsync_czdt.sh` 在 `czdt/czdt_0.1.0/` 里各有一份同源副本（随项目源码一起分发）；通用构建脚本模板集中在 `shipyard/templates/build_image/`，项目内是各自的项目配置。

典型的上线链路是：用 `dev_start_*` 在本地联调 → `build_image.sh` 打成镜像 → `rsync.sh` 送到远程 → 目标机 `podman load` 后启动。开发、构建、部署三段各对应一类脚本，可以按这个链路顺着读下来。`shipyard/` 是**通用发布引擎项目**（船坞）：读取 `shipyard/manifests/<项目>.json` 清单（每项目一份，见 `shipyard/docs/schema.md` 的 schema 说明），按「测试 → 构建 → 上传 → 部署 → 健康检查」执行，`--env staging|prod` 切换环境，任一步失败即中止。用法：`./shipyard/engine/release.sh czdt --env prod --tag 0.12.10`（`--dry-run` 先预览）。引擎只认清单不写死项目，新项目接入 = 新增一份清单 + `shipyard/ops/` 下的部署脚本。
