# deploy_container 模板

通用多容器部署模板，按配置顺序部署多个容器。

## 文件

- deploy_container.sh：通用部署脚本。
- deploy_container.conf.template：服务配置模板。

## 使用

cp <shipyard>/templates/deploy_container/deploy_container.sh .
cp <shipyard>/templates/deploy_container/deploy_container.conf.template ./deploy_container.conf

在配置中为每个服务填写：

- CONTAINER_IMAGE
- CONTAINER_NETWORK
- CONTAINER_PORTS
- CONTAINER_VOLUMES
- CONTAINER_ENV_FILES
- CONTAINER_ENV_VARS
- CONTAINER_RESTART
- CONTAINER_HEALTH_URL

./deploy_container.sh deploy
./deploy_container.sh deploy --only backend
./deploy_container.sh stop
./deploy_container.sh rm
./deploy_container.sh status
./deploy_container.sh logs

默认使用 podman 或 docker；SYSTEMD_ENABLE=true 时尝试生成 systemd 用户服务，仅 podman 且 systemd --user 可用时生效。删除容器不会自动删除数据卷。
