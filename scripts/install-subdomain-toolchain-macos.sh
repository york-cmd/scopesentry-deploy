#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install-subdomain-toolchain-macos.sh [options]

Purpose:
  Install a macOS subdomain discovery toolchain for the external
  subdomain-full-pipeline.sh workflow.

Options:
      --assets-dir DIR      Asset output directory (default: ~/recon-assets)
      --amass-version VER   Amass version tag from GitHub Releases (default: latest)
      --findomain-version VER
                           Findomain version tag from GitHub Releases (default: latest)
      --skip-bbot           Skip bbot installation
      --skip-seclists       Skip SecLists clone/update and merged wordlist generation
      --profile FILE        Shell profile to update (default: ~/.zshrc)
  -h, --help                Show this help

What it installs:
  - GitHub binary: amass
  - GitHub binary: findomain
  - Go binaries: puredns, alterx, shuffledns, gotator
  - Python package: dnsgen
  - pipx package: bbot (best-effort, warning-only on failure)
  - Assets: resolvers, trusted resolvers, SecLists DNS wordlists, permutation list

Examples:
  ./scripts/install-subdomain-toolchain-macos.sh
  ./scripts/install-subdomain-toolchain-macos.sh --assets-dir ~/recon-assets --skip-bbot
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_cmd() {
  have_cmd "$1" || die "missing required command: $1"
}

ensure_profile_line() {
  local line="$1"
  local profile="$2"
  mkdir -p "$(dirname "$profile")"
  touch "$profile"
  if ! grep -Fqx "$line" "$profile"; then
    printf '%s\n' "$line" >>"$profile"
    log "added PATH update to $profile"
  fi
}

install_go_pkg() {
  local name="$1"
  local spec="$2"
  if have_cmd "$name"; then
    log "binary already available, skipping go install: $name"
    return 0
  fi
  log "installing go binary: $name"
  GOBIN="${GOBIN_DIR}" go install "$spec"
}

install_python_user_pkg() {
  local pkg="$1"
  if have_cmd "$pkg"; then
    log "binary already available, skipping python install: $pkg"
    return 0
  fi
  if python3 -m pip show "$pkg" >/dev/null 2>&1; then
    log "python package already installed: $pkg"
    return 0
  fi
  log "installing python package: $pkg"
  python3 -m pip install --user "$pkg"
}

install_pipx_pkg() {
  local pkg="$1"
  if have_cmd "$pkg"; then
    log "binary already available, skipping pipx install: $pkg"
    return 0
  fi
  if pipx list --short 2>/dev/null | awk '{print $1}' | grep -Fxq "$pkg"; then
    log "pipx package already installed: $pkg"
    return 0
  fi
  log "installing pipx package: $pkg"
  if ! pipx install "$pkg"; then
    warn "pipx install failed for $pkg; continuing"
    return 1
  fi
}

download_file() {
  local url="$1"
  local out="$2"
  log "downloading $(basename "$out")"
  curl -fsSL "$url" -o "$out"
}

resolve_amass_version() {
  local requested_version="$1"
  if [[ -n "$requested_version" ]]; then
    printf '%s\n' "$requested_version"
    return 0
  fi

  curl -fsSL https://api.github.com/repos/owasp-amass/amass/releases/latest \
    | sed -n 's/.*"tag_name": "\(v[^"]*\)".*/\1/p' \
    | head -n 1
}

