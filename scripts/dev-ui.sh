#!/usr/bin/env bash
# 内部 helper：单独使用请优先 ./devctl up（或 ./devctl restart ui）。
set -euo pipefail

ROOT_DIR="${DEVCTL_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UI_DIR="$ROOT_DIR/ScopeSentry-UI"

cd "$UI_DIR"

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm is required but was not found in PATH"
  exit 1
fi

if [[ ! -d node_modules/.pnpm ]]; then
  pnpm install
fi

exec pnpm dev
