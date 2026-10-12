# dev_start 模板

通用开发环境启动模板，合并 MySQL 容器管理与后端/前端进程管理。

## 文件

- dev_start.sh：通用启动脚本。
- dev_start.conf.template：项目配置模板。

## 使用

cp <shipyard>/templates/dev_start/dev_start.sh .
cp <shipyard>/templates/dev_start/dev_start.conf.template ./dev_start.conf

按需启用 MYSQL_ENABLED、BACKEND_ENABLED、FRONTEND_ENABLED。

./dev_start.sh start
./dev_start.sh stop
./dev_start.sh restart
./dev_start.sh status
./dev_start.sh logs
./dev_start.sh tail

## 配置要点

- MYSQL_*：容器运行时、镜像、端口、数据目录、密码来源、就绪命令。
- BACKEND_*：运行目录、启动命令数组、端口、热重载参数、日志、健康地址。
- FRONTEND_*：与后端类似。
- 密码通过 MYSQL_PASSWORD_ENV 指定的环境变量或 MYSQL_PASSWORD_FILE 指向的文件注入。
