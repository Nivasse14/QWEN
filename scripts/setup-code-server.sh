#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Binaries and extension packages contain no credentials and may live on the
# persistent workspace volume. User data, Cline history and SecretStorage may
# not: their defaults are under /var/lib and are checked below.
CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-4.135.0}"
CODE_SERVER_PREFIX="${CODE_SERVER_PREFIX:-${RUNTIME_DIR}/code-server-${CODE_SERVER_VERSION}}"
CODE_SERVER_EXTENSIONS_DIR="${CODE_SERVER_EXTENSIONS_DIR:-${RUNTIME_DIR}/code-server-extensions}"
CODE_SERVER_PRIVATE_DIR="${CODE_SERVER_PRIVATE_DIR:-/var/lib/ai-phone-stack/code-server}"
CODE_SERVER_USER_DATA_DIR="${CODE_SERVER_USER_DATA_DIR:-${CODE_SERVER_PRIVATE_DIR}/user-data}"
CODE_SERVER_SETTINGS_TEMPLATE="${CODE_SERVER_SETTINGS_TEMPLATE:-${STACK_ROOT}/config/code-server/settings.json}"
CLINE_EXTENSION_ID="${CLINE_EXTENSION_ID:-saoudrizwan.claude-dev}"
CLINE_EXTENSION_VERSION="${CLINE_EXTENSION_VERSION:-4.1.16}"

