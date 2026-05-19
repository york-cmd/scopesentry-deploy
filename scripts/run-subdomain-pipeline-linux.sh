#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run-subdomain-pipeline-linux.sh -d example.com [options]

Options:
  -d, --domain DOMAIN     Target root domain
  -w, --workdir DIR       Output directory (default: ~/recon-output/<domain>)
  -R, --rounds N          Prediction rounds (default: 2)
      --assets-dir DIR    Assets directory (default: ~/recon-assets)
      --with-bbot         Enable bbot
      --skip-predict      Skip prediction rounds
  -h, --help              Show help
EOF
}

DOMAIN=""
WORKDIR=""
ROUNDS="2"
ASSETS_DIR="$HOME/recon-assets"
WITH_BBOT=0
SKIP_PREDICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    -w|--workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    -R|--rounds)
      ROUNDS="${2:-}"
      shift 2
      ;;
    --assets-dir)
      ASSETS_DIR="${2:-}"
      shift 2
      ;;
    --with-bbot)
      WITH_BBOT=1
      shift
      ;;
    --skip-predict)
      SKIP_PREDICT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

[[ -n "$DOMAIN" ]] || {
  usage
  exit 1
}

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$HOME/recon-output/$DOMAIN"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD=(
  "$ROOT_DIR/scripts/subdomain-full-pipeline.sh"
  -d "$DOMAIN"
  -r "$ASSETS_DIR/resolvers/resolvers.txt"
  -t "$ASSETS_DIR/resolvers/trusted.txt"
  -s "$ASSETS_DIR/wordlists/subdomains-merged.txt"
  -p "$ASSETS_DIR/wordlists/permutations-common.txt"
  -w "$WORKDIR"
  -R "$ROUNDS"
)

if [[ "$WITH_BBOT" != "1" ]]; then
  CMD+=(--skip-bbot)
fi

if [[ "$SKIP_PREDICT" == "1" ]]; then
  CMD+=(--skip-predict)
fi

printf 'Running:\n'
printf '  %q' "${CMD[@]}"
printf '\n\n'

exec "${CMD[@]}"
