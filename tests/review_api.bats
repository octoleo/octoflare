#!/usr/bin/env bats
# Review fixes for the transport layer (src/lib/api.sh): pagination limits, zone precedence,
# case-insensitive record names, credential/body handling, retry policy and URL restrictions.

load helpers

setup() { setup_env; }

# fake_curl - put a curl stand-in first in PATH that records its argv and the -K config file
fake_curl() {
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  cat > "$BATS_TEST_TMPDIR/fakebin/curl" <<'SH'
#!/usr/bin/env bash
out="$FAKE_CURL_DIR"
printf '%s\n' "$@" > "$out/argv"
prev=""
for a in "$@"; do
  if [[ "$prev" == "-K" ]]; then
    cat "$a" > "$out/config"
    ls -l "$a" | cut -c1-10 > "$out/config-mode"
  fi
  if [[ "$prev" == "--data-binary" && "$a" == @* ]]; then
    cat "${a#@}" > "$out/body"
  fi
  prev="$a"
done
printf '{"success":true,"errors":[],"messages":[],"result":{"id":"fake"}}\n200\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/fakebin/curl"
  export FAKE_CURL_DIR="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$FAKE_CURL_DIR"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
}

@test "--limit spans several pages of at most the endpoint maximum" {
  mock_seed 250
  octo dns list --domain=example.com --limit=120 --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'length == 120'
  [ "$(mock_requests | grep -c 'GET /client/v4/zones/zone123/dns_records')" -eq 3 ]
  mock_log | jq -e '[.[] | select(.path | endswith("dns_records")) | .query.per_page] | all(. == "50")' >/dev/null
}

@test "--limit above the record count returns everything in one page" {
  mock_seed 30
  octo dns list --domain=example.com --limit=100 --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'length == 30'
  [ "$(mock_requests | grep -c 'dns_records')" -eq 1 ]
  mock_log | jq -e '[.[] | select(.path | endswith("dns_records")) | .query.per_page] == ["50"]' >/dev/null
}

@test "--limit must be a positive number" {
  octo dns list --domain=example.com --limit=abc --json
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--limit must be a positive number"* ]]
}

@test "OCTOFLARE_PER_PAGE changes the page size" {
  mock_seed 60
  OCTOFLARE_PER_PAGE=25 octo dns list --domain=example.com --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'length == 60'
  [ "$(mock_requests | grep -c 'dns_records')" -eq 3 ]
}

@test "zone list and account list stay within the per_page=50 contract" {
  octo zone list --json --quiet
  [ "$status" -eq 0 ]
  mock_log | jq -e '[.[] | select(.path == "/client/v4/zones") | .query.per_page] == ["50"]' >/dev/null
  octo account list --json --quiet
  [ "$status" -eq 0 ]
  mock_log | jq -e '[.[] | select(.path == "/client/v4/accounts") | .query.per_page | tonumber] | all(. <= 50)' >/dev/null
}

@test "an explicit --domain is looked up even when CLOUDFLARE_ZONE_ID is set" {
  CLOUDFLARE_ZONE_ID=zoneAAA octo zone id --domain=example.com --field=.id
  [ "$status" -eq 0 ]
  [ "$output" = "zone123" ]
  mock_requests | grep -q 'GET /client/v4/zones$'
  ! mock_requests | grep -q 'zoneAAA'
}

@test "an explicit --zone-id wins over a domain and CLOUDFLARE_ZONE_ID alone is honoured" {
  CLOUDFLARE_ZONE_ID=zoneAAA octo zone id --zone-id=zone123 --domain=other.com --field=.id
  [ "$status" -eq 0 ]
  [ "$output" = "zone123" ]
  ! mock_requests | grep -q 'GET /client/v4/zones$'
  CLOUDFLARE_ZONE_ID=zone123 octo zone id --field=.name
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
  ! mock_requests | grep -q 'GET /client/v4/zones$'
}

@test "record names are matched against the zone case-insensitively" {
  octo dns create --domain=example.com --name=www.Example.com --type=A --content=203.0.113.9 --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.name == "www.example.com"'
  octo dns create --zone-id=zone123 --domain=Example.COM --name=api.example.com --type=A --content=203.0.113.10 --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.name == "api.example.com"'
  octo dns get --domain=example.com --name=WWW --type=A --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.name == "www.example.com"'
}

@test "credentials travel in a 0600 curl config file, never in the command line" {
  fake_curl
  octo zone list --json --quiet
  [ "$status" -eq 0 ]
  ! grep -q 'test-token' "$FAKE_CURL_DIR/argv"
  grep -q '^-K$' "$FAKE_CURL_DIR/argv"
  grep -q '^header = "Authorization: Bearer test-token"$' "$FAKE_CURL_DIR/config"
  [ "$(cat "$FAKE_CURL_DIR/config-mode")" = "-rw-------" ]
}

