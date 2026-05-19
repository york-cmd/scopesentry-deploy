# devctl Up Progress Output Design

## Goal

让 `./devctl up` 在等待数据库、HTTP 服务和扫描容器就绪时持续输出可见进度，避免用户面对静默等待，不知道当前阶段、预计等待窗口和最近状态。

## Scope

本次改动只覆盖 `./devctl up` 的进度可见性，不改变已有启动顺序、失败判定、`doctor` 诊断语义或任何组件的实际运行方式。

## Chosen Approach

采用“阶段日志 + 周期性心跳”方案：

- 进入每个阶段时打印一条 `stage ...`
- 在等待循环中按固定间隔打印 `waiting ...`
- 阶段完成时打印 `ready in ...`
- 超时或失败时继续沿用现有失败输出、日志尾部和 `doctor` 提示

不采用单行动态刷新，不新增交互 UI。

## Output Contract

所有输出保持纯文本，并复用现有 `[devctl]` 前缀。

### Stage start

- `stage db: start mongodb/redis`
- `stage server: build and boot backend`
- `stage ui: start pnpm dev`
- `stage scan: start scan container`

### Waiting heartbeat

默认每 5 秒打印一次：

- `waiting db: mongo health=starting, elapsed=15s, timeout=90s`
- `waiting db: tcp 127.0.0.1:6379 not reachable yet, elapsed=5s, timeout=30s`
- `waiting server: http http://127.0.0.1:8082 not ready yet, elapsed=20s, timeout=60s`
- `waiting scan: container scopesentry-scan-dev not running yet, elapsed=10s, timeout=30s`

### Stage completion

- `stage db: ready in 18s`
- `stage server: ready in 9s`

## Configuration

新增环境变量：

- `DEVCTL_PROGRESS_INTERVAL`

默认值为 `5` 秒，用于控制等待期间的心跳输出频率。它只影响可见性，不影响超时上限和业务逻辑。

## Implementation Notes

- `wait_for_mongo_ready`、`wait_for_tcp_port`、`wait_for_http`、`wait_for_scan_container` 都要有进度输出
- 输出逻辑尽量复用共享辅助函数，避免四套等待循环各自维护节流逻辑
- 不打印完整日志，不打印复杂动画
- 只在等待期间输出状态；失败时再打印日志尾部

## Testing

脚本测试需要覆盖：

- `up` 开始时会打印阶段开始信息
- 在缩短进度间隔后，会出现至少一条 `waiting db` 心跳
- 阶段成功后会打印 `ready in`
- 现有失败输出不被回归破坏

## Non-Goals

- 不改 `status` 输出
- 不改 `doctor` 输出
- 不增加 `--verbose`
- 不实现 spinner 或单行刷新动画