[[ "$CODE_SERVER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Invalid CODE_SERVER_VERSION: ${CODE_SERVER_VERSION}"
[[ "$CLINE_EXTENSION_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Invalid CLINE_EXTENSION_VERSION: ${CLINE_EXTENSION_VERSION}"

require_private_path() {
  local path="$1" label="$2"
  [[ "$path" == /* ]] || die "${label} must be an absolute path"
  case "$path" in
    /workspace|/workspace/*)
      die "${label} must stay outside /workspace because it may contain credentials"
      ;;
  esac
}

require_private_path "$CODE_SERVER_PRIVATE_DIR" CODE_SERVER_PRIVATE_DIR
require_private_path "$CODE_SERVER_USER_DATA_DIR" CODE_SERVER_USER_DATA_DIR

find_code_server() {
  if [[ -x "${CODE_SERVER_PREFIX}/bin/code-server" ]]; then
    printf '%s\n' "${CODE_SERVER_PREFIX}/bin/code-server"
    return 0
  fi
  local candidate
  for candidate in "${CODE_SERVER_PREFIX}"/lib/code-server-*/bin/code-server; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

TEMP_DIR=""
cleanup() {
  if [[ -n "$TEMP_DIR" && "$TEMP_DIR" == /tmp/ai-phone-code-server.* ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

install_code_server() {
  require_command curl
  require_command sha256sum
  require_command tar
  require_command uname

  local machine asset_arch default_sha archive_url archive extracted
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)
      asset_arch=amd64
      # Official GitHub release asset digest for v4.135.0.
      default_sha=300ef4e37e469e6368a4673c6a623e1c9ba8a34f42b394fb49c431a8900bc7d1
      ;;
    aarch64|arm64)
      asset_arch=arm64
      # Official GitHub release asset digest for v4.135.0.
      default_sha=fe6561798415e709109cb902dca2a57a687240af7d8220f6fa1d01cd2ae0541e
      ;;
    *) die "Unsupported code-server architecture: ${machine}" ;;
  esac

  if [[ "$CODE_SERVER_VERSION" == 4.135.0 ]]; then
    CODE_SERVER_SHA256="${CODE_SERVER_SHA256:-$default_sha}"
  else
    [[ -n "${CODE_SERVER_SHA256:-}" ]] || die \
      "Set CODE_SERVER_SHA256 when overriding CODE_SERVER_VERSION"
  fi
  [[ "$CODE_SERVER_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] \
    || die "CODE_SERVER_SHA256 must be a SHA-256 digest"

  TEMP_DIR="$(mktemp -d /tmp/ai-phone-code-server.XXXXXX)"
  archive="${TEMP_DIR}/code-server.tar.gz"
  archive_url="https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-${asset_arch}.tar.gz"
  log "Downloading pinned code-server v${CODE_SERVER_VERSION}"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
    --output "$archive" "$archive_url"
  printf '%s  %s\n' "$CODE_SERVER_SHA256" "$archive" | sha256sum --check --status \
    || die "code-server archive checksum mismatch"
  tar -xzf "$archive" -C "$TEMP_DIR"
  extracted="${TEMP_DIR}/code-server-${CODE_SERVER_VERSION}-linux-${asset_arch}"
  [[ -x "${extracted}/bin/code-server" ]] \
    || die "Downloaded code-server archive has an unexpected layout"
  [[ ! -e "$CODE_SERVER_PREFIX" ]] \
    || die "Incomplete destination already exists: ${CODE_SERVER_PREFIX}"
  mkdir -p -- "$(dirname -- "$CODE_SERVER_PREFIX")"
  mv -- "$extracted" "$CODE_SERVER_PREFIX"
  rm -rf -- "$TEMP_DIR"
  TEMP_DIR=""
}

ensure_stack_dirs
install -d -m 0700 "$CODE_SERVER_PRIVATE_DIR" "$CODE_SERVER_USER_DATA_DIR"
mkdir -p -- "$CODE_SERVER_EXTENSIONS_DIR"

if ! CODE_SERVER_BIN="$(find_code_server)"; then
  install_code_server
  CODE_SERVER_BIN="$(find_code_server)" \
    || die "code-server installation completed but its executable was not found"
else
  log "Using existing pinned code-server: ${CODE_SERVER_BIN}"
fi

installed_version="$("$CODE_SERVER_BIN" --version 2>&1 \
  | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print $1; exit }')"
[[ "$installed_version" == "$CODE_SERVER_VERSION" ]] \
  || die "Expected code-server ${CODE_SERVER_VERSION}, found ${installed_version}"

[[ -r "$CODE_SERVER_SETTINGS_TEMPLATE" ]] \
  || die "Missing safe settings template: ${CODE_SERVER_SETTINGS_TEMPLATE}"
install -d -m 0700 "${CODE_SERVER_USER_DATA_DIR}/User"
if [[ ! -e "${CODE_SERVER_USER_DATA_DIR}/User/settings.json" ]]; then
  install -m 0600 "$CODE_SERVER_SETTINGS_TEMPLATE" \
    "${CODE_SERVER_USER_DATA_DIR}/User/settings.json"
fi

install_extension() {
  local extension_target="$1"
  env -i \
    HOME="$CODE_SERVER_PRIVATE_DIR" \
    PATH=/usr/local/bin:/usr/bin:/bin \
    LANG=C.UTF-8 \
    "$CODE_SERVER_BIN" \
    --user-data-dir "$CODE_SERVER_USER_DATA_DIR" \
    --extensions-dir "$CODE_SERVER_EXTENSIONS_DIR" \
    --install-extension "$extension_target" --force
}

if [[ -n "${CLINE_VSIX_PATH:-}" ]]; then
  [[ -r "$CLINE_VSIX_PATH" ]] || die "CLINE_VSIX_PATH is not readable"
  [[ "${CLINE_VSIX_SHA256:-}" =~ ^[0-9a-fA-F]{64}$ ]] || die \
    "CLINE_VSIX_SHA256 is mandatory with CLINE_VSIX_PATH"
  CLINE_VSIX_ACTUAL_SHA256="$(sha256sum -- "$CLINE_VSIX_PATH" | awk '{print $1}')"
  [[ "${CLINE_VSIX_ACTUAL_SHA256,,}" == "${CLINE_VSIX_SHA256,,}" ]] \
    || die "Cline VSIX checksum mismatch"
  install_extension "$CLINE_VSIX_PATH"
else
  # code-server uses Open VSX. Version pinning avoids silently replacing an
  # agent extension that can execute commands in the workspace.
  install_extension "${CLINE_EXTENSION_ID}@${CLINE_EXTENSION_VERSION}" || die \
    "Pinned Cline is unavailable in Open VSX; provide a verified CLINE_VSIX_PATH and CLINE_VSIX_SHA256"
fi

if ! env -i \
  HOME="$CODE_SERVER_PRIVATE_DIR" \
  PATH=/usr/local/bin:/usr/bin:/bin \
  LANG=C.UTF-8 \
  "$CODE_SERVER_BIN" \
  --user-data-dir "$CODE_SERVER_USER_DATA_DIR" \
  --extensions-dir "$CODE_SERVER_EXTENSIONS_DIR" \
  --list-extensions --show-versions \
  | grep -Fqx "${CLINE_EXTENSION_ID}@${CLINE_EXTENSION_VERSION}"; then
  [[ -n "${CLINE_VSIX_PATH:-}" ]] || die "Pinned Cline version was not installed"
  env -i \
    HOME="$CODE_SERVER_PRIVATE_DIR" \
    PATH=/usr/local/bin:/usr/bin:/bin \
    LANG=C.UTF-8 \
    "$CODE_SERVER_BIN" \
    --user-data-dir "$CODE_SERVER_USER_DATA_DIR" \
    --extensions-dir "$CODE_SERVER_EXTENSIONS_DIR" \
    --list-extensions --show-versions \
    | grep -Eiq "^${CLINE_EXTENSION_ID}@[0-9]+\.[0-9]+\.[0-9]+$" \
    || die "Cline VSIX did not register the expected extension ID"
fi

log "code-server ${CODE_SERVER_VERSION} and Cline are installed"
log "Provider credentials remain a one-time UI step; see config/code-server/CLINE_SETUP.md"