install_amass_github() {
  local requested_version="$1"
  local version
  local arch
  local asset_name
  local url
  local tmp_dir
  local amass_bin

  if have_cmd amass; then
    log "binary already available, skipping GitHub install: amass"
    return 0
  fi

  version="$(resolve_amass_version "$requested_version")"
  [[ -n "$version" ]] || die "failed to resolve latest amass release version"

  case "$(uname -m)" in
    x86_64)
      arch="amd64"
      ;;
    arm64)
      arch="arm64"
      ;;
    *)
      die "unsupported macOS architecture for amass: $(uname -m)"
      ;;
  esac

  asset_name="amass_darwin_${arch}.tar.gz"
  url="https://github.com/owasp-amass/amass/releases/download/${version}/${asset_name}"
  tmp_dir="$(mktemp -d)"
  log "installing amass ${version} from GitHub release"
  curl -fsSL "$url" -o "$tmp_dir/$asset_name"
  tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir"
  amass_bin="$(find "$tmp_dir" -type f -name amass -perm -111 | head -n 1)"
  if [[ -z "$amass_bin" ]]; then
    rm -rf "$tmp_dir"
    die "amass binary not found in downloaded archive"
  fi
  install -m 0755 "$amass_bin" "$GOBIN_DIR/amass"

  rm -rf "$tmp_dir"
  log "installed amass to $GOBIN_DIR/amass"
}

resolve_findomain_version() {
  local requested_version="$1"
  if [[ -n "$requested_version" ]]; then
    printf '%s\n' "$requested_version"
    return 0
  fi

  curl -fsSL https://api.github.com/repos/Findomain/Findomain/releases/latest \
    | sed -n 's/.*"tag_name": "\(.*\)".*/\1/p' \
    | head -n 1
}

install_findomain_github() {
  local requested_version="$1"
  local version
  local asset_name
  local url
  local tmp_dir
  local findomain_bin

  if have_cmd findomain; then
    log "binary already available, skipping GitHub install: findomain"
    return 0
  fi

  version="$(resolve_findomain_version "$requested_version")"
  [[ -n "$version" ]] || die "failed to resolve latest findomain release version"

  case "$(uname -m)" in
    x86_64)
      asset_name="findomain-osx-x86_64.zip"
      ;;
    arm64)
      asset_name="findomain-osx-arm64.zip"
      ;;
    *)
      die "unsupported macOS architecture for findomain: $(uname -m)"
      ;;
  esac

  url="https://github.com/Findomain/Findomain/releases/download/${version}/${asset_name}"
  tmp_dir="$(mktemp -d)"
  log "installing findomain ${version} from GitHub release"
  curl -fsSL "$url" -o "$tmp_dir/$asset_name"
  unzip -q "$tmp_dir/$asset_name" -d "$tmp_dir"
  findomain_bin="$(find "$tmp_dir" -type f \( -name findomain -o -name 'findomain*' \) -perm -111 | head -n 1)"
  if [[ -z "$findomain_bin" ]]; then
    rm -rf "$tmp_dir"
    die "findomain binary not found in downloaded archive"
  fi
  install -m 0755 "$findomain_bin" "$GOBIN_DIR/findomain"

  rm -rf "$tmp_dir"
  log "installed findomain to $GOBIN_DIR/findomain"
}

ASSETS_DIR="$HOME/recon-assets"
PROFILE_FILE="$HOME/.zshrc"
AMASS_VERSION=""
FINDOMAIN_VERSION=""
SKIP_BBOT=0
SKIP_SECLISTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets-dir)
      ASSETS_DIR="${2:-}"
      shift 2
      ;;
    --profile)
      PROFILE_FILE="${2:-}"
      shift 2
      ;;
    --amass-version)
      AMASS_VERSION="${2:-}"
      shift 2
      ;;
    --findomain-version)
      FINDOMAIN_VERSION="${2:-}"
      shift 2
      ;;
    --skip-bbot)
      SKIP_BBOT=1
      shift
      ;;
    --skip-seclists)
      SKIP_SECLISTS=1
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

[[ "$(uname -s)" == "Darwin" ]] || die "this installer is intended for macOS only"

ensure_cmd go
ensure_cmd python3
ensure_cmd pipx
ensure_cmd curl
ensure_cmd git
ensure_cmd unzip

mkdir -p "$ASSETS_DIR"/{resolvers,wordlists}

