#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  subdomain-full-pipeline.sh -d example.com [options]

Purpose:
  Run an external, non-invasive subdomain discovery pipeline before importing
  the final results into ScopeSentry. This does not change the existing
  ScopeSentry module chain.

Required:
  -d, --domain DOMAIN                Root domain to enumerate
  -r, --resolvers FILE               Public resolvers file for puredns

Optional:
  -t, --trusted FILE                 Trusted resolvers file for puredns
  -w, --workdir DIR                  Working directory
  -s, --subdomain-wordlist FILE      Wordlist for puredns bruteforce
  -p, --perm-wordlist FILE           Wordlist for gotator permutations
  -R, --rounds N                     Prediction rounds after seed discovery (default: 2)
      --skip-bbot                    Skip bbot passive enumeration
      --skip-findomain               Skip findomain passive enumeration
      --skip-amass                   Skip amass passive enumeration
      --skip-shuffledns              Skip shuffledns bruteforce/resolve
      --skip-predict                 Skip alterx/dnsgen/gotator prediction rounds
  -h, --help                         Show this help

Environment overrides:
  SUBFINDER_BIN
  PUREDNS_BIN
  AMASS_BIN
  BBOT_BIN
  FINDOMAIN_BIN
  ALTERX_BIN
  DNSGEN_BIN
  GOTATOR_BIN
  SHUFFLEDNS_BIN

Examples:
  ./scripts/subdomain-full-pipeline.sh \
    -d example.com \
    -r /path/to/resolvers.txt \
    -t /path/to/trusted-resolvers.txt \
    -s /path/to/subdomains.txt \
    -p /path/to/permutations.txt
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

line_count() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -l <"$file" | tr -d ' '
  else
    printf '0\n'
  fi
}

append_summary() {
  local section="$1"
  local label="$2"
  local file="$3"
  local count
  count="$(line_count "$file")"
  printf '%-16s %-28s %s\n' "$section" "$label" "$count" >>"$SUMMARY_FILE"
  log "summary ${section}/${label}: ${count}"
}

print_summary() {
  printf '\n=== Subdomain Pipeline Summary ===\n'
  cat "$SUMMARY_FILE"
  printf '\n'
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || die "missing required binary: $bin"
}

resolve_bin() {
  local env_name="$1"
  local fallback="$2"
  local value="${!env_name:-}"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  if command -v "$fallback" >/dev/null 2>&1; then
    command -v "$fallback"
    return 0
  fi
  printf '\n'
}

is_available() {
  [[ -n "${1:-}" ]] && [[ -x "$1" || -f "$1" ]]
}

append_if_exists() {
  local file="$1"
  [[ -f "$file" ]] && cat "$file"
}

filter_scope() {
  local domain="$1"
  local escaped
  escaped="$(printf '%s' "$domain" | sed 's/[.[\*^$()+?{|]/\\&/g')"
  awk 'NF {print tolower($0)}' \
    | sed -E 's#^[[:space:]]+##; s#[[:space:]]+$##' \
    | sed -E 's#^\*\.##' \
    | sed -E 's#^[A-Za-z]+://##' \
    | sed -E 's#/.*$##' \
    | sed '/^$/d' \
    | awk -v re="^(.*\\.)?${escaped}$" '$0 ~ re' \
    | sort -u
}

extract_words() {
  local input_file="$1"
  awk -F. '
    NF > 2 {
      for (i = 1; i < NF - 1; i++) {
        gsub(/[^a-zA-Z0-9-]/, "", $i)
        if (length($i) >= 2) {
          print tolower($i)
        }
        split($i, parts, /-/)
        for (j in parts) {
          if (length(parts[j]) >= 2) {
            print tolower(parts[j])
          }
        }
      }
    }
  ' "$input_file" | sort -u
}

merge_unique() {
  sort -u "$@"
}

run_passive_subfinder() {
  local out_file="$1"
  log "running subfinder"
  "$SUBFINDER" -d "$DOMAIN" -all -recursive -silent >"$out_file" || true
}

run_passive_amass() {
  local out_file="$1"
  [[ "${SKIP_AMASS}" == "1" ]] && return 0
  if ! is_available "$AMASS"; then
    log "amass not found, skipping"
    return 0
  fi
  log "running amass passive"
  "$AMASS" enum -passive -norecursive -noalts -d "$DOMAIN" -o "$out_file" >/dev/null 2>&1 || true
}

run_passive_findomain() {
  local out_file="$1"
  [[ "${SKIP_FINDOMAIN}" == "1" ]] && return 0
  if ! is_available "$FINDOMAIN"; then
    log "findomain not found, skipping"
    return 0
  fi
  log "running findomain"
  "$FINDOMAIN" -t "$DOMAIN" -q >"$out_file" 2>/dev/null || true
}

