# Shared helpers for the Octoflare bats tests
bats_require_minimum_version 1.5.0

OCTOFLARE="${OCTOFLARE_ROOT}/src/octoflare"
MOCK="http://127.0.0.1:${MOCK_PORT}"

# setup_env - isolate the test from the user's environment and reset the mock API
setup_env() {
  export HOME="$BATS_TEST_TMPDIR"
  cd "$BATS_TEST_TMPDIR"
  export CLOUDFLARE_API_BASE="${MOCK}/client/v4"
  export CLOUDFLARE_API_TOKEN="test-token"
  export OCTOFLARE_UNATTENDED=true
  export OCTOFLARE_COLOR=never
  export OCTOFLARE_RETRY_DELAY=0
  unset GITHUB_OUTPUT GITHUB_ACTIONS GITHUB_STEP_SUMMARY CI
  unset CLOUDFLARE_DOMAIN CLOUDFLARE_ZONE_ID CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL
  unset OCTOFLARE_DRY_RUN OCTOFLARE_OUTPUT OCTOFLARE_QUIET OCTOFLARE_ENV_FILE OCTOFLARE_ENV_OVERRIDE OCTOFLARE_FIELD
  curl -s -X POST "${MOCK}/__reset" >/dev/null
}

# octo - run octoflare with --separate-stderr semantics ($output = stdout, $stderr = stderr)
octo() {
  run --separate-stderr "$OCTOFLARE" "$@"
}

# mock_log - JSON array of the requests the mock received
mock_log() {
  curl -s "${MOCK}/__log"
}

# mock_requests - "METHOD /path" lines
mock_requests() {
  mock_log | jq -r '.[] | "\(.method) \(.path)"'
}

# mock_seed - add N records to zone123
mock_seed() {
  curl -s -X POST "${MOCK}/__seed?records=$1" >/dev/null
}

# assert_json - evaluate a jq boolean against $output
assert_json() {
  printf '%s' "$output" | jq -e "$1" >/dev/null || {
    echo "jq assertion failed: $1" >&2
    echo "output: $output" >&2
    return 1
  }
}

# fake_curl - Put a curl stand-in first on PATH that records every invocation instead of
# talking to the network. Files under $FAKE_CURL_DIR: argv (latest) / argv.N, body / body.N
# (--data-binary @file contents), config (the -K file), form-<name> / form-<name>.N (-F parts,
# '<file' and '@file' resolved). The response is $FAKE_CURL_DIR/responses/<token>.json when the
# request URL contains <token>, otherwise a generic success envelope.
fake_curl() {
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  export FAKE_CURL_DIR="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$FAKE_CURL_DIR/responses"
  cat > "$BATS_TEST_TMPDIR/fakebin/curl" <<'SH'
#!/usr/bin/env bash
out="$FAKE_CURL_DIR"
n=$(( $(ls "$out" | grep -c '^argv\.') + 1 ))
printf '%s\n' "$@" > "$out/argv.$n"; cp "$out/argv.$n" "$out/argv"
url=""; prev=""
for a in "$@"; do
  case "$prev" in
    -K) cat "$a" > "$out/config" ;;
    --data-binary) [[ "$a" == @* ]] && { cat "${a#@}" > "$out/body.$n"; cp "$out/body.$n" "$out/body"; } ;;
    -F)
      name="${a%%=*}"; spec="${a#*=}"; spec="${spec%%;*}"
      case "$spec" in
        \<*) cat "${spec#<}" > "$out/form-$name.$n" ;;
        @*) cat "${spec#@}" > "$out/form-$name.$n" ;;
        *) printf '%s' "$spec" > "$out/form-$name.$n" ;;
      esac
      cp "$out/form-$name.$n" "$out/form-$name"
      ;;
  esac
  [[ "$a" == http://* || "$a" == https://* ]] && url="$a"
  prev="$a"
done
resp=""
for f in "$out"/responses/*.json; do
  [[ -f "$f" ]] || continue
  token="$(basename "$f" .json)"
  [[ "$url" == *"$token"* ]] && resp="$f"
done
if [[ -n "$resp" ]]; then cat "$resp"; else printf '{"success":true,"errors":[],"messages":[],"result":{"id":"fake"}}'; fi
printf '\n200\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/fakebin/curl"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
}
