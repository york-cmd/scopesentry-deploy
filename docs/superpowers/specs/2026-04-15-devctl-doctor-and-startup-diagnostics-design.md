# devctl Doctor And Startup Diagnostics Design

## Goal

为 `./devctl` 增加一个只读诊断入口 `doctor`，并增强 `up` 的失败输出，让本地开发者在启动失败时能直接看到失败阶段、相关日志和下一步建议，而不是只拿到一个非零退出码。

## Scope

本次工作只覆盖本地开发控制器体验改进，不改变现有默认运行形态：

- `db`：Docker
- `server`：本地进程
- `ui`：本地进程
- `scan`：Docker

不引入自动修复，不改为交互式菜单，不重构为全 Docker 模式。

## New Command

新增命令：

- `./devctl doctor`

命令语义：

- 只读诊断
- 不创建、不删除、不启动、不停止任何组件
- 输出 `PASS/WARN/FAIL` 级别的检查结果
- 对 `FAIL` 和关键 `WARN` 给出明确修复建议

## Doctor Checks

`doctor` 至少覆盖以下检查项：

### Project

- 仓库布局是否完整
- `ScopeSentry/.env` 是否存在
- `.local-dev` 关键运行目录是否存在

### Tooling

- `docker`
- `docker compose`
- `go`
- `pnpm`
- `python3`
- `curl`

### Docker Runtime

- Docker daemon 是否可访问
- Compose 命令是否可执行

### Ports

- API 端口是否被非预期进程占用
- UI 端口是否被非预期进程占用
- Redis 端口是否被非预期进程占用

### Runtime State

- `db/server/ui/scan` 当前状态
- `PASSWORD` 文件是否存在
- 是否存在 stale pid 文件

## Output Contract

### doctor

输出保持纯文本，便于本地直接读，也便于脚本 grep：

- `PASS <check>: <summary>`
- `WARN <check>: <summary>`
- `FAIL <check>: <summary>`

当存在问题时，在结果后紧跟建议，例如：

- `hint: start Docker Desktop and rerun ./devctl doctor`
- `hint: free port 4000 or override UI_URL`

### up failure

`./devctl up` 在以下阶段失败时必须打印阶段名：

- `db`
- `server`
- `ui`
- `scan`

每次失败至少输出：

- 失败阶段
- 简明原因
- 对应日志尾部
- 建议下一步

示例结构：

- `startup failed at stage: db`
- `reason: docker compose could not start mongodb/redis`
- `last logs from db (...)`
- `hint: run ./devctl doctor`

## Shared Helpers

为避免 `doctor` 和 `up` 分别维护两套判断逻辑，本次会新增共享诊断辅助函数，集中处理：

- 命令存在性检查
- Docker daemon 可达性检查
- Compose 可用性检查
- 端口占用检查
- 日志尾部输出
- 标准化提示文本

## Error Handling

- `doctor` 自己不因单项失败而立刻退出，应尽量收集完整结果后统一返回
- `doctor` 在存在 `FAIL` 项时返回非零
- `up` 仍保持 fail-fast，但失败信息需要结构化
- 对日志文件不存在的情况要优雅降级，不能二次报错覆盖原始问题

## Testing

本次改动优先通过脚本测试覆盖：

- `doctor` 在健康环境下输出 `PASS`
- `doctor` 在 Docker daemon 不可用时输出 `FAIL` 和修复提示
- `up` 在数据库启动失败时输出阶段名、日志片段和建议
- `up` 在后端或前端未就绪时仍保留现有等待逻辑，并补充更明确的失败说明

## Non-Goals

- 不自动安装依赖
- 不自动修复 `.env`、pid、端口冲突
- 不新增交互式菜单
- 不改变 `status/install/down/restart` 的命令语义
