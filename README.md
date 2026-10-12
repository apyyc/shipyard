# shipyard

shipyard 是一个通用发布引擎和脚本模板库，不绑定具体项目。

## 目录结构

```text
shipyard/
├── engine/                # 发布引擎
├── manifests/template.json
├── ops/                   # 目标机部署脚本模板
├── templates/             # 可复制脚本模板
├── docs/                  # schema、架构、模板说明
└── tests/check_syntax.sh  # 基础自检
```

## 快速开始

项目清单推荐放在项目自己的仓库根目录，例如 `shipyard.json`。

```bash
./engine/release.sh <project> \
  --manifest /path/to/project/shipyard.json \
  --env prod \
  --dry-run
```

去掉 `--dry-run` 即可执行发布。

## 模板

- `templates/build_image/`：镜像构建
- `templates/dev_start/`：开发环境启动
- `templates/deploy_container/`：多容器部署
- `templates/sync_artifacts/`：产物同步

每个模板目录都有 README，详细索引见 `docs/templates.md`。

## 配置分层

- `engine/config.json`：引擎级默认值。
- 项目清单 `shipyard.json`：项目路径、构建、测试、上传、环境、远程地址。
- 模板 `.conf`：各脚本自己的项目配置。
- 敏感信息：只通过环境变量或仓库外文件注入。

## 安全约定

- 清单和模板中不写真实密码、token、私钥。
- `ssh_key` 字段填写环境变量名，实际密钥路径从环境变量读取。
- 脚本输出使用 `[INFO]`、`[WARN]`、`[ERROR]`、`[OK]`、`[SKIP]`。