run_passive_bbot() {
  local out_file="$1"
  local scan_dir="$WORKDIR/tmp/bbot"
  local log_file="$WORKDIR/logs/bbot.log"
  [[ "${SKIP_BBOT}" == "1" ]] && return 0
  if ! is_available "$BBOT"; then
    log "bbot not found, skipping"
    return 0
  fi

  rm -rf "$scan_dir"
  mkdir -p "$scan_dir"
  log "running bbot passive preset (logs: $log_file)"
  "$BBOT" -t "$DOMAIN" -p subdomain-enum -rf passive --no-deps --ignore-failed-deps -y \
    --output-dir "$scan_dir" --name "bbot-${DOMAIN//./-}" >"$log_file" 2>&1 || true

  find "$scan_dir" -type f \( -name 'subdomains*.txt' -o -name '*.txt' \) -print0 \
    | xargs -0 cat 2>/dev/null \
    | filter_scope "$DOMAIN" >"$out_file" || true
}

run_puredns_resolve() {
  local input_file="$1"
  local out_file="$2"
  local wildcard_file="$3"
  [[ -s "$input_file" ]] || {
    : >"$out_file"
    : >"$wildcard_file"
    return 0
  }

  log "running puredns resolve on $(wc -l <"$input_file" | tr -d ' ') candidates"
  if [[ -n "$TRUSTED_RESOLVERS" ]]; then
    "$PUREDNS" resolve "$input_file" \
      --resolvers "$RESOLVERS" \
      --resolvers-trusted "$TRUSTED_RESOLVERS" \
      --write "$out_file" \
      --write-wildcards "$wildcard_file" >/dev/null
  else
    "$PUREDNS" resolve "$input_file" \
      --resolvers "$RESOLVERS" \
      --write "$out_file" \
      --write-wildcards "$wildcard_file" >/dev/null
  fi
}

run_puredns_bruteforce_raw() {
  local out_file="$1"
  [[ -n "$SUBDOMAIN_WORDLIST" ]] || {
    log "subdomain wordlist not provided, skipping puredns bruteforce raw pass"
    : >"$out_file"
    return 0
  }
  [[ -f "$SUBDOMAIN_WORDLIST" ]] || die "missing subdomain wordlist: $SUBDOMAIN_WORDLIST"

  log "running puredns bruteforce raw pass"
  if [[ -n "$TRUSTED_RESOLVERS" ]]; then
    "$PUREDNS" bruteforce "$SUBDOMAIN_WORDLIST" "$DOMAIN" \
      --resolvers "$RESOLVERS" \
      --resolvers-trusted "$TRUSTED_RESOLVERS" \
      --skip-validation \
      --skip-wildcard-filter \
      -q >"$out_file" || true
  else
    "$PUREDNS" bruteforce "$SUBDOMAIN_WORDLIST" "$DOMAIN" \
      --resolvers "$RESOLVERS" \
      --skip-validation \
      --skip-wildcard-filter \
      -q >"$out_file" || true
  fi
}

run_shuffledns_bruteforce() {
  local out_file="$1"
  [[ "${SKIP_SHUFFLEDNS}" == "1" ]] && return 0
  if ! is_available "$SHUFFLEDNS"; then
    log "shuffledns not found, skipping bruteforce cross-check"
    return 0
  fi
  [[ -n "$SUBDOMAIN_WORDLIST" ]] || return 0

  log "running shuffledns bruteforce raw pass"
  if [[ -n "$TRUSTED_RESOLVERS" ]]; then
    "$SHUFFLEDNS" -d "$DOMAIN" -w "$SUBDOMAIN_WORDLIST" -r "$RESOLVERS" -tr "$TRUSTED_RESOLVERS" -mode bruteforce -o "$out_file" >/dev/null 2>&1 || true
  else
    "$SHUFFLEDNS" -d "$DOMAIN" -w "$SUBDOMAIN_WORDLIST" -r "$RESOLVERS" -mode bruteforce -o "$out_file" >/dev/null 2>&1 || true
  fi
}

run_bruteforce_raw() {
  local out_file="$1"
  BRUTEFORCE_SOURCE="puredns"

  if [[ "${SKIP_SHUFFLEDNS}" != "1" ]] && is_available "$SHUFFLEDNS"; then
    BRUTEFORCE_SOURCE="shuffledns"
    run_shuffledns_bruteforce "$out_file"
    return 0
  fi

  if [[ "${SKIP_SHUFFLEDNS}" == "1" ]]; then
    log "shuffledns skipped, falling back to puredns raw bruteforce"
  else
    log "shuffledns not found, falling back to puredns raw bruteforce"
  fi
  run_puredns_bruteforce_raw "$out_file"
}

