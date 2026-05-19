# Deploy Lifecycle Commands Design

把现有三脚本（`install-server.sh` / `update-server.sh` / `update-node.sh`）改造成统一交互式管理菜单，并在 dev 机加 `./devctl publish-all` 一键发布。

## Goal

让远端服务端和节点的运维**一条 curl 走完所有生命周期**（安装、升级、重启、状态、卸载），dev 机改完代码也能**一条命令推完所有变更**。

具体三个变化：

1. **服务端**：`scripts/install-server.sh` 升级成既能首次安装也能跑交互菜单。已装情况下跑同一条 curl，弹菜单。脚本自更新（每次升级把自己也覆盖到最新版本）。
2. **节点端**：新增 `scripts/manage-node.sh`，节点装完之后的所有生命周期管理（升级 / 卸载 / 重启 / 状态）走这个；**初装仍走服务端 API 发的带 token curl 命令不变**。
3. **dev 机**：新增 `./devctl publish-all`，串行推 scan-base（按 fingerprint 智能跳过）/ server / scan + git push 脚本改动。一组 publish 用同一个时间戳 tag。

## Scope

本设计覆盖：

- `scripts/install-server.sh` 改造成首装 + 菜单模式
- `scripts/update-server.sh` 改成 thin wrapper（向后兼容已发布的 raw URL）
- 新增 `scripts/manage-node.sh`
- `scripts/update-node.sh` 改成 thin wrapper
- 新增 `devctl publish-all` 子命令 + `.local-dev/state/scan-base-fingerprint` 状态文件
- README.md / DEPLOY_SERVER.md / DEPLOY_NODE.md 文档同步更新

不做：

- **不改 ScopeSentry-Scan 节点 enrollment 业务逻辑**（服务端 API 发 install-node.sh 的那条线仍然由服务端代码生成，本设计只关心装完之后的管理）
- **不做服务端→节点集中升级**（A 方案：节点容器要挂 docker.sock 自我重启 / 改心跳协议，超出 deploy 脚本职责，且回滚链路复杂）
- **不做服务端 ssh 批量推送到节点**（C 方案：可作为后续 `devctl nodes update --all` 增强，本期不做）
- **不重命名 `install-server.sh`**：保持旧名字，避免破坏已发布的 raw URL
- **不做菜单脚本的本地 systemd 集成**（不装 `/usr/local/bin/scopesentry`，每次 curl 走最新版本，避免本地副本陈旧）
- **不为 publish-all 引入测试运行 / 镜像签名 / SBOM**（YAGNI，发现需要再加）

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       dev 机 (info-scan/)                       │
│                                                                 │
│  ./devctl publish-all                                           │
│    1. fingerprint check (dockerfile.base sha256)                │
│       └─> publish-base 仅当变化                                  │
│    2. server publish                                            │
│    3. scan publish (FROM 刚 publish 的 base)                    │
│    4. git push (如果工作区有未提交改动)                          │
│                                                                 │
│  状态：.local-dev/state/scan-base-fingerprint                    │
└─────────────────────────────────────────────────────────────────┘
            │                  │                  │
            │ push 镜像          │ push 脚本         │
            ▼                  ▼                  │
       ┌─────────┐       ┌────────────┐           │
       │  ghcr   │       │  GitHub    │           │
       │ .io/... │       │ york-cmd/  │           │
       │         │       │ scopesentry│           │
       │ 3 images│       │ -deploy    │           │
       └────┬────┘       └─────┬──────┘           │
            │                  │                  │
            │ docker pull      │ raw curl         │
            ▼                  ▼                  ▼
┌─────────────────────────┐  ┌─────────────────────────┐
│  服务端 VPS              │  │  节点机 (N 台)            │
│                         │  │                         │
│  bash <(curl install-   │  │  bash <(curl manage-    │
│  server.sh)             │  │  node.sh)               │
│  ├── 未装 → 装           │  │  ├── 未装 → 提示去服务端  │
│  └── 已装 → 菜单         │  │  │       UI 拿 token   │
│        [1] 升级          │  │  └── 已装 → 菜单         │
│        [2] 卸载          │  │        [1] 升级         │
│        [3] 重启          │  │        [2] 卸载         │
│        [4] 状态          │  │        [3] 重启         │
│        [0] 退出          │  │        [4] 状态         │
│                         │  │        [0] 退出         │
│  状态：/opt/scopesentry  │  │  状态：/etc/scopesentry-│
│       /.env             │  │       node/node.env     │
└─────────────────────────┘  └─────────────────────────┘
```

## Components

### 1. `scripts/install-server.sh`（重构后）

入口判定：
```bash
if [[ -f /opt/scopesentry/.env ]]; then
  show_menu
else
  run_install   # 现有逻辑
