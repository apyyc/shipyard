# build_image 模板

本目录提供一套通用的镜像构建脚本模板。它不包含任何具体项目名、IP、账号或业务配置。

## 文件说明

- `build_image.sh`
  通用构建引擎，负责读取同目录下的 `build_image.conf`，按配置构建、校验、导出镜像。
- `build_image.conf.template`
  项目配置模板。复制到项目根目录后改名为 `build_image.conf`，再按项目需要修改。

## 使用方式

在项目根目录执行：

```bash
cp <shipyard>/templates/build_image/build_image.sh .
cp <shipyard>/templates/build_image/build_image.conf.template ./build_image.conf
```

然后编辑 `build_image.conf`，至少修改：

- `PROJECT_ID`
- `PROJECT_TITLE`
- `IMAGE_IDS`
- 每个镜像对应的 `IMAGE_DOCKERFILE`、`IMAGE_CONTEXT`、`IMAGE_NAME`
- 如需要，修改 `SAVE_DIR`

常用命令：

```bash
./build_image.sh                         # 构建默认启用的镜像
./build_image.sh --image <id>            # 只构建指定镜像
./build_image.sh --tag <版本>            # 覆盖 dynamic tag
./build_image.sh --no-cache              # 禁用构建缓存
./build_image.sh --no-save               # 只构建，不导出 tar
./build_image.sh --save <目录>           # 指定导出目录
./build_image.sh --images                # 列出配置里的镜像
./build_image.sh --help
```

## 配置分层

- `build_image.sh`：通用流程，通常不需要改。
- `build_image.conf`：项目差异，例如镜像名、Dockerfile、上下文、导出目录。
- 环境变量：仅用于命令行临时覆盖，例如 `FORCE=podman`、`--tag`。

不含密钥。构建代理、私有仓库凭据等敏感信息应通过宿主环境变量或密钥管理工具注入。

## 与 shipyard 发布引擎的关系

使用 shipyard 发布项目时，推荐的清单配置为：

```json
"build": {
  "enabled": true,
  "script": "build_image.sh",
  "tag_arg": "--tag",
  "tag_source": {
    "file": "build_image.conf",
    "pattern": "^DEFAULT_TAG=\"?([^\"]+)"
  }
}
```

这样发布引擎会从 `build_image.conf` 的 `DEFAULT_TAG` 读取版本号，再用 `--tag` 覆盖构建版本的默认值。
