# shipyard 清单 schema 说明

每个项目一份清单（`manifests/<项目名>.json`），声明这个项目怎么发布。引擎 `engine/release.sh` 只认清单、不写死项目；`engine/lib/manifest.py` 负责解析与严格校验。

## 顶层字段

- **`schema_version`**（推荐）：清单自身的版本号，当前 `"1.0"`，schema 演进时用于区分新旧格式。
- **`project`**（必填）：项目名，作为日志标识和 CLI 参数，建议与清单文件名一致。
- **`title`**：项目中文展示名（日志 / 未来 web 界面显示用）。
- **`repo`**：GitHub 仓库地址，为将来 GitHub Actions 接入预留。
- **`app_dir`**（必填）：项目根目录，相对仓库根。测试和构建命令都在此目录下执行。
- **`build`**（对象）：构建闸门。`enabled` 控制是否参与；`script` 是构建脚本名（相对 `app_dir`）；`args` 是固定参数；`tag_arg` 是版本参数名（如 `--tag`）；`tag_source` 描述版本号从哪自动读——`file` 文件名、`pattern` 提取版本的 grep 正则（第一个捕获组为版本）。版本号优先级：命令行 `--tag` > `tag_source` 自动读 > `0.0.0` 兜底。使用通用 `build_image.sh` 时，推荐把 `tag_source.file` 指向 `build_image.conf`，pattern 使用 `^DEFAULT_TAG="?([^"]+)`。
- **`test`**（对象）：测试闸门。`enabled` 控制是否参与；`cmd` 是在 `app_dir` 下执行的测试命令。
- **`upload`**（对象）：上传闸门。`enabled` 控制是否参与；`source_dir` 是构建产物（tar）所在目录，相对仓库根。引擎会 rsync 整个目录到目标环境，并在目标机 load 其中所有 `.tar`。
- **`environments`**（对象）：目标环境表，至少一个，key 即 `--env` 参数值。

## 环境字段（environments.<env>）

- **`enabled`**：该环境是否启用（staging 没机器时可置 false，不动其它配置）。
- **`remote`**：`用户@主机:SSH端口:远程目录` 三段式，对应 rsync 的 `-e "ssh -p <端口>"`。
- **`ssh_key`**：SSH 密钥。只存环境变量名，值从环境变量注入（引擎读取同名环境变量的值作为密钥文件路径）；留空则用默认 ssh 免密。**值本身绝不写进清单。**
- **`health_url`**：部署完成后健康检查地址；留空则跳过健康检查。
- **`deploy_cmd`**：部署脚本路径，相对仓库根（通常 `ops/<项目>.<环境>.sh`），引擎把它送到目标机执行。

## 部署脚本（ops/）

每个环境一个 bash 脚本。引擎通过 ssh 在目标机上执行，注入环境变量 `REMOTE_TAR_DIR`（远程 tar 目录）、`PROJECT`、`VERSION`。脚本负责 `podman load` 目录下所有新 tar，并按目标机实际方式重启应用容器（重启命令是每台机器专属的，文件里留了「改我」标记）。脚本要能独立运行、可 `bash -n` 检查。

## 引擎执行顺序

`test → build → upload → deploy → health`，每步 `enabled=false` 即跳过，任一步失败立即中止。`--env` 决定用哪个环境的 `remote` / `deploy_cmd` / `health_url`。