fi
```

`show_menu`：

```
ScopeSentry 服务端已安装在 /opt/scopesentry/
版本：v2026.05.19-123043   状态：running
[1] 升级 (拉最新镜像 + 重启)
[2] 卸载
[3] 重启
[4] 查看状态
[0] 退出
请选择: _
```

子命令的实现：

| 选项 | 行为 |
|------|------|
| `[1] 升级` | (a) `curl -fsSL <raw>/install-server.sh -o /opt/scopesentry/install-server.sh` 把自己更新到最新（脚本自更新）;<br>(b) `docker compose pull` + `up -d --force-recreate` |
| `[2] 卸载` | 弹二级菜单：[1] 保留数据 [2] 彻底卸载 [0] 返回。二次 yes/no 确认。详见 "Uninstall 子流程" |
| `[3] 重启` | `docker compose restart` |
| `[4] 查看状态` | `docker compose ps` + `curl -fsS localhost:8082/api/health` + 凭据文件位置提示 |
| `[0] 退出` | 直接退 |

**自更新机制**：每次进入"升级"分支，先把自己 curl 到 `/opt/scopesentry/install-server.sh`（即使裸 curl 跑的也无所谓——下次 ssh 上去可直接跑 `bash /opt/scopesentry/install-server.sh` 是最新版本）。

**Command-line flag mode**：支持非交互参数跳过菜单，便于脚本化调用 + 老 raw URL wrapper：

| 参数 | 行为 |
|------|------|
| `--upgrade` | 跳菜单直接执行升级分支 |
| `--uninstall` | 跳菜单进入卸载流程（**仍保留二次确认**，flag 不绕过 destructive 操作的确认） |
| `--restart` | 跳菜单执行 docker compose restart |
| `--status` | 跳菜单打印状态后退出 |
| 无参数 | 按 .env 是否存在决定走 install 还是弹菜单 |

### 2. Uninstall 子流程

```
卸载 ScopeSentry 服务端
  [1] 保留数据：停容器、删容器、删镜像；保留 /opt/scopesentry/
  [2] 彻底卸载：连 /opt/scopesentry/ 一起删（不可恢复）
  [0] 返回上级
请选择: _
```

选 `[1]` 后：
```
将执行：
  - docker compose down
  - docker rmi <SERVER_IMAGE>
  - 保留 /opt/scopesentry/{.env, docker-compose.yml, PASSWORD, PLUGINKEY, data/}
继续？(yes/no): _
```

选 `[2]` 后（**标红**）：
```
⚠️  将执行（不可恢复）：
  - docker compose down -v
  - docker rmi <SERVER_IMAGE> mongo:7.0.28 redis:7.0.11
  - sudo rm -rf /opt/scopesentry
所有数据库数据、上传文件、admin 密码都会丢失。
继续？请输入 "DELETE EVERYTHING" 确认: _
```

第二级用"打字确认"（输入指定字符串而不是 yes/no）防止误删。

### 3. `scripts/manage-node.sh`（新增）

入口判定：
```bash
if [[ -f /etc/scopesentry-node/node.env ]]; then
  show_menu
else
  echo "这台机器还没装过节点。请到服务端 UI → 节点管理 → 添加节点，"
  echo "复制 curl 命令在这台机器上跑（带一次性 token 的那条）。"
  exit 1
