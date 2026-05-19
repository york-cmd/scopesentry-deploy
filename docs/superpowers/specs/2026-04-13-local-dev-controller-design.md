# Local Dev Controller Design

## Goal

为当前本地开发环境提供一个统一入口 `./devctl`，覆盖安装、启动、停止、状态、日志、扫描镜像重建、清理和卸载，降低本地环境搭建和恢复成本。

## Scope

默认运行形态固定为：

- `db`：Docker
- `server`：本地进程
- `ui`：本地进程
- `scan`：Docker

固定默认地址：

- UI: `http://127.0.0.1:4000`
- API: `http://127.0.0.1:8082`

## Command Set

- `./devctl install`
- `./devctl up`
- `./devctl down`
- `./devctl restart`
- `./devctl status`
- `./devctl logs server|ui|scan|db`
- `./devctl update`
- `./devctl scan rebuild`
- `./devctl clean`
- `./devctl uninstall`
- `./devctl uninstall --purge`

## Command Semantics

### install

- 检查 `docker`、`docker compose`、`go`、`pnpm`、`python3`、`curl`
- 自动生成 `ScopeSentry/.env`
- 初始化 `.local-dev` 目录结构
- 不覆盖已有 `.env` 和密码，除非显式 `--force`
- ScopeSentry 登录密码不在 `install` 阶段生成，而是在服务端首次建库时自行生成并写入运行目录

### up

- 幂等启动 `db/server/ui/scan`
- 已启动组件跳过
- 启动后输出地址、用户名、密码文件路径、节点名和日志入口

### down

- 停止 `server/ui` 本地进程
- 停止扫描容器
- 默认保留数据库数据

### restart

- 等价于 `down + up`

### status

- 展示 `db/server/ui/scan` 当前状态
- 展示端口、pid、容器名、节点名、扫描镜像 tag、密码文件位置

### logs

- `server` 和 `ui` 读取 `.local-dev/logs`
- `scan` 和 `db` 走 docker 日志

### scan rebuild

- 重新编译 Linux 扫描端二进制
- 重建扫描镜像
- 重启扫描容器
- 等待节点回到在线

### update

- 刷新本地前端依赖
- 重启本地 `server/ui`
- 重建并重启扫描容器
- 默认不删除数据库数据

### clean

- 清日志、pid、缓存、临时文件
- 不删除数据库数据
- 不删除 `.env`

### uninstall

- 停止服务
- 删除 `.local-dev` 运行态
- 默认保留数据库数据

### uninstall --purge

- 在 `uninstall` 基础上额外删除数据库容器和数据卷

## Runtime Layout

统一收口到 `.local-dev`：

- `.local-dev/env`
- `.local-dev/logs`
- `.local-dev/pids`
- `.local-dev/cache`
- `.local-dev/runtime`
- `.local-dev/data`
- `.local-dev/state`

密码文件默认放在：

- `.local-dev/runtime/server/PASSWORD`

说明：

- 该文件在服务端首次成功启动并完成初始化后出现
- `devctl status` 负责暴露密码文件路径和存在状态

运行时状态写入：

- `.local-dev/state/manifest.json`

## Implementation Notes

- `devctl` 只做统一入口和运行态编排，底层尽量复用现有 `scripts/*.sh`
- 扫描端代码变更不做源码热同步，统一走镜像重建，保持与生产更接近
- `install` 只负责检查系统依赖，不自动调用系统包管理器安装依赖
- 所有默认值可通过环境变量覆盖，但脚本本身给出稳定默认值
