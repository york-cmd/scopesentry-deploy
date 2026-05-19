#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/ScopeSentry/single-host-deployment.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

python3 - "$COMPOSE_FILE" <<'PY'
import sys
from pathlib import Path

compose_path = Path(sys.argv[1])
text = compose_path.read_text(encoding="utf-8")

try:
    mongodb_section = text.split("  mongodb:\n", 1)[1].split("\n  redis:\n", 1)[0]
except IndexError:
    raise SystemExit("missing mongodb section boundaries")

try:
    redis_section = text.split("  redis:\n", 1)[1].split("\n  scope-sentry:\n", 1)[0]
except IndexError:
    raise SystemExit("missing redis section boundaries")

required_parts = [
    'test: [ "CMD-SHELL",',
    '$${MONGO_INITDB_ROOT_USERNAME}',
    '$${MONGO_INITDB_ROOT_PASSWORD}',
    '--authenticationDatabase admin',
    'db.adminCommand({ ping: 1 })',
]

missing = [part for part in required_parts if part not in mongodb_section]
if missing:
    raise SystemExit(f"mongodb healthcheck missing required parts: {missing}")

redis_required_parts = [
    'CMD-SHELL',
    'redis-cli -a \\"$${REDIS_PASSWORD}\\" ping',
    '|| exit 1',
]

redis_missing = [part for part in redis_required_parts if part not in redis_section]
if redis_missing:
    raise SystemExit(f"redis healthcheck missing required parts: {redis_missing}")
PY

printf 'PASS: compose healthcheck test\n'
