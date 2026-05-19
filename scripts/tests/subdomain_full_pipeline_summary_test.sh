#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIPELINE_SCRIPT="$REPO_ROOT/scripts/subdomain-full-pipeline.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq "$needle" "$file" || fail "expected '$needle' in $file"
}

make_stub_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat >"$bin_dir/subfinder" <<'EOF'
#!/usr/bin/env bash
printf 'www.example.com\napi.example.com\n'
EOF

  cat >"$bin_dir/amass" <<'EOF'
#!/usr/bin/env bash
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
printf 'mail.example.com\n' >"$out"
EOF

  cat >"$bin_dir/findomain" <<'EOF'
#!/usr/bin/env bash
printf 'dev.example.com\n'
EOF

  cat >"$bin_dir/bbot" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "$out"
printf 'cdn.example.com\n' >"$out/subdomains.txt"
EOF

  cat >"$bin_dir/puredns" <<'EOF'
#!/usr/bin/env bash
cmd="$1"
shift
case "$cmd" in
  resolve)
    input="$1"
    shift
    write=""
    wildcards=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --write)
          write="$2"
          shift 2
          ;;
        --write-wildcards)
          wildcards="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    cat "$input" >"$write"
    : >"$wildcards"
    ;;
  bruteforce)
    echo "unexpected puredns bruteforce call" >&2
    exit 99
    ;;
  *)
    exit 1
    ;;
esac
EOF

  cat >"$bin_dir/shuffledns" <<'EOF'
#!/usr/bin/env bash
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
printf 'beta.example.com\n' >"$out"
EOF

  cat >"$bin_dir/alterx" <<'EOF'
#!/usr/bin/env bash
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
printf 'portal.example.com\n' >"$out"
EOF

  cat >"$bin_dir/dnsgen" <<'EOF'
#!/usr/bin/env bash
printf 'uat.example.com\n'
EOF

  cat >"$bin_dir/gotator" <<'EOF'
#!/usr/bin/env bash
printf 'vpn.example.com\n'
EOF

  chmod +x "$bin_dir"/*
}

test_pipeline_summary_and_console_output() {
  local tmp_root
  local stub_bin
  local workdir
  local stdout_file
  local stderr_file
  local resolvers
  local trusted
  local wordlist
  local perm_wordlist
  local summary_file

  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN
  stub_bin="$tmp_root/bin"
  workdir="$tmp_root/work"
  stdout_file="$tmp_root/stdout.log"
  stderr_file="$tmp_root/stderr.log"
  resolvers="$tmp_root/resolvers.txt"
  trusted="$tmp_root/trusted.txt"
  wordlist="$tmp_root/subdomains.txt"
  perm_wordlist="$tmp_root/permutations.txt"
  summary_file="$workdir/logs/summary.txt"

  make_stub_bin "$stub_bin"
  printf '1.1.1.1\n' >"$resolvers"
  printf '1.1.1.1\n' >"$trusted"
  printf 'www\napi\n' >"$wordlist"
  printf 'corp\nedge\n' >"$perm_wordlist"

  PATH="$stub_bin:/usr/bin:/bin" \
  SUBFINDER_BIN="$stub_bin/subfinder" \
  PUREDNS_BIN="$stub_bin/puredns" \
  AMASS_BIN="$stub_bin/amass" \
  BBOT_BIN="$stub_bin/bbot" \
  FINDOMAIN_BIN="$stub_bin/findomain" \
  ALTERX_BIN="$stub_bin/alterx" \
  DNSGEN_BIN="$stub_bin/dnsgen" \
  GOTATOR_BIN="$stub_bin/gotator" \
  SHUFFLEDNS_BIN="$stub_bin/shuffledns" \
    bash "$PIPELINE_SCRIPT" \
      -d example.com \
      -r "$resolvers" \
      -t "$trusted" \
      -s "$wordlist" \
      -p "$perm_wordlist" \
      -w "$workdir" \
      -R 1 >"$stdout_file" 2>"$stderr_file"

  assert_contains "=== Subdomain Pipeline Summary ===" "$stdout_file"
  assert_contains "passive          subfinder                    2" "$summary_file"
  assert_contains "passive          amass                        1" "$summary_file"
  assert_contains "passive          findomain                    1" "$summary_file"
  assert_contains "passive          bbot                         1" "$summary_file"
  assert_contains "bruteforce       shuffledns_raw               1" "$summary_file"
  assert_contains "resolve          bruteforce_validated         1" "$summary_file"
  assert_contains "round1           alterx                       1" "$summary_file"
  assert_contains "round1           dnsgen                       1" "$summary_file"
  assert_contains "round1           gotator                      1" "$summary_file"
  assert_contains "final            final_confirmed              9" "$summary_file"
}

test_pipeline_summary_and_console_output
printf 'PASS: %s\n' "$(basename "$0")"
