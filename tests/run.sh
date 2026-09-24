#!/usr/bin/env bash
# Run the Octoflare test suite: starts the mock Cloudflare API and runs bats.
#
#   tests/run.sh [bats options] [test files]
#
# bats-core is cloned into tests/.bats when no recent bats (>= 1.5) is available.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required to run the mock API" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

# bats (>= 1.5 for --separate-stderr)
BATS=""
if command -v bats >/dev/null 2>&1; then
  ver="$(bats --version 2>/dev/null | awk '{print $2}')"
  major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
  if [[ "${major:-0}" -gt 1 || ( "${major:-0}" -eq 1 && "${minor:-0}" -ge 5 ) ]]; then
    BATS="bats"
  fi
fi
if [[ -z "$BATS" ]]; then
  if [[ ! -x tests/.bats/bin/bats ]]; then
    echo "Installing bats-core into tests/.bats ..." >&2
    git clone -q --depth 1 https://github.com/bats-core/bats-core.git tests/.bats
  fi
  BATS="tests/.bats/bin/bats"
fi

# mock API on a free port
PORT="${MOCK_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')}"
python3 tests/mock_api.py "$PORT" "$ROOT" >tests/.mock.log 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
  curl -s "http://127.0.0.1:${PORT}/__health" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -s "http://127.0.0.1:${PORT}/__health" >/dev/null 2>&1 || { echo "mock API did not start (see tests/.mock.log)" >&2; exit 1; }

export MOCK_PORT="$PORT"
export OCTOFLARE_ROOT="$ROOT"

if [[ $# -gt 0 ]]; then
  "$BATS" "$@"
else
  "$BATS" tests/*.bats
fi
