#!/usr/bin/env bash
# Build a single-file distribution of Octoflare (all modules inlined).
#
#   scripts/bundle.sh [output]   (default: dist/octoflare)
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${ROOT}/dist/octoflare}"
MAIN="${ROOT}/src/octoflare"
MARKER='######################################## Bootstrap'

# shellcheck disable=SC2016
MODULES="$(sed -n 's/^OCTOFLARE_MODULES="\${OCTOFLARE_MODULES:-\(.*\)}"$/\1/p' "$MAIN")"
[[ -z "$MODULES" ]] && { echo "Could not read the module list from ${MAIN}" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
{
  # everything before the bootstrap section (identity, helpers)
  awk -v marker="$MARKER" 'index($0, marker) == 1 {exit} {print}' "$MAIN"
  printf '\n#####################################################################################################################VDM\n'
  printf '######################################## Bundled modules\n\nOCTOFLARE_BUNDLED=true\n'
  for m in $MODULES; do
    printf '\n# ---------------------------------------------------------------- module: %s\n' "$m"
    sed '1{/^#!/d;}' "${ROOT}/src/lib/${m}.sh"
  done
  printf '\n#####################################################################################################################VDM\n'
  # the bootstrap section and everything after it
  awk -v marker="$MARKER" 'found {print; next} index($0, marker) == 1 {found=1; print}' "$MAIN"
} >"$OUT"
chmod +x "$OUT"
echo "Bundled $(wc -l <"$OUT" | tr -d ' ') lines into ${OUT}"
