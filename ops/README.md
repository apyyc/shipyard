# ops 目录

本目录存放“在目标机上执行”的部署脚本。

## 使用方式

1. 把 `ops/template.sh` 复制成项目自己的部署脚本，例如 `ops/deploy.sh`。
2. 在项目清单的 `environments.<env>.deploy_cmd` 中填写相对路径，例如 `ops/deploy.sh`。
3. 按目标机实际情况修改脚本中的 `RESTART_CMD`，或直接在模板基础上扩展。

## 注入变量

release.sh 会把下列变量通过 ssh 传到目标机：

- `REMOTE_TAR_DIR`：远程产物目录
- `PROJECT`：项目名
- `VERSION`：版本号

脚本自身还可以读取目标机环境变量，例如 `RUNTIME`、`RESTART_CMD`。

## 约定

- 脚本必须可独立执行，建议先本地执行 `bash -n ops/deploy.sh`。
- 不在脚本中硬编码密码、token、私钥；通过目标机环境变量或密钥文件注入。
- 输出使用 `[INFO]`、`[WARN]`、`[ERROR]`、`[OK]`、`[SKIP]`，不使用 emoji。