run_prediction_round() {
  local seed_file="$1"
  local round_prefix="$2"
  local round_words="$3"

  [[ "${SKIP_PREDICT}" == "1" ]] && return 0
  [[ -s "$seed_file" ]] || return 0

  extract_words "$seed_file" >"$round_words"
  if [[ -n "$PERM_WORDLIST" ]] && [[ -f "$PERM_WORDLIST" ]]; then
    cat "$round_words" "$PERM_WORDLIST" | sort -u >"${round_words}.merged"
    mv "${round_words}.merged" "$round_words"
  fi

  if is_available "$ALTERX"; then
    log "running alterx for $round_prefix"
    "$ALTERX" -l "$seed_file" -enrich -o "predict/${round_prefix}-alterx.txt" >/dev/null 2>&1 || true
  else
    : >"predict/${round_prefix}-alterx.txt"
  fi

  if is_available "$DNSGEN"; then
    log "running dnsgen for $round_prefix"
    "$DNSGEN" "$seed_file" >"predict/${round_prefix}-dnsgen.txt" 2>/dev/null || true
  else
    : >"predict/${round_prefix}-dnsgen.txt"
  fi

  if is_available "$GOTATOR"; then
    log "running gotator for $round_prefix"
    "$GOTATOR" -sub "$seed_file" -perm "$round_words" -depth 2 -numbers 5 -mindup -adv -md -silent >"predict/${round_prefix}-gotator.txt" 2>/dev/null || true
  else
    : >"predict/${round_prefix}-gotator.txt"
  fi

  cat \
    "predict/${round_prefix}-alterx.txt" \
    "predict/${round_prefix}-dnsgen.txt" \
    "predict/${round_prefix}-gotator.txt" \
    | filter_scope "$DOMAIN" >"predict/${round_prefix}-candidates.txt"

  run_puredns_resolve \
    "predict/${round_prefix}-candidates.txt" \
    "resolve/${round_prefix}-resolved.txt" \
    "resolve/${round_prefix}-wildcards.txt"
}

DOMAIN=""
WORKDIR=""
RESOLVERS=""
TRUSTED_RESOLVERS=""
SUBDOMAIN_WORDLIST=""
PERM_WORDLIST=""
ROUNDS=2
SKIP_BBOT=0
SKIP_FINDOMAIN=0
SKIP_AMASS=0
SKIP_SHUFFLEDNS=0
SKIP_PREDICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    -r|--resolvers)
      RESOLVERS="${2:-}"
      shift 2
      ;;
    -t|--trusted)
      TRUSTED_RESOLVERS="${2:-}"
      shift 2
      ;;
    -w|--workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    -s|--subdomain-wordlist)
      SUBDOMAIN_WORDLIST="${2:-}"
      shift 2
      ;;
    -p|--perm-wordlist)
      PERM_WORDLIST="${2:-}"
      shift 2
      ;;
    -R|--rounds)
      ROUNDS="${2:-}"
      shift 2
      ;;
    --skip-bbot)
      SKIP_BBOT=1
      shift
      ;;
    --skip-findomain)
      SKIP_FINDOMAIN=1
      shift
      ;;
    --skip-amass)
      SKIP_AMASS=1
      shift
      ;;
    --skip-shuffledns)
      SKIP_SHUFFLEDNS=1
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
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$DOMAIN" ]] || die "missing domain, use -d example.com"
[[ -n "$RESOLVERS" ]] || die "missing resolvers file, use -r /path/to/resolvers.txt"
[[ -f "$RESOLVERS" ]] || die "resolvers file not found: $RESOLVERS"
if [[ -n "$TRUSTED_RESOLVERS" ]]; then
  [[ -f "$TRUSTED_RESOLVERS" ]] || die "trusted resolvers file not found: $TRUSTED_RESOLVERS"
fi
[[ "$ROUNDS" =~ ^[0-9]+$ ]] || die "rounds must be a positive integer"

SUBFINDER="$(resolve_bin SUBFINDER_BIN subfinder)"
PUREDNS="$(resolve_bin PUREDNS_BIN puredns)"
AMASS="$(resolve_bin AMASS_BIN amass)"
BBOT="$(resolve_bin BBOT_BIN bbot)"
FINDOMAIN="$(resolve_bin FINDOMAIN_BIN findomain)"
ALTERX="$(resolve_bin ALTERX_BIN alterx)"
DNSGEN="$(resolve_bin DNSGEN_BIN dnsgen)"
GOTATOR="$(resolve_bin GOTATOR_BIN gotator)"
SHUFFLEDNS="$(resolve_bin SHUFFLEDNS_BIN shuffledns)"

