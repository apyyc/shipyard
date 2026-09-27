# shipyard — 通用发布引擎

shipyard（船坞）是一个配置驱动的通用发布工具：读取每个项目的发布清单，按「测试 → 构建 → 上传 → 部署 → 健康检查」一条流程把项目发布到指定环境。它不写死任何项目——新项目接入只需在 `manifests/` 加一份 JSON、在 `ops/` 加对应环境的部署脚本，引擎本身不需要改动。

## 快速上手

```bash
./engine/release.sh czdt --env staging --dry-run   # 先预览
./engine/release.sh czdt --env staging --tag 0.12.10   # 实际发布到预发
./engine/release.sh czdt --env prod --tag 0.12.10      # 发布到生产
```

`--env` 必填（staging / prod 二选一，强制指定防误发）；`--tag` 不填则自动从清单 `tag_source` 读取版本号。发布日志写入 `logs/`。

## 目录结构

```
shipyard/
├── engine/               # 应用层：编排引擎 + 全局配置
│   ├── release.sh        # CLI 入口（读清单 → 按步执行）
│   ├── config.json       # 引擎级全局配置（ssh 超时 / 带宽 / 健康检查等）
│   └── lib/manifest.py   # 领域层：清单解析与严格校验（纯逻辑）
├── manifests/            # 配置层：每项目一份清单
│   ├── template.json     # 新项目模板
│   └── czdt.json         # 实例
├── ops/                  # 基础设施层：各项目各环境部署脚本
│   ├── czdt.prod.sh
│   └── czdt.staging.sh
├── docs/schema.md        # 清单 schema 说明
└── logs/                 # 引擎日志（gitignore）
```

## 架构分层

- **领域层**（`engine/lib/manifest.py`）：清单 schema 的定义与校验，纯解析、不执行任何操作，可单独测试。
- **应用层**（`engine/release.sh`）：编排逻辑——拿到合法清单后按顺序跑哪几步、失败如何中止。它调用领域层取配置，再调用基础设施层做真实操作。
- **基础设施层**（`ops/`）：对目标机的真实操作（ssh / rsync / podman / curl），每个环境一个脚本。
- **接口层**：CLI 入口（`engine/release.sh`）以及将来的 GitHub Actions workflow。

依赖方向由外向内：接口 → 应用 → 领域；基础设施被应用调用，不反向依赖。

## 配置纪律

清单 `manifests/*.json` 只放非敏感配置（目录、脚本、远程地址、版本规则），提交进 git。敏感配置——SSH 密钥、数据库密码等——一律不落清单：`ssh_key` 字段只存环境变量名，值从环境变量或 Secret 注入。引擎全局参数在 `engine/config.json`，优先级为"清单字段 > 引擎配置 > 内置默认值"。