GOPATH_VALUE="$(go env GOPATH)"
[[ -n "$GOPATH_VALUE" ]] || die "failed to resolve GOPATH"
GOBIN_DIR="${GOBIN:-$GOPATH_VALUE/bin}"
mkdir -p "$GOBIN_DIR"

export PATH="$GOBIN_DIR:$PATH"
ensure_profile_line 'export PATH="$(go env GOPATH)/bin:$PATH"' "$PROFILE_FILE"

log "using assets dir: $ASSETS_DIR"
log "using shell profile: $PROFILE_FILE"

install_amass_github "$AMASS_VERSION"
install_findomain_github "$FINDOMAIN_VERSION"

install_go_pkg puredns github.com/d3mondev/puredns/v2@latest
install_go_pkg alterx github.com/projectdiscovery/alterx/cmd/alterx@latest
install_go_pkg shuffledns github.com/projectdiscovery/shuffledns/cmd/shuffledns@latest
install_go_pkg gotator github.com/Josue87/gotator@latest

install_python_user_pkg dnsgen

if [[ "$SKIP_BBOT" != "1" ]]; then
  install_pipx_pkg bbot || true
fi

download_file \
  https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt \
  "$ASSETS_DIR/resolvers/resolvers.txt"
download_file \
  https://raw.githubusercontent.com/trickest/resolvers/main/resolvers-trusted.txt \
  "$ASSETS_DIR/resolvers/trusted.txt"

cat >"$ASSETS_DIR/wordlists/permutations-common.txt" <<'EOF'
admin
api
app
auth
beta
cdn
corp
crm
dev
demo
gateway
git
grafana
graylog
internal
jira
k8s
mail
mfa
mobile
monitor
new
ns1
old
portal
pre
prod
qa
sso
stage
staging
test
uat
vpn
waf
web
www
EOF
log "wrote permutation wordlist: $ASSETS_DIR/wordlists/permutations-common.txt"

SECLISTS_DIR="$ASSETS_DIR/SecLists"
if [[ "$SKIP_SECLISTS" != "1" ]]; then
  if [[ -d "$SECLISTS_DIR/.git" ]]; then
    log "updating SecLists"
    git -C "$SECLISTS_DIR" pull --ff-only || warn "failed to update SecLists; continuing with existing copy"
  else
    log "cloning SecLists"
    git clone --depth 1 https://github.com/danielmiessler/SecLists.git "$SECLISTS_DIR"
  fi

  DNS_JHADDIX="$SECLISTS_DIR/Discovery/DNS/dns-Jhaddix.txt"
  DNS_TOP1M="$SECLISTS_DIR/Discovery/DNS/subdomains-top1million-110000.txt"
  if [[ -f "$DNS_JHADDIX" && -f "$DNS_TOP1M" ]]; then
    cat "$DNS_JHADDIX" "$DNS_TOP1M" | sort -u >"$ASSETS_DIR/wordlists/subdomains-merged.txt"
    log "wrote merged subdomain wordlist: $ASSETS_DIR/wordlists/subdomains-merged.txt"
  else
    warn "SecLists DNS source files not found; skipped merged subdomain wordlist generation"
  fi
fi

log "tool availability summary:"
for tool in subfinder massdns puredns amass bbot findomain alterx dnsgen gotator shuffledns; do
  if have_cmd "$tool"; then
    printf '  %s -> %s\n' "$tool" "$(command -v "$tool")"
  else
    printf '  %s -> NOT_FOUND\n' "$tool"
  fi
done

PIPELINE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/subdomain-full-pipeline.sh"
cat <<EOF

Next command:
$PIPELINE_SCRIPT \\
  -d example.com \\
  -r $ASSETS_DIR/resolvers/resolvers.txt \\
  -t $ASSETS_DIR/resolvers/trusted.txt \\
  -s $ASSETS_DIR/wordlists/subdomains-merged.txt \\
  -p $ASSETS_DIR/wordlists/permutations-common.txt \\
  -w \$HOME/recon-output/example.com \\
  -R 2
EOF
