#!/usr/bin/env bash
# 单文件工具：把 ScopeSentry-UI/dist-pro 同步到 ScopeSentry/cmd/main/static 供 go:embed 使用。
# 仅在做"前端打包后嵌入后端"实验时手工跑；常规本地开发不需要——./devctl up 已经把前端跑在 4000 端口。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI_DIR="$ROOT_DIR/ScopeSentry-UI"
STATIC_DIR="$ROOT_DIR/ScopeSentry/cmd/main/static"

if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required but was not found in PATH"
  exit 1
fi

cd "$UI_DIR"

if [[ ! -d node_modules ]]; then
  pnpm install
fi

pnpm build:pro

rsync -a --delete "$UI_DIR/dist-pro/" "$STATIC_DIR/"

echo "Synced ScopeSentry-UI/dist-pro into ScopeSentry/cmd/main/static"
