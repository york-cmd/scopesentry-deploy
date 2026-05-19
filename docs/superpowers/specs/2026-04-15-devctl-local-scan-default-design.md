# devctl Local Scan Default Design

## Goal

让 `./devctl up` 默认使用本地二开扫描镜像 `scopesentry-scan-dev:local`，而不是官方 `autumn27/scopesentry-scan:latest`；如果本地镜像不存在，则自动构建一次本地扫描镜像后再启动扫描容器。

## Scope

本次工作只调整本地开发环境中扫描节点的默认镜像选择逻辑：

- 修改 `devctl` 默认 `SCAN_IMAGE`
- 在扫描启动前检查本地镜像是否存在
- 镜像不存在时自动构建本地扫描镜像
- 更新文档和状态输出语义

不做以下事情：

- 不比较源码变更时间
- 不在每次 `up` 时强制 rebuild
- 不移除官方镜像支持
- 不自动判断“本地镜像过期”

## Chosen Behavior

### Default

默认扫描镜像改为：

- `scopesentry-scan-dev:local`

这意味着全新环境下，`status`、`manifest` 和启动输出里的 `Scan image` 默认都应指向本地镜像，而不是官方镜像。

### Lazy Build

在 `run_up` 启动扫描端之前：

- 如果本地扫描镜像已存在：直接启动扫描容器
- 如果本地扫描镜像不存在：先执行一次本地扫描镜像构建，再启动扫描容器

### Explicit Rebuild

如果用户已经修改 `ScopeSentry-Scan` 源码，仍然通过：

- `./devctl scan rebuild`

来刷新到最新源码版本。

## Implementation Notes

- 复用现有 `run_scan_rebuild` 或其内部构建逻辑，避免两套扫描镜像构建路径
- 自动构建只在“本地镜像缺失”时触发，不在镜像存在时触发
- 对显式传入的 `SCAN_IMAGE` 保持尊重；只有默认路径才强制偏向本地镜像

## Output Expectations

典型首次启动输出应体现：

- 扫描镜像默认值是 `scopesentry-scan-dev:local`
- 如果缺镜像，打印类似：
  - `scan image scopesentry-scan-dev:local not found, building local scan image`

## Testing

脚本测试至少覆盖：

- `install/status` 默认写入的 `SCAN_IMAGE` 为本地镜像
- `up` 在镜像缺失时触发本地扫描镜像构建
- `up` 在镜像已存在时不重复构建
- 现有 `scan rebuild` 行为不被破坏