[[ -n "$SUBFINDER" ]] || die "subfinder is required"
[[ -n "$PUREDNS" ]] || die "puredns is required"

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$PWD/recon-$DOMAIN"
fi

mkdir -p "$WORKDIR"/{passive,resolve,bruteforce,predict,final,tmp,logs}
cd "$WORKDIR"
SUMMARY_FILE="$WORKDIR/logs/summary.txt"
: >"$SUMMARY_FILE"
printf '%-16s %-28s %s\n' "Section" "Item" "Count" >>"$SUMMARY_FILE"
printf '%-16s %-28s %s\n' "-------" "----" "-----" >>"$SUMMARY_FILE"

log "domain: $DOMAIN"
log "workdir: $WORKDIR"
log "this pipeline is external to ScopeSentry and does not change the existing module chain"

run_passive_subfinder "passive/subfinder.txt"
append_summary "passive" "subfinder" "passive/subfinder.txt"
run_passive_amass "passive/amass.txt"
append_summary "passive" "amass" "passive/amass.txt"
run_passive_findomain "passive/findomain.txt"
append_summary "passive" "findomain" "passive/findomain.txt"
run_passive_bbot "passive/bbot.txt"
append_summary "passive" "bbot" "passive/bbot.txt"

cat \
  <(append_if_exists "passive/subfinder.txt") \
  <(append_if_exists "passive/amass.txt") \
  <(append_if_exists "passive/findomain.txt") \
  <(append_if_exists "passive/bbot.txt") \
  | filter_scope "$DOMAIN" >"passive/all.txt"
append_summary "passive" "merged_candidates" "passive/all.txt"

run_puredns_resolve "passive/all.txt" "resolve/passive-resolved.txt" "resolve/passive-wildcards.txt"
append_summary "resolve" "passive_resolved" "resolve/passive-resolved.txt"
run_bruteforce_raw "bruteforce/raw.txt"
append_summary "bruteforce" "${BRUTEFORCE_SOURCE}_raw" "bruteforce/raw.txt"
run_puredns_resolve "bruteforce/raw.txt" "resolve/bruteforce-validated.txt" "resolve/bruteforce-wildcards.txt"
append_summary "resolve" "bruteforce_validated" "resolve/bruteforce-validated.txt"

cat \
  <(append_if_exists "resolve/passive-resolved.txt") \
  <(append_if_exists "resolve/bruteforce-validated.txt") \
  | filter_scope "$DOMAIN" >"final/round1-confirmed.txt"
append_summary "confirmed" "round1" "final/round1-confirmed.txt"

cp "final/round1-confirmed.txt" "final/current-confirmed.txt"

if [[ "$SKIP_PREDICT" != "1" ]]; then
  round=1
  while [[ "$round" -le "$ROUNDS" ]]; do
    seed_file="final/current-confirmed.txt"
    round_prefix="round${round}"
    round_words="predict/${round_prefix}-words.txt"
    append_summary "$round_prefix" "seed_input" "$seed_file"

    run_prediction_round "$seed_file" "$round_prefix" "$round_words"
    append_summary "$round_prefix" "words" "$round_words"
    append_summary "$round_prefix" "alterx" "predict/${round_prefix}-alterx.txt"
    append_summary "$round_prefix" "dnsgen" "predict/${round_prefix}-dnsgen.txt"
    append_summary "$round_prefix" "gotator" "predict/${round_prefix}-gotator.txt"
    append_summary "$round_prefix" "candidates" "predict/${round_prefix}-candidates.txt"
    append_summary "$round_prefix" "resolved" "resolve/${round_prefix}-resolved.txt"

    cat \
      <(append_if_exists "final/current-confirmed.txt") \
      <(append_if_exists "resolve/${round_prefix}-resolved.txt") \
      | filter_scope "$DOMAIN" >"final/${round_prefix}-confirmed.txt"
    append_summary "$round_prefix" "confirmed" "final/${round_prefix}-confirmed.txt"

    cp "final/${round_prefix}-confirmed.txt" "final/current-confirmed.txt"
    round=$((round + 1))
  done
fi

cp "final/current-confirmed.txt" "final/final.txt"
append_summary "final" "final_confirmed" "final/final.txt"

log "pipeline completed"
log "final confirmed subdomains: $(wc -l <"final/final.txt" | tr -d ' ')"
log "final output: $WORKDIR/final/final.txt"
log "summary output: $SUMMARY_FILE"
log "import final/final.txt into ScopeSentry as task input if you want to preserve the existing scan chain"
print_summary
