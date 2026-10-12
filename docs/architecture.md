# shipyard 架构

shipyard 由四层组成，依赖方向由外向内。

## 分层

1. 接口层：engine/release.sh，负责参数、路径、日志与步骤编排。
2. 应用层：test、build、upload、deploy、health 五个步骤。
3. 领域层：engine/lib/manifest.py，负责清单解析、校验、默认值合并。
4. 基础设施层：ops/ 与 templates/，分别放目标机脚本与可复制模板。

## 发布流程

release.sh
  -> manifest.py 解析清单
  -> test
  -> build
  -> upload
  -> deploy
  -> health

任一步失败立即中止；enabled=false 或 --no-* 可跳过对应步骤。

## 路径模型

- 清单可由 --manifest 指向项目自己的 shipyard.json。
- repo_root 默认是清单所在目录，可用 --repo-root 覆盖。
- app_dir、upload.source_dir、deploy_cmd 相对 repo_root 解析。

## 配置模型

- engine/config.json：引擎默认值。
- 项目清单：项目级非敏感配置。
- 模板 .conf：各脚本自己的项目配置。
- 环境变量或仓库外文件：敏感信息。
