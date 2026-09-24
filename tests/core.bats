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

@test "env file is loaded from ./.octoflare (interactive) and does not override the environment" {
  export OCTOFLARE_UNATTENDED=false
  printf 'CLOUDFLARE_DOMAIN="file.example.com" # comment after quotes\nCLOUDFLARE_ACCOUNT_ID=acc-file # comment\nexport CLOUDFLARE_RESTORE_LEVEL=medium\nOCTOFLARE_OUTPUT=json\n' > .octoflare
  octo config show
  assert_json '.domain == "file.example.com" and .account_id == "acc-file" and .restore_level == "medium" and .env_file == "./.octoflare" and .output == "json"'
  CLOUDFLARE_DOMAIN=shell.example.com octo config show --json
  assert_json '.domain == "shell.example.com"'
  OCTOFLARE_ENV_OVERRIDE=true CLOUDFLARE_DOMAIN=shell.example.com octo config show --json
  assert_json '.domain == "file.example.com"'
  octo config show --output=text --field=.output
  [ "$output" = "text" ]
}

@test "unattended runs ignore ./.octoflare unless the file is requested explicitly" {
  printf 'CLOUDFLARE_DOMAIN=file.example.com\n' > .octoflare
  octo config show --json
  assert_json '.domain == "" and .env_file == ""'
  octo config show --env=.octoflare --json
  assert_json '.domain == "file.example.com"'
  OCTOFLARE_ENV_FILE=.octoflare octo config show --field=.domain
  [ "$output" = "file.example.com" ]
}

@test "env file values with quotes, escapes and CRLF are parsed" {
  printf 'A="x \\"y\\" z" # c\r\nB='"'"'single # not comment'"'"'\r\nC=plain value # comment\r\n' > vars.env
  run --separate-stderr bash -c "source "$OCTOFLARE_ROOT/src/lib/core.sh" 2>/dev/null; OCTOFLARE_ORIG_ENV=' PATH '; while IFS= read -r l || [ -n \"\$l\" ]; do loadEnvLine \"\$l\"; done < vars.env; printf '%s|%s|%s' \"\$A\" \"\$B\" \"\$C\""
  [ "$output" = 'x "y" z|single # not comment|plain value' ]
}

@test "parseBool is strict and splitArgs never evaluates" {
  run bash -c "source \"$OCTOFLARE_ROOT/src/lib/core.sh\" 2>/dev/null; parseBool ON; parseBool off; parseBool onn"
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = "true" ]
  [ "${lines[1]}" = "false" ]
  cat > line.txt <<'EOT'
a "b c" $(touch pwned) `id` d\ e 'it'"'"'s' --x="q\"in" ${HOME}
EOT
  run bash -c "source \"$OCTOFLARE_ROOT/src/lib/core.sh\" 2>/dev/null; IFS= read -r l < line.txt; splitArgs \"\$l\"; printf '%s\n' \"\${SPLIT_ARGS[@]}\""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "a" ]
  [ "${lines[1]}" = "b c" ]
  [ "${lines[2]}" = '$(touch' ]
  [ "${lines[3]}" = 'pwned)' ]
  [ "${lines[4]}" = '`id`' ]
  [ "${lines[5]}" = "d e" ]
  [ "${lines[6]}" = "it's" ]
  [ "${lines[7]}" = '--x=q"in' ]
  [ "${lines[8]}" = '${HOME}' ]
  [ ! -e pwned ]
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
  run --separate-stderr "$OCTOFLARE" batch run --domain=example.com --commands=$'zone id\ndns list --domain=nope.invalid' --json --quiet --continue-on-error
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^::add-mask::test-token$')" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q '^::error title=Octoflare::'
  printf '%s\n' "$output" | jq -e '.results[0].result.id == "zone123" and .results[1].success == false' >/dev/null
  grep -q '^failed=1$' "$GITHUB_OUTPUT"
}

@test "GitHub Actions outputs can be disabled" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out.txt"
  : > "$GITHUB_OUTPUT"
  octo zone get --domain=example.com --json --quiet --github-output=false
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "errors become GitHub annotations and secrets are masked in Actions (on stderr, stdout stays clean)" {
  export GITHUB_ACTIONS=true
  octo dns list --domain=nope.invalid
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"::error title=Octoflare::"* ]]
  [[ "$stderr" == *"::add-mask::test-token"* ]]
  [ -z "$output" ]
  octo zone id --domain=example.com --field=.id
  [ "$output" = "zone123" ]
}

@test "exit code output is written even when a command dies" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out.txt"
  : > "$GITHUB_OUTPUT"
  octo dns list --domain=nope.invalid
  [ "$status" -eq 4 ]
  grep -q '^exit_code=4$' "$GITHUB_OUTPUT"
}

@test "--api-email is the credential option; --email is free for commands" {
  unset CLOUDFLARE_API_TOKEN
  octo zone list --api-email=me@example.com --api-key=test-key --json --quiet
  [ "$status" -eq 0 ]
  mock_log | jq -e '.[0].headers.authorization == ""' >/dev/null
  octo config show --email=someone@example.com --api-token=x --json
  assert_json '.email == ""'
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
