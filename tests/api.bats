#!/usr/bin/env bats
# Transport layer: zone resolution, auth errors, retries, pagination, module auto-install

load helpers

setup() { setup_env; }

@test "zone is resolved by name and cached for the run" {
  octo zone id --domain=example.com --json --quiet
  assert_json '.id == "zone123" and .name == "example.com"'
  [ "$(mock_requests | grep -c 'GET /client/v4/zones')" -eq 1 ]
}

@test "zone lookup walks up the labels (www.sub.example.com -> example.com)" {
  octo zone id --domain=www.sub.example.com --field=.id
  [ "$output" = "zone123" ]
  mock_log | jq -e '[.[] | .query.name] == ["www.sub.example.com","sub.example.com","example.com"]' >/dev/null
}

@test "zone is derived from an FQDN --name when --domain is absent" {
  octo dns upsert --name=app.example.com --type=A --content=203.0.113.5 --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.name == "app.example.com" and .zone_id == "zone123"'
}

@test "--zone-id skips the lookup and CLOUDFLARE_ZONE_ID is honoured" {
  octo dns list --zone-id=zone123 --json --quiet
  [ "$status" -eq 0 ]
  mock_requests | grep -q 'GET /client/v4/zones/zone123$'
  ! mock_requests | grep -q 'GET /client/v4/zones$'
  CLOUDFLARE_ZONE_ID=zone123 CLOUDFLARE_DOMAIN=example.com octo zone id --field=.id
  [ "$output" = "zone123" ]
}

@test "authentication failure exits 2 with the API error" {
  CLOUDFLARE_API_TOKEN=wrong octo zone list
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"HTTP 401"* ]]
  [[ "$stderr" == *"[10000] Authentication error"* ]]
}

@test "not found exits 5" {
  octo dns get --domain=example.com --id=nope
  [ "$status" -eq 5 ]
}

@test "5xx responses are retried" {
  octo api GET '/zones/{zone_id}/flaky' --domain=example.com --json
  [ "$status" -eq 0 ]
  assert_json '.hits == 2'
  [[ "$stderr" == *"HTTP 503; retrying"* ]]
}

@test "429 honours Retry-After" {
  octo api GET '/zones/{zone_id}/ratelimited' --domain=example.com --json
  [ "$status" -eq 0 ]
  assert_json '.hits == 2'
  [[ "$stderr" == *"HTTP 429; retrying in 1s"* ]]
}

@test "retries give up after OCTOFLARE_RETRIES" {
  CLOUDFLARE_API_BASE="http://127.0.0.1:1/client/v4" OCTOFLARE_RETRIES=1 octo zone list
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"curl failed"* ]]
  [[ "$stderr" == *"attempt 1/1"* ]]
}

@test "list commands fetch every page (pages of 50 by default)" {
  mock_seed 250
  octo dns list --domain=example.com --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'length == 250'
  [ "$(mock_requests | grep -c 'GET /client/v4/zones/zone123/dns_records')" -eq 5 ]
  mock_log | jq -e '[.[] | select(.path | endswith("dns_records")) | .query.per_page] | all(. == "50")' >/dev/null
}

@test "--limit fetches a single page" {
  mock_seed 30
  octo dns list --domain=example.com --limit=10 --json --quiet
  assert_json 'length == 10'
  [ "$(mock_requests | grep -c 'dns_records')" -eq 1 ]
}

@test "account is resolved from the zone or the token" {
  octo account id --domain=example.com --field=.id
  [ "$output" = "acc123" ]
  octo account id --field=.id
  [ "$output" = "acc123" ]
  octo account id --account-id=explicit --field=.id
  [ "$output" = "explicit" ]
}

@test "User-Agent and bearer token headers are sent" {
  octo zone list --quiet
  mock_log | jq -e '.[0].headers.authorization == "Bearer test-token"' >/dev/null
}

@test "missing modules are downloaded automatically" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$OCTOFLARE" "$BATS_TEST_TMPDIR/bin/octoflare"
  run --separate-stderr env OCTOFLARE_RAW_BASE="${MOCK}/raw" OCTOFLARE_REF=master "$BATS_TEST_TMPDIR/bin/octoflare" version --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Installing missing Octoflare modules"* ]]
  assert_json '.version == "2.0.0"'
  [ -f "$BATS_TEST_TMPDIR/bin/lib/core.sh" ]
  [ -f "$BATS_TEST_TMPDIR/bin/lib/dns.sh" ]
  # second run uses the installed modules, no download
  run --separate-stderr env OCTOFLARE_RAW_BASE="${MOCK}/raw" "$BATS_TEST_TMPDIR/bin/octoflare" version
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"Installing missing"* ]]
}

@test "modules fall back to OCTOFLARE_HOME when the script directory is read-only" {
  mkdir -p "$BATS_TEST_TMPDIR/ro"
  cp "$OCTOFLARE" "$BATS_TEST_TMPDIR/ro/octoflare"
  chmod 555 "$BATS_TEST_TMPDIR/ro"
  if [ -w "$BATS_TEST_TMPDIR/ro" ]; then skip "running as root, directory is still writable"; fi
  run --separate-stderr env OCTOFLARE_RAW_BASE="${MOCK}/raw" OCTOFLARE_HOME="$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/ro/octoflare" version
  chmod 755 "$BATS_TEST_TMPDIR/ro"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Installing missing Octoflare modules"* ]]
  # first writable fallback wins: <script dir>/../lib/octoflare, then OCTOFLARE_HOME/lib
  [ -f "$BATS_TEST_TMPDIR/lib/octoflare/core.sh" ] || [ -f "$BATS_TEST_TMPDIR/home/lib/core.sh" ]
  [ ! -e "$BATS_TEST_TMPDIR/ro/lib/core.sh" ]
}

@test "a missing dependency is reported (exit 69) when it cannot be installed" {
  mkdir -p "$BATS_TEST_TMPDIR/pathbin"
  for tool in bash curl sed awk grep tr cat mkdir cut wc date head tail sort uniq mv rm cp chmod id uname readlink dirname basename mktemp env printf; do
    p="$(command -v "$tool" || true)"
    [ -n "$p" ] && ln -sf "$p" "$BATS_TEST_TMPDIR/pathbin/$tool"
  done
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/pathbin" OCTOFLARE_UNATTENDED=false "$OCTOFLARE" version
  [ "$status" -eq 69 ]
  [[ "$stderr" == *'Missing dependency "jq"'* ]]
  [[ "$stderr" == *"--unattended"* ]]
}

@test "a static binary placed in OCTOFLARE_HOME/bin is picked up" {
  mkdir -p "$BATS_TEST_TMPDIR/pathbin" "$BATS_TEST_TMPDIR/home/bin"
  for tool in bash curl sed awk grep tr cat mkdir cut wc date head tail sort uniq mv rm cp chmod id uname readlink dirname basename mktemp env printf; do
    p="$(command -v "$tool" || true)"
    [ -n "$p" ] && ln -sf "$p" "$BATS_TEST_TMPDIR/pathbin/$tool"
  done
  ln -sf "$(command -v jq)" "$BATS_TEST_TMPDIR/home/bin/jq"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/pathbin" OCTOFLARE_HOME="$BATS_TEST_TMPDIR/home" "$OCTOFLARE" version
  [ "$status" -eq 0 ]
}
