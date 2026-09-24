#!/usr/bin/env bats
# Review fixes: action packaging, examples, bundle, release, help

load helpers

setup() { setup_env; }

@test "action.yml never evaluates the command input and routes single commands through exec" {
  ! grep -q 'eval ' "$OCTOFLARE_ROOT/action.yml"
  grep -q 'exec --line="\$cmd"' "$OCTOFLARE_ROOT/action.yml"
  grep -q 'batch run --stdin \$extra' "$OCTOFLARE_ROOT/action.yml"
  # OCTOFLARE_FIELD is only exported for single commands
  [ "$(grep -c 'export OCTOFLARE_FIELD' "$OCTOFLARE_ROOT/action.yml")" -eq 1 ]
  grep -B3 'export OCTOFLARE_FIELD' "$OCTOFLARE_ROOT/action.yml" | grep -q '\*)'
}

@test "the action's shell snippet handles block-scalar commands, quotes and literal expansions" {
  # replay the action's run script locally with the same environment the runner provides
  # (the block scalar under "run: |" is the last key of the step; strip its 8-space indent)
  awk '/^      run: \|$/ {on=1; next} on && /^        / {sub(/^        /, ""); print; next} on && /^[[:space:]]*$/ {print ""; next} on {exit}' "$OCTOFLARE_ROOT/action.yml" > run.sh
  grep -q 'exec --line=' run.sh
  export GITHUB_ACTION_PATH="$OCTOFLARE_ROOT" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out.txt"
  export INPUT_API_TOKEN=test-token INPUT_ACCOUNT_ID="" INPUT_ZONE_ID="" INPUT_DOMAIN=example.com INPUT_EMAIL="" INPUT_API_KEY="" INPUT_ORIGIN_CA_KEY="" INPUT_ENV_FILE="" INPUT_OUTPUT=json INPUT_FIELD="" INPUT_DRY_RUN=false INPUT_CONTINUE_ON_ERROR=false INPUT_QUIET=true INPUT_DEBUG=false INPUT_TIMEOUT=60 INPUT_RETRIES=3
  : > "$GITHUB_OUTPUT"
  OCTOFLARE_COMMAND=$'dns create --name=spf --type=TXT --content="v=spf1 $(touch pwned) ~all"\n' OCTOFLARE_COMMANDS="" run --separate-stderr bash run.sh
  [ "$status" -eq 0 ]
  [ ! -e pwned ]
  printf '%s' "$output" | jq -e '.content == "\"v=spf1 $(touch pwned) ~all\""' >/dev/null
  grep -q '^id=rec' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  OCTOFLARE_COMMAND="zone id" OCTOFLARE_COMMANDS="" INPUT_FIELD=.id run --separate-stderr bash run.sh
  [ "$status" -eq 0 ]
  [ "$output" = "zone123" ]
  grep -q '^result=zone123$' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  OCTOFLARE_COMMAND="" OCTOFLARE_COMMANDS=$'# two steps\nzone id\nzone bogus\nzone nameservers\n' INPUT_FIELD=.id INPUT_CONTINUE_ON_ERROR=true run --separate-stderr bash run.sh
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.total == 3 and .failed == 1 and .results[2].success == true' >/dev/null
  grep -q '^failed=1$' "$GITHUB_OUTPUT"
  OCTOFLARE_COMMAND="" OCTOFLARE_COMMANDS="" run --separate-stderr bash run.sh
  [ "$status" -eq 64 ]
}

@test "example workflows pass step outputs through environment variables" {
  ! grep -rn 'run:.*\${{ steps\.' "$OCTOFLARE_ROOT/examples/workflows"
  ! grep -rn "echo '\${{" "$OCTOFLARE_ROOT/examples/workflows"
}

@test "bundle keeps helpers before modules and the bootstrap last, and works" {
  "$OCTOFLARE_ROOT/scripts/bundle.sh" "$BATS_TEST_TMPDIR/bundle" >/dev/null
  helpers="$(grep -n '^######################################## Bootstrap helpers' "$BATS_TEST_TMPDIR/bundle" | cut -d: -f1)"
  modules="$(grep -n '^######################################## Bundled modules' "$BATS_TEST_TMPDIR/bundle" | cut -d: -f1)"
  boot="$(grep -n '^######################################## Bootstrap$' "$BATS_TEST_TMPDIR/bundle" | cut -d: -f1)"
  [ "$helpers" -lt "$modules" ] && [ "$modules" -lt "$boot" ]
  run --separate-stderr "$BATS_TEST_TMPDIR/bundle" zone id --domain=example.com --field=.id
  [ "$status" -eq 0 ]
  [ "$output" = "zone123" ]
}

@test "the release workflow pins the installer to the tag" {
  mkdir -p dist
  GITHUB_REF_NAME=v9.9.9 bash -c 'sed "s|^REF=\"\${OCTOFLARE_REF:-master}\"|REF=\"\${OCTOFLARE_REF:-${GITHUB_REF_NAME}}\"|" "$OCTOFLARE_ROOT/install.sh" > dist/install.sh'
  grep -q '^REF="${OCTOFLARE_REF:-v9.9.9}"$' dist/install.sh
  grep -q 'OCTOFLARE_REF:-\${GITHUB_REF_NAME}' "$OCTOFLARE_ROOT/.github/workflows/release.yml"
}

@test "help documents --env-file and the exec command" {
  octo --help
  [[ "$output" == *"--env-file=<file>"* ]]
  octo help exec
  [[ "$output" == *"exec line --line=<command line>"* ]]
}