fi
```

`show_menu`：

```
ScopeSentry 扫描节点已安装在 /etc/scopesentry-node/
节点名：node-hk-01   状态：running   上次心跳：2s ago
[1] 升级 (拉最新 scan 镜像 + 重启)
[2] 卸载
[3] 重启
[4] 查看状态
[0] 退出
请选择: _
```

uninstall 颗粒度：

| 选项 | 删除范围 |
|------|---------|
| `[1] 保留配置` | docker container + scan image。**保留** `/etc/scopesentry-node/` 和 `/opt/scopesentry-scan/{logs,cache}` |
| `[2] 彻底卸载` | 上面所有 + `/etc/scopesentry-node/` + `/opt/scopesentry-scan/` 整个目录 + docker network |

**自更新机制**：升级分支先把自己 curl 到 `/etc/scopesentry-node/manage-node.sh`，再 `docker compose pull` + `up -d --force-recreate`。下次本地跑 `bash /etc/scopesentry-node/manage-node.sh` 是最新版本。

**Command-line flag mode**：同 install-server.sh，支持 `--upgrade` / `--uninstall` / `--restart` / `--status`（同语义，区别只在管的是节点容器而不是服务端）。

### 4. `./devctl publish-all`

入口（新增 devctl 子命令）：

```bash
./devctl publish-all [--tag vX.Y] [--skip-base] [--force-base] [--skip-git]
```

伪代码：

```bash
run_publish_all() {
  local tag="${custom_tag:-v$(date +%Y.%m.%d-%H%M%S)}"

  # 1. scan-base 智能跳过
  if [[ $skip_base != 1 ]]; then
    local current_fp expected_fp
    current_fp=$(sha256sum ScopeSentry-Scan/dockerfile.base | awk '{print $1}')
    expected_fp=$(cat .local-dev/state/scan-base-fingerprint 2>/dev/null || echo "")
    if [[ $force_base == 1 || "$current_fp" != "$expected_fp" ]]; then
      log "步骤 1/4：scan-base 指纹变化，重新 publish-base"
      run_scan_publish_base --tag "$tag"
      # 只在 publish-base 成功（run_scan_publish_base 不 fail）之后更新指纹
      echo "$current_fp" > .local-dev/state/scan-base-fingerprint
    else
      log "步骤 1/4：scan-base 未变化，跳过"
    fi
  fi

  # 2. server publish
  log "步骤 2/4：publish server"
  run_server_publish --tag "$tag"

  # 3. scan publish
  log "步骤 3/4：publish scan"
  run_scan_publish --tag "$tag"

  # 4. git push（如果工作区有未提交改动且未指定 --skip-git）
  if [[ $skip_git != 1 ]] && [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    log "步骤 4/4：git commit + push 脚本改动"
    git add -A
    git commit -m "publish-all $tag"
    git push origin main
  fi

  log "publish-all 完成（tag=$tag）"
}
```

### 5. 向后兼容 wrapper

老 raw URL 的 `update-server.sh` 和 `update-node.sh` 仍存在，只是变成 thin wrapper：

```bash
# scripts/update-server.sh
#!/usr/bin/env bash
exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/york-cmd/scopesentry-deploy/main/scripts/install-server.sh)" -- --upgrade
```

`install-server.sh` 支持 `--upgrade` 参数：跳过菜单直接执行升级分支。同理 `--uninstall` / `--status` / `--restart`，便于脚本化调用。

## Data Flow / State

| 文件 | 存放在 | 内容 | 谁写 | 谁读 |
|------|--------|------|------|------|
| `/opt/scopesentry/.env` | 服务端 | DB/Redis 密码、镜像名、端口 | install-server.sh 初装 | install-server.sh 每次 |
| `/opt/scopesentry/install-server.sh` | 服务端 | 脚本自身副本 | install-server.sh 升级分支 | 可选 ssh 后本地跑 |
| `/etc/scopesentry-node/node.env` | 节点机 | NodeName + Mongo/Redis 连接 + PluginKey | 服务端发的 install-node.sh | manage-node.sh 检测安装状态 |
| `/etc/scopesentry-node/manage-node.sh` | 节点机 | 脚本自身副本 | manage-node.sh 升级分支 | 可选本地跑 |
| `.local-dev/state/scan-base-fingerprint` | dev 机 | dockerfile.base sha256 | publish-all 成功 publish-base 后 | publish-all 决定是否跳过 |

## Error Handling

**菜单脚本**：

- 用户按 Ctrl+C / 输入非法选项 → 提示后**重新弹菜单**（不退出）
- 升级失败（docker compose pull 网络问题）→ 打印错误日志摘要 + 提示 "看 `/opt/scopesentry/install-server.log` 定位"，**按任意键返回菜单**；既有容器不变（pull 失败 docker compose 本身不会动现有容器）
- 卸载 destructive 操作 → 必须二次输入确认串才执行（保留数据走 yes/no，彻底卸载走输入 `DELETE EVERYTHING`）
- 状态检查找不到容器 → 提示 "容器未运行，可能需要 [1] 升级 或 [3] 重启"，返回菜单
- Flag 模式（`--upgrade` 等）失败 → 退出码非 0，不弹菜单（脚本化调用环境下不能 hang 在交互）

**publish-all**：

- fail-fast：任一步骤非 0 退出，前面已推的 tag 留在 GHCR
- 错误信息明确指出 "已完成 X / 未完成 Y / 重试命令 Z"
- git push 是最后一步，失败不影响已推镜像；提示用户手动 push

## Testing

按以下顺序做实测（不引入单元测试框架，shell 脚本主要靠端到端验证）：

1. **dev 机 publish-all** 跑一次完整流程，验证：
   - `.local-dev/state/scan-base-fingerprint` 写入正确
   - 3 个镜像同 tag 出现在 GHCR
   - git push 成功（HEAD 出现在 main）
2. **dev 机 publish-all** 第二次（无改动），验证：
   - "scan-base 未变化，跳过" 日志
   - git push 跳过（no changes to commit）
3. **首装服务端**（一台干净 Linux VPS）curl 一行，验证菜单不弹（直接进 install）
4. **已装服务端**裸 curl 一行，验证弹菜单
5. **升级分支**选 [1]，验证 `/opt/scopesentry/install-server.sh` 被覆盖到最新
6. **卸载 [1] 保留数据** + 重新 install，验证密码不变 admin 不变
7. **卸载 [2] 彻底卸载**，验证 `/opt/scopesentry/` 不存在
8. **节点机**装好后跑 `manage-node.sh`，验证菜单弹出、升级和卸载流程

## Compatibility

- 老的 `update-server.sh` raw URL 仍可用（thin wrapper）
- 老的 `update-node.sh` raw URL 仍可用（thin wrapper）
- 已部署的服务端 `/opt/scopesentry/.env` schema 不变
- 已部署的节点 `/etc/scopesentry-node/node.env` schema 不变

## Out of Scope (后续可能做)

- 服务端 ssh 批量推送节点升级（C 方案，`./devctl nodes update --all`）
- 服务端管理菜单加 "查看注册节点列表"、"踢掉离线节点"
- 节点端管理菜单加 "切换服务端"（迁移到不同 ScopeSentry 实例）
- 菜单脚本的本地 systemd 集成（`/usr/local/bin/scopesentry`）
- 镜像签名 / SBOM
