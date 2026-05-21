#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/runtime"

cat >"$TMP_DIR/bin/go" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$(dirname "$out")"
cat >"$out" <<'BIN'
#!/usr/bin/env bash
set -euo pipefail
printf 'NodeName=%s\n' "${NodeName:-}"
printf 'TASK_MODE=%s\n' "${TASK_MODE:-}"
printf 'STREAM_PORTSCAN_ENABLED=%s\n' "${STREAM_PORTSCAN_ENABLED:-}"
printf 'ADAPTIVE_PULL_ENABLED=%s\n' "${ADAPTIVE_PULL_ENABLED:-}"
printf 'MONGODB_DATABASE=%s\n' "${MONGODB_DATABASE:-}"
BIN
chmod +x "$out"
SH
chmod +x "$TMP_DIR/bin/go"

output="$(
  PATH="$TMP_DIR/bin:$PATH" \
    NODE_NAME=stream-node-from-node-name \
    TASK_MODE=stream \
    STREAM_PORTSCAN_ENABLED=true \
    ADAPTIVE_PULL_ENABLED=true \
    MONGODB_DATABASE=ScopeSentryEnvSmoke \
    SCAN_RUNTIME_DIR="$TMP_DIR/runtime" \
    "$REPO_ROOT/scripts/dev-scan.sh"
)"

grep -q '^NodeName=stream-node-from-node-name$' <<<"$output"
grep -q '^TASK_MODE=stream$' <<<"$output"
grep -q '^STREAM_PORTSCAN_ENABLED=true$' <<<"$output"
grep -q '^ADAPTIVE_PULL_ENABLED=true$' <<<"$output"
grep -q '^MONGODB_DATABASE=ScopeSentryEnvSmoke$' <<<"$output"

printf 'dev scan env smoke passed\n'