@test "global key credentials are also passed through the config file" {
  fake_curl
  CLOUDFLARE_API_TOKEN="" CLOUDFLARE_API_KEY='k"ey\1' CLOUDFLARE_EMAIL=me@example.com octo zone list --json --quiet
  [ "$status" -eq 0 ]
  ! grep -q 'ey' "$FAKE_CURL_DIR/argv"
  grep -q '^header = "X-Auth-Email: me@example.com"$' "$FAKE_CURL_DIR/config"
  grep -q '^header = "X-Auth-Key: k\\"ey\\\\1"$' "$FAKE_CURL_DIR/config"
}

@test "request bodies are sent from a temp file and are not in the command line" {
  fake_curl
  octo dns create --zone-id=zone123 --domain=example.com --name=www --type=A --content=203.0.113.1 --comment='hunter2-secret' --json --quiet
  [ "$status" -eq 0 ]
  ! grep -q 'hunter2' "$FAKE_CURL_DIR/argv"
  grep -q '^--data-binary$' "$FAKE_CURL_DIR/argv"
  jq -e '.comment == "hunter2-secret" and .name == "www.example.com"' "$FAKE_CURL_DIR/body" >/dev/null
  # temp files live in the private run directory and are gone afterwards
  ! grep -q '^@/tmp/[^/]*$' "$FAKE_CURL_DIR/argv"
}

@test "bodies larger than the exec argument limit are sent" {
  head -c 200000 /dev/zero | tr '\0' a > big.txt
  jq -Rs '{files: [.]}' big.txt > big.json
  octo api POST '/zones/{zone_id}/purge_cache' --domain=example.com --data=@big.json --json --quiet
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"Argument list too long"* ]]
  mock_log | jq -e '[.[] | select(.path | endswith("purge_cache")) | .body.files[0] | length] == [200000]' >/dev/null
  OCTOFLARE_DRY_RUN=true octo api POST '/zones/{zone_id}/purge_cache' --domain=example.com --data=@big.json --json --quiet
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"Argument list too long"* ]]
  assert_json '.files[0] | length == 200000'
}

@test "large result sets are assembled without hitting the argument limit" {
  mock_seed 2000
  octo dns list --domain=example.com --json --quiet
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"Argument list too long"* ]]
  assert_json 'length == 2000'
}

@test "POST is not replayed after a 5xx but is retried on 429" {
  octo api POST '/zones/{zone_id}/flaky' --domain=example.com --json
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"HTTP 503"* ]]
  [[ "$stderr" != *"retrying"* ]]
  [ "$(mock_requests | grep -c 'POST /client/v4/zones/zone123/flaky')" -eq 1 ]
  octo api POST '/zones/{zone_id}/ratelimited' --domain=example.com --json
  [ "$status" -eq 0 ]
  assert_json '.hits == 2'
  [[ "$stderr" == *"HTTP 429; retrying"* ]]
}

@test "PUT, PATCH and DELETE are retried after a 5xx" {
  octo api PUT '/zones/{zone_id}/flaky' --domain=example.com --json
  [ "$status" -eq 0 ]
  assert_json '.hits == 2'
  [[ "$stderr" == *"HTTP 503; retrying"* ]]
}

@test "POST network failures are not retried" {
  CLOUDFLARE_API_BASE="http://127.0.0.1:1/client/v4" OCTOFLARE_RETRIES=2 octo api POST /zones --json
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"curl failed"* ]]
  [[ "$stderr" != *"retrying"* ]]
}

@test "absolute URLs are only accepted under CLOUDFLARE_API_BASE" {
  octo api GET https://evil.example/client/v4/zones --json
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"Refusing to send"* ]]
  octo api GET "${CLOUDFLARE_API_BASE}/zones" --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'type == "array"'
  OCTOFLARE_DRY_RUN=true octo api GET "${CLOUDFLARE_API_BASE}evil/zones" --json
  [ "$status" -eq 3 ]
}

@test "stdout stays machine-readable under GitHub Actions with retries and debug logging" {
  GITHUB_ACTIONS=true OCTOFLARE_DEBUG=true octo api GET '/zones/{zone_id}/flaky' --domain=example.com --json
  [ "$status" -eq 0 ]
  assert_json '.hits == 2'
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$stderr" == *"::warning"* ]]
  [[ "$stderr" == *"::debug::"* ]]
}
