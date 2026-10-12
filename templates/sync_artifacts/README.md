# sync_artifacts 模板

通用产物同步模板，通过 rsync 把本地目录同步到一个或多个远端目录。

## 文件

- sync_artifacts.sh：通用同步脚本。
- sync_artifacts.conf.template：目标配置模板。

## 使用

cp <shipyard>/templates/sync_artifacts/sync_artifacts.sh .
cp <shipyard>/templates/sync_artifacts/sync_artifacts.conf.template ./sync_artifacts.conf

配置项：

- SOURCE_DIR
- REMOTE_DESTINATIONS：格式 user@host:port:dir，可多个
- BWLIMIT_KBPS
- SSH_KEY_FILE
- DELETE_REMOTE

./sync_artifacts.sh
./sync_artifacts.sh --source ./podman --dest root@example-host:22:/srv/app
./sync_artifacts.sh --dry-run

任意目标失败时脚本返回非 0。
