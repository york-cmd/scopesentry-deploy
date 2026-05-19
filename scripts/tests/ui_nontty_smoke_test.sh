#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UI_DIR="$REPO_ROOT/ScopeSentry-UI"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

python3 - "$UI_DIR" <<'PY'
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

ui_dir = Path(sys.argv[1])
log_path = Path("/tmp/ui-nontty-smoke.log")
log_path.write_text("", encoding="utf-8")

def port_open(host: str, port: int) -> bool:
    sock = socket.socket()
    sock.settimeout(0.5)
    try:
        sock.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        sock.close()

if port_open("127.0.0.1", 4000):
    raise SystemExit("port 4000 already in use before test start")

with log_path.open("w", encoding="utf-8") as log_file:
    proc = subprocess.Popen(
        ["pnpm", "vite", "--mode", "base"],
        cwd=ui_dir,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        text=True,
    )

try:
    deadline = time.time() + 20
    while time.time() < deadline:
        if port_open("127.0.0.1", 4000):
            print("PASS: ui non-tty smoke test")
            break
        if proc.poll() is not None:
            output = log_path.read_text(encoding="utf-8", errors="replace")
            raise SystemExit(f"ui process exited early with rc={proc.returncode}\n{output}")
        time.sleep(1)
    else:
        output = log_path.read_text(encoding="utf-8", errors="replace")
        raise SystemExit(f"ui did not listen on 4000 within timeout\n{output}")
finally:
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
PY
