#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install-subdomain-toolchain-linux.sh [options]

Options:
      --assets-dir DIR        Assets directory (default: ~/recon-assets)
      --go-version VER        Go version to install if missing/too old (default: 1.25.0)
      --amass-version VER     Amass GitHub release tag (default: v5.1.1)
      --findomain-version VER Findomain GitHub release tag (default: 10.0.1)
      --skip-bbot             Skip bbot installation
      --skip-seclists         Skip SecLists clone/update
  -h, --help                  Show help
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

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

append_profile_line() {
  local line="$1"
  local file="$2"
  touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '%s\n' "$line" >>"$file"
  fi
}

version_ge() {
  local current="$1"
  local required="$2"
  [[ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n1)" == "$required" ]]
}

install_apt_base() {
  log "installing base packages"
  as_root apt-get update
  as_root DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget git unzip zip python3 python3-pip pipx \
    build-essential make gcc jq dnsutils
}

install_go_if_needed() {
  local arch="$1"
  local go_tar="go${GO_VERSION}.linux-${arch}.tar.gz"
  local current_go_version=""

  if have_cmd go; then
    current_go_version="$(go version | awk '{print $3}' | sed 's/^go//')"
  fi

  if [[ -n "$current_go_version" ]] && version_ge "$current_go_version" "1.24.0"; then
    log "go already available: $current_go_version"
    return 0
  fi

  log "installing go ${GO_VERSION}"
  curl -fsSL "https://go.dev/dl/${go_tar}" -o "/tmp/${go_tar}"
  as_root rm -rf /usr/local/go
  as_root tar -C /usr/local -xzf "/tmp/${go_tar}"

  append_profile_line 'export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH' "$HOME/.bashrc"
  append_profile_line 'export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH' "$HOME/.zshrc"
  export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
}

install_massdns() {
  if have_cmd massdns; then
    log "massdns already installed: $(command -v massdns)"
    return 0
  fi

  log "installing massdns"
  rm -rf /tmp/massdns
  git clone --depth 1 https://github.com/blechschmidt/massdns.git /tmp/massdns
  make -C /tmp/massdns
  as_root make -C /tmp/massdns install
}

install_go_tool() {
  local name="$1"
  local spec="$2"
  if have_cmd "$name"; then
    log "$name already installed: $(command -v "$name")"
    return 0
  fi
  log "installing $name"
  go install -v "$spec"
}

install_amass() {
  local arch="$1"
  local asset="amass_linux_${arch}.tar.gz"
  local url="https://github.com/owasp-amass/amass/releases/download/${AMASS_VERSION}/${asset}"

  if have_cmd amass; then
    log "amass already installed: $(command -v amass)"
    return 0
  fi

  log "installing amass ${AMASS_VERSION}"
  rm -rf /tmp/amass-install
  mkdir -p /tmp/amass-install
  curl -fsSL "$url" -o "/tmp/amass-install/${asset}"
  tar -xzf "/tmp/amass-install/${asset}" -C /tmp/amass-install
  local amass_bin
  amass_bin="$(find /tmp/amass-install -type f -name amass -perm -111 | head -n1)"
  [[ -n "$amass_bin" ]] || die "amass binary not found in archive"
  as_root install -m 0755 "$amass_bin" /usr/local/bin/amass
}

install_findomain() {
  local arch="$1"
  local asset=""
  local url=""

  if have_cmd findomain; then
    log "findomain already installed: $(command -v findomain)"
    return 0
  fi

  case "$arch" in
    amd64) asset="findomain-linux.zip" ;;
    arm64) asset="findomain-aarch64.zip" ;;
    *) die "unsupported arch for findomain: $arch" ;;
  esac

  url="https://github.com/Findomain/Findomain/releases/download/${FINDOMAIN_VERSION}/${asset}"
  log "installing findomain ${FINDOMAIN_VERSION}"
  rm -rf /tmp/findomain-install
  mkdir -p /tmp/findomain-install
  curl -fsSL "$url" -o "/tmp/findomain-install/${asset}"
  unzip -q "/tmp/findomain-install/${asset}" -d /tmp/findomain-install
  local bin
  bin="$(find /tmp/findomain-install -type f -name findomain -perm -111 | head -n1)"
  [[ -n "$bin" ]] || die "findomain binary not found in archive"
  as_root install -m 0755 "$bin" /usr/local/bin/findomain
}

