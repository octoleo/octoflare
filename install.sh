#!/usr/bin/env bash
# Octoflare installer
#
#   curl -fsSL https://raw.githubusercontent.com/octoleo/octoflare/master/install.sh | bash
#
# Environment overrides:
#   OCTOFLARE_REF      Branch or tag to install (default: master)
#   OCTOFLARE_PREFIX   Install prefix (default: /usr/local when writable or sudo is available, else ~/.local)
#   OCTOFLARE_NO_DEPS  Set to true to skip installing curl/jq
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

set -euo pipefail

REPO="${OCTOFLARE_REPO:-octoleo/octoflare}"
REF="${OCTOFLARE_REF:-master}"
RAW="${OCTOFLARE_RAW_BASE:-https://raw.githubusercontent.com/${REPO}}/${REF}"
PROGRAM="octoflare"

log() { printf '[install] %s\n' "$*" >&2; }
hasCmd() { command -v "$1" >/dev/null 2>&1; }

download() {
  if hasCmd curl; then curl -fsSL --retry 3 -o "$2" "$1"
  elif hasCmd wget; then wget -q -O "$2" "$1"
  else log "curl or wget is required to download Octoflare"; exit 1
  fi
}

# Run as root when needed (non-interactive sudo in CI)
asRoot() {
  if [ "$(id -u)" = "0" ]; then "$@"
  elif hasCmd sudo; then
    if [ -t 0 ]; then sudo "$@"; else sudo -n "$@"; fi
  else return 1
  fi
}

# Pick the install prefix
if [ -n "${OCTOFLARE_PREFIX:-}" ]; then
  PREFIX="$OCTOFLARE_PREFIX"
elif [ -w /usr/local/bin ] || asRoot true 2>/dev/null; then
  PREFIX="/usr/local"
else
  PREFIX="${HOME}/.local"
fi
BIN_DIR="${PREFIX}/bin"
LIB_DIR="${PREFIX}/lib/${PROGRAM}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Downloading ${PROGRAM} (${REF}) from ${RAW}..."
download "${RAW}/src/${PROGRAM}" "${TMP}/${PROGRAM}"
chmod +x "${TMP}/${PROGRAM}"

# Module list as declared by the main script
# shellcheck disable=SC2016
MODULES="$(sed -n 's/^OCTOFLARE_MODULES="\${OCTOFLARE_MODULES:-\(.*\)}"$/\1/p' "${TMP}/${PROGRAM}")"
[ -z "$MODULES" ] && MODULES="core api help zone dns setting cache security rules pagerule ssl workers pages tunnel email turnstile r2 account analytics batch"
mkdir -p "${TMP}/lib"
for m in $MODULES; do
  download "${RAW}/src/lib/${m}.sh" "${TMP}/lib/${m}.sh"
done

# Install (with sudo when the prefix is not writable)
install_files() {
  mkdir -p "$BIN_DIR" "$LIB_DIR"
  cp "${TMP}/${PROGRAM}" "${BIN_DIR}/${PROGRAM}"
  chmod 755 "${BIN_DIR}/${PROGRAM}"
  cp "${TMP}"/lib/*.sh "${LIB_DIR}/"
  chmod 644 "${LIB_DIR}"/*.sh
}
if [ -w "$PREFIX" ] || { mkdir -p "$BIN_DIR" 2>/dev/null && [ -w "$BIN_DIR" ]; }; then
  install_files
else
  log "Installing into ${PREFIX} requires elevated permissions..."
  asRoot bash -c "$(declare -f install_files); BIN_DIR='$BIN_DIR'; LIB_DIR='$LIB_DIR'; TMP='$TMP'; PROGRAM='$PROGRAM'; install_files"
fi
log "Installed ${BIN_DIR}/${PROGRAM} with modules in ${LIB_DIR}"

# Dependencies (curl, jq)
if [ "${OCTOFLARE_NO_DEPS:-false}" != "true" ]; then
  OCTOFLARE_UNATTENDED=true OCTOFLARE_LIB_DIR="$LIB_DIR" "${BIN_DIR}/${PROGRAM}" self install-deps --quiet || log "Could not install dependencies automatically; install curl and jq manually."
fi

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) log "Add ${BIN_DIR} to your PATH, e.g.: export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac
"${BIN_DIR}/${PROGRAM}" --version
