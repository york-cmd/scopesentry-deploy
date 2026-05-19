# OneForAll Hot Plugin Design

## Goal

为 `ScopeSentry-Scan` 增加一个 `SubdomainScan` 热插件，用 OneForAll 做轻量被动子域名候选收集。第一版只负责调用预装的 OneForAll、解析结果、转发到现有 ScopeSentry 子域名结果链路，不改扫描端主程序。

## Decisions

- 插件形态：热插件，不内置到 `modules/subdomainscan`。
- 运行环境：镜像预装 OneForAll 和 Python venv。
- 收集模式：被动候选模式。
- OneForAll 参数：`--brute False --dns False --req False --takeover False`。
- 输出格式：JSON。
- DNS 解析：不使用 OneForAll 解析，热插件拿到候选子域后交给 ScopeSentry 自己的 DNS 工具解析。
- 结果来源：热插件桥接层自动设置 `SourcePlugin` 和 `SourcePluginHash`，插件也可显式返回 `types.SubdomainResult`。

## Runtime Layout

OneForAll 固定安装到扫描镜像内：

- `/apps/ext/oneforall/OneForAll`
- `/apps/ext/oneforall/venv`
- `/apps/ext/oneforall/venv/bin/python`
- `/apps/ext/oneforall/OneForAll/results`

热插件运行时为每个目标创建独立临时输出目录，例如：

- `/apps/ext/oneforall/OneForAll/results/scopesentry-<taskId>-<random>`

任务结束后清理本次输出目录，避免结果文件累计占用磁盘。

## Image Dependencies

`dockerfile.base` 负责预装运行环境：

- Python 3.8 或更高版本
- `python3-venv`
- `python3-pip`
- `git`
- `build-essential`
- `libffi-dev`
- `libxml2-dev`
- `libxslt-dev`
- `libssl-dev`

OneForAll Python 依赖按官方 `requirements.txt` 安装到独立 venv，包括：

- `beautifulsoup4`
- `bs4`
- `certifi`
- `chardet`
- `colorama`
- `dnspython`
- `exrex`
- `fire`
- `future`
- `idna`
- `loguru`
- `PySocks`
- `requests`
- `six`
- `soupsieve`
- `SQLAlchemy`
- `tenacity`
- `termcolor`
- `tqdm`
- `treelib`
- `urllib3`
- `setuptools`

第一版不要求安装或配置 `massdns` 给 OneForAll，因为禁用 `--brute`。

## Hot Plugin Behavior

### Install

`Install()` 只做环境检查，不做联网安装：

- 检查 OneForAll 目录存在
- 检查 venv Python 可执行
- 检查 `oneforall.py` 存在
- 可选执行 `python oneforall.py version`

缺依赖时返回明确错误，让插件日志提示需要重建扫描 base 镜像。

### Execute

输入必须是单个根域名字符串。

执行流程：

1. 读取输入根域名。
2. 创建本次任务输出目录。
3. 执行 OneForAll：
   - `python oneforall.py --target <domain> --brute False --dns False --req False --takeover False --fmt json --path <output-dir> run`
4. 读取输出目录中的 JSON 结果文件。
5. 提取每条结果中的 `subdomain` 字段。
6. 过滤空值、非当前根域后缀、重复项。
7. 对每个候选子域调用 ScopeSentry DNS 查询。
8. 转为 `types.SubdomainResult` 并调用 `op.ResultFunc`。
9. 记录总候选数、有效输出数、失败原因。

### Parameters

第一版只保留少量参数，避免热插件复杂化：

- `timeout`：执行超时，默认 20 分钟。
- `path`：可选 OneForAll 安装目录，默认 `/apps/ext/oneforall/OneForAll`。
- `python`：可选 Python 路径，默认 `/apps/ext/oneforall/venv/bin/python`。

不开放 `brute`、`dns`、`req`、`takeover`，避免任务配置把插件从被动模式改成重型主动模式。

## Error Handling

- 环境缺失：`Install()` 和 `Execute()` 都输出清晰插件日志。
- 命令超时：终止 OneForAll 子进程，返回错误但不影响整个扫描节点运行。
- 输出为空：记录 warning，正常结束。
- JSON 解析失败：记录文件路径和错误，返回插件错误。
- 单条结果解析失败：跳过该条，继续处理后续结果。

## Security And Stability

- 不从热插件中执行联网安装，避免扫描任务期间环境漂移。
- OneForAll 源码版本在镜像构建时固定，避免 `master` 变化导致不可复现。
- 默认关闭 OneForAll 网络检查和版本检查，避免每次扫描做额外联网探测。
- 所有外部命令使用参数数组调用，不拼接 shell 字符串。
- 输出目录按任务隔离并清理，避免多任务互相读写结果。

## Testing Plan

- 热插件环境检查：缺 OneForAll、缺 venv Python、缺 `oneforall.py` 都能给出明确错误。
- 命令构造测试：确认固定包含被动模式参数。
- JSON 解析测试：模拟 OneForAll JSON 输出，确认能提取 `subdomain`。
- 结果转发测试：确认输出 `types.SubdomainResult` 并保留来源信息。
- 镜像检查：构建后能执行 `python oneforall.py version`。
- Smoke 测试：对安全测试域名运行一次 SubdomainScan，确认结果进入现有子域名链路。

## Non-Goals

- 不做内置插件。
- 不启用 OneForAll 爆破。
- 不启用 OneForAll DNS 解析。
- 不启用 OneForAll HTTP 探测。
- 不启用接管检测。
- 不在热插件运行时安装 Python 包或 clone 仓库。
