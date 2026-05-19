#!/usr/bin/env bash
# 兼容老入口：委托给 devctl 的新 scan 子命令。
# 新推荐用法:
#   ./devctl scan reload          # 纯 Go 代码改动，~3-5s
#   ./devctl scan rebuild         # tools/linux/* 改动，~10-20s
#   ./devctl scan rebuild-base    # 系统依赖改动，~5-10min
set -euo pipefail

ROOT_DIR="${DEVCTL_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEVCTL="$ROOT_DIR/devctl"

ACTION="${1:-build}"

cat <<'EOF' >&2
[dev-scan-docker-build.sh] 提示: 此脚本已委托给 ./devctl scan。
  纯 Go 改动请用: ./devctl scan reload
  tools 改动请用: ./devctl scan rebuild
  系统依赖改动: ./devctl scan rebuild-base
EOF

case "$ACTION" in
  build|up|restart)
    exec "$DEVCTL" scan rebuild
    ;;
  reload)
    exec "$DEVCTL" scan reload
    ;;
  rebuild-base)
    exec "$DEVCTL" scan rebuild-base
    ;;
  *)
    printf '用法: %s [build|up|restart|reload|rebuild-base]\n' "$0" >&2
    exit 1
    ;;
esac
