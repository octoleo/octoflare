#!/usr/bin/env bats
# Core behaviour: options, environment files, output formats, help, exit codes

load helpers

setup() { setup_env; }

@test "version prints the program version" {
  octo version
  [ "$status" -eq 0 ]
  [[ "$output" == "Octoflare v"* ]]
  octo --version --json
  assert_json '.version == "2.0.0" and .name == "Octoflare"'
}

@test "help lists commands and resources" {
  octo help
  [ "$status" -eq 0 ]
  [[ "$output" == *"dns upsert"* ]]
  [[ "$output" == *"redirect upsert"* ]]
  [[ "$output" == *"Global options"* ]]
}

@test "help --output=json is machine readable" {
  octo help --output=json --quiet
  [ "$status" -eq 0 ]
  assert_json 'type == "array" and (map(select(.resource == "dns" and .action == "upsert")) | length) == 1'
  assert_json 'length > 150'
}

@test "help <resource> shows only that resource" {
  octo help dns
  [ "$status" -eq 0 ]
  [[ "$output" == *"dns upsert"* ]]
  [[ "$output" != *"redirect upsert"* ]]
}

@test "unknown resource exits 64" {
  octo frobnicate list
  [ "$status" -eq 64 ]
  [[ "$stderr" == *"Unknown resource"* ]]
}

@test "unknown action exits 64 and shows the resource help" {
  octo dns frobnicate
  [ "$status" -eq 64 ]
  [[ "$stderr" == *'Unknown action "frobnicate" for dns'* ]]
}

@test "missing API token exits 2" {
  unset CLOUDFLARE_API_TOKEN
  octo zone list
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"CLOUDFLARE_API_TOKEN must be set"* ]]
}

@test "missing zone exits 4 with a helpful message" {
  octo dns list
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"--domain=example.com"* ]]
}

@test "unknown zone exits 4" {
  octo dns list --domain=nope.invalid
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"Could not find a Cloudflare zone for nope.invalid"* ]]
}

@test "config show masks the token and reflects CLI options" {
  octo config show --domain=cli.example.com --api-token=abcdefgh12345678 --json
  [ "$status" -eq 0 ]
  assert_json '.api_token == "****5678" and .domain == "cli.example.com" and .unattended == true'
}

@test "legacy --debug without a command shows the configuration" {
  octo --debug --json
  [ "$status" -eq 0 ]
  assert_json 'has("api_base") and has("lib_dir")'
}

@test "env file is loaded from ./.octoflare and does not override the environment" {
  printf 'CLOUDFLARE_DOMAIN="file.example.com"\nCLOUDFLARE_ACCOUNT_ID=acc-file # comment\nexport CLOUDFLARE_RESTORE_LEVEL=medium\n' > .octoflare
  octo config show --json
  assert_json '.domain == "file.example.com" and .account_id == "acc-file" and .restore_level == "medium" and .env_file == "./.octoflare"'
  CLOUDFLARE_DOMAIN=shell.example.com octo config show --json
  assert_json '.domain == "shell.example.com"'
  OCTOFLARE_ENV_OVERRIDE=true CLOUDFLARE_DOMAIN=shell.example.com octo config show --json
  assert_json '.domain == "file.example.com"'
}

@test "--env and -e load a specific file; missing file exits 2" {
  printf 'CLOUDFLARE_DOMAIN=custom.example.com\n' > custom.env
  octo config show --env=custom.env --json
  assert_json '.domain == "custom.example.com"'
  octo config show -e custom.env --field=.domain
  [ "$output" = "custom.example.com" ]
  octo config show --env=/does/not/exist
  [ "$status" -eq 2 ]
}

@test "CLI options beat environment variables" {
  CLOUDFLARE_DOMAIN=env.example.com octo config show --domain=cli.example.com --field=.domain
  [ "$output" = "cli.example.com" ]
}

@test "wrangler style CF_* aliases are accepted" {
  unset CLOUDFLARE_API_TOKEN
  CF_API_TOKEN=test-token octo token verify --json
  [ "$status" -eq 0 ]
  assert_json '.status == "active"'
}

@test "global API key authentication works" {
  unset CLOUDFLARE_API_TOKEN
  CLOUDFLARE_EMAIL=me@example.com CLOUDFLARE_API_KEY=test-key octo zone list --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'length == 2'
}

@test "--field extracts a value and --json prints compact JSON" {
  octo zone get --domain=example.com --field=.id
  [ "$output" = "zone123" ]
  octo zone get --domain=example.com --json
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -le 1 ]
  assert_json '.name == "example.com"'
  octo zone get --domain=example.com --json --pretty
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -gt 3 ]
}

