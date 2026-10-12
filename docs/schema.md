# shipyard 清单 schema

每个项目一份清单，推荐放在项目根目录，命名为 `shipyard.json`，通过 `--manifest` 传给发布引擎。

## 顶层字段

- `schema_version`：清单版本，当前 `"1.0"`。
- `project`：项目名，必填。
- `title`：项目显示名，可选。
- `repo`：Git 仓库地址，可选。
- `repo_root`：项目根目录，可选，默认是清单所在目录。
- `app_dir`：项目代码目录，必填，相对 `repo_root` 或写绝对路径。
- `build`、`test`、`upload`：可选配置块。
- `environments`：环境表，至少一个，必填。

## build

- `enabled`：是否构建。
- `script`：构建脚本名，相对 `app_dir`。
- `args`：固定参数数组。
- `tag_arg`：版本参数名，默认 `--tag`。
- `tag_source`：版本来源。
  - `file`：版本文件，相对 `app_dir`。
  - `pattern`：Python 正则，第一个捕获组为版本号。

版本优先级：命令行 `--tag` > `tag_source` > `0.0.0`。

## test

- `enabled`：是否测试。
- `cmd`：测试命令，在 `app_dir` 下执行。

## upload

- `enabled`：是否上传。
- `source_dir`：上传目录，相对 `repo_root` 或写绝对路径。
- `args`：额外 rsync 参数数组。
- `exclude`：rsync 排除项数组。

## environments.<env>

- `enabled`：是否启用。
- `remote`：可写字符串 `user@host:port:dir`，也可写对象：

```json
{"user": "root", "host": "host.example.com", "port": 22, "dir": "/srv/app"}
```

- `ssh_key`：SSH 密钥的环境变量名，不是密钥内容。
- `health_url`：健康检查地址，留空则跳过。
- `deploy_cmd`：目标机部署脚本，相对 `repo_root`，留空则跳过。

## 配置优先级

命令行参数 > 清单字段 > `engine/config.json` > 内置默认值。

## 安全

清单只保存非敏感信息；密码、token、私钥通过环境变量或仓库外文件注入。