install_python_user_pkg() {
  local pkg="$1"
  if have_cmd "$pkg"; then
    log "$pkg already installed: $(command -v "$pkg")"
    return 0
  fi
  python3 -m pip install --user "$pkg"
}

install_pipx_pkg() {
  local pkg="$1"
  if have_cmd "$pkg"; then
    log "$pkg already installed: $(command -v "$pkg")"
    return 0
  fi
  if ! pipx install "$pkg"; then
    warn "failed to install $pkg via pipx"
  fi
}

prepare_assets() {
  mkdir -p "$ASSETS_DIR"/{resolvers,wordlists}

  log "downloading resolver lists"
  curl -fsSL https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt \
    -o "$ASSETS_DIR/resolvers/resolvers.txt"
  curl -fsSL https://raw.githubusercontent.com/trickest/resolvers/main/resolvers-trusted.txt \
    -o "$ASSETS_DIR/resolvers/trusted.txt"

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

  if [[ "$SKIP_SECLISTS" == "1" ]]; then
    return 0
  fi

  if [[ -d "$ASSETS_DIR/SecLists/.git" ]]; then
    log "updating SecLists"
    git -C "$ASSETS_DIR/SecLists" pull --ff-only || warn "failed to update SecLists"
  else
    log "cloning SecLists"
    git clone --depth 1 https://github.com/danielmiessler/SecLists.git "$ASSETS_DIR/SecLists"
  fi

  cat \
    "$ASSETS_DIR/SecLists/Discovery/DNS/dns-Jhaddix.txt" \
    "$ASSETS_DIR/SecLists/Discovery/DNS/subdomains-top1million-110000.txt" \
    | sort -u >"$ASSETS_DIR/wordlists/subdomains-merged.txt"
}

ASSETS_DIR="$HOME/recon-assets"
GO_VERSION="1.25.0"
AMASS_VERSION="v5.1.1"
FINDOMAIN_VERSION="10.0.1"
SKIP_BBOT=0
SKIP_SECLISTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets-dir)
      ASSETS_DIR="${2:-}"
      shift 2
      ;;
    --go-version)
      GO_VERSION="${2:-}"
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

[[ "$(uname -s)" == "Linux" ]] || die "linux only"

case "$(uname -m)" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "unsupported arch: $(uname -m)" ;;
esac

install_apt_base
install_go_if_needed "$ARCH"
export PATH="/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin:$PATH"

install_massdns
install_amass "$ARCH"
install_findomain "$ARCH"
install_go_tool subfinder github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
install_go_tool puredns github.com/d3mondev/puredns/v2@latest
install_go_tool shuffledns github.com/projectdiscovery/shuffledns/cmd/shuffledns@latest
install_go_tool alterx github.com/projectdiscovery/alterx/cmd/alterx@latest
install_go_tool gotator github.com/Josue87/gotator@latest
install_python_user_pkg dnsgen

if [[ "$SKIP_BBOT" != "1" ]]; then
  install_pipx_pkg bbot
fi

prepare_assets

printf '\nInstalled tools:\n'
for tool in subfinder amass findomain massdns puredns shuffledns alterx dnsgen gotator bbot; do
  if have_cmd "$tool"; then
    printf '  %-12s %s\n' "$tool" "$(command -v "$tool")"
  else
    printf '  %-12s %s\n' "$tool" "NOT_FOUND"
  fi
done

printf '\nAssets:\n'
printf '  resolvers:   %s\n' "$ASSETS_DIR/resolvers/resolvers.txt"
printf '  trusted:     %s\n' "$ASSETS_DIR/resolvers/trusted.txt"
printf '  subdomains:  %s\n' "$ASSETS_DIR/wordlists/subdomains-merged.txt"
printf '  perms:       %s\n' "$ASSETS_DIR/wordlists/permutations-common.txt"