@test "--quiet suppresses info logs but keeps errors" {
  octo zone get --domain=example.com --quiet
  [ -z "$stderr" ]
  octo zone get --domain=nope.invalid --quiet
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"[error]"* ]]
}

@test "-- ends option parsing" {
  octo -- version
  [ "$status" -eq 0 ]
}

@test "--no-flag sets a boolean option to false" {
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --no-proxied --json --quiet
  assert_json '.proxied == false'
}

@test "dry-run sends no requests and reports the requests it would send" {
  octo dns upsert --domain=example.com --name=www --type=A --content=203.0.113.1 --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[dry-run] POST"*"/dns_records"* ]]
  [ "$(mock_requests | wc -l | tr -d ' ')" -eq 0 ]
}

@test "GitHub Actions outputs are written to GITHUB_OUTPUT" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out.txt"
  : > "$GITHUB_OUTPUT"
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --json --quiet
  [ "$status" -eq 0 ]
  grep -q '^zone_id=zone123$' "$GITHUB_OUTPUT"
  grep -q '^zone_name=example.com$' "$GITHUB_OUTPUT"
  grep -q '^id=rec' "$GITHUB_OUTPUT"
  grep -q '^result={' "$GITHUB_OUTPUT"
  grep -q '^exit_code=0$' "$GITHUB_OUTPUT"
}

@test "--field value becomes the GitHub result output" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out.txt"
  : > "$GITHUB_OUTPUT"
  octo zone id --domain=example.com --field=.id
  [ "$output" = "zone123" ]
  grep -q '^result=zone123$' "$GITHUB_OUTPUT"
}

@test "batch results stay clean JSON under GitHub Actions and annotations are re-emitted" {
  export GITHUB_ACTIONS=true
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out.txt"
  : > "$GITHUB_OUTPUT"
  run "$OCTOFLARE" batch run --domain=example.com --commands=$'zone id\ndns list --domain=nope.invalid' --json --quiet --continue-on-error
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^::add-mask::test-token$')" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^::error title=Octoflare::'
  printf '%s\n' "$output" | grep -v '^::' | jq -e '.results[0].result.id == "zone123" and .results[1].success == false' >/dev/null
  grep -q '^failed=1$' "$GITHUB_OUTPUT"
}

@test "GitHub Actions outputs can be disabled" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out.txt"
  : > "$GITHUB_OUTPUT"
  octo zone get --domain=example.com --json --quiet --github-output=false
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "errors become GitHub annotations and secrets are masked in Actions" {
  export GITHUB_ACTIONS=true
  octo dns list --domain=nope.invalid
  [ "$status" -eq 4 ]
  [[ "$output" == *"::error title=Octoflare::"* ]]
  [[ "$output" == *"::add-mask::test-token"* ]]
}

@test "batch runs commands from a file with shared options" {
  printf '# comment\ndns upsert --name=www --type=A --content=203.0.113.9 --proxied\nsetting set --name=ssl --value=strict\n\ncache purge --everything\n' > batch.txt
  octo batch run --domain=example.com --file=batch.txt --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.total == 3 and .failed == 0 and .results[0].result.name == "www.example.com" and .results[1].result.value == "strict"'
  mock_requests | grep -q 'POST /client/v4/zones/zone123/purge_cache'
}

@test "batch stops at the first failure unless --continue-on-error" {
  octo batch run --domain=example.com --commands=$'zone bogus\ndns list' --json --quiet
  [ "$status" -eq 1 ]
  assert_json '.total == 1 and .failed == 1'
  octo batch run --domain=example.com --commands=$'zone bogus\ndns list' --json --quiet --continue-on-error
  [ "$status" -eq 1 ]
  assert_json '.total == 2 and .failed == 1 and .results[1].success == true'
}

@test "batch reads stdin" {
  octo batch run --domain=example.com --stdin --json --quiet <<< 'zone id'
  [ "$status" -eq 0 ]
  assert_json '.results[0].result.id == "zone123"'
}

@test "api passthrough calls any endpoint and resolves {zone_id}" {
  octo api GET /zones --query=per_page=1 --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'length == 1'
  octo api POST '/zones/{zone_id}/purge_cache' --domain=example.com --data='{"purge_everything":true}' --json --quiet
  [ "$status" -eq 0 ]
  mock_log | jq -e '.[-1] | .method == "POST" and .path == "/client/v4/zones/zone123/purge_cache" and .body.purge_everything == true' >/dev/null
  octo api /user/tokens/verify --field=.status
  [ "$output" = "active" ]
}

@test "self path reports the module directory" {
  octo self path --json
  assert_json '.lib_dir | endswith("src/lib")'
}
