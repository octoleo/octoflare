#!/usr/bin/env bats
# Review fixes: batch tokenisation, exec, api placeholders, lists, R2, bulk redirects, dates

load helpers

setup() {
  setup_env
  export CLOUDFLARE_ACCOUNT_ID=acc123
}

@test "batch lines are tokenised, never evaluated" {
  printf 'dns create --domain=example.com --name=spf --type=TXT --content="v=spf1 $(touch pwned) `id` ~all"\r\ndns create --domain=example.com --name=w --type=A --content=203.0.113.9\r\n' > batch.txt
  octo batch run --file=batch.txt --json --quiet
  [ "$status" -eq 0 ]
  [ ! -e pwned ]
  assert_json '.total == 2 and .failed == 0 and .results[0].result.content == "\"v=spf1 $(touch pwned) `id` ~all\"" and .results[1].result.content == "203.0.113.9"'
}

@test "batch reports an unterminated quote as exit 3 and stops unless --continue-on-error" {
  octo batch run --domain=example.com --commands=$'zone id --field="oops\nzone id' --json --quiet
  [ "$status" -eq 1 ]
  assert_json '.total == 1 and .failed == 1 and .results[0].exit_code == 3'
  octo batch run --domain=example.com --commands=$'zone id --field="oops\nzone id' --json --quiet --continue-on-error
  assert_json '.total == 2 and .failed == 1 and .results[1].success == true'
}

@test "exec runs one command line in-process with the command's own outputs" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out.txt"
  : > "$GITHUB_OUTPUT"
  octo exec --line='dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --comment="hello world"' --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.comment == "hello world" and .name == "www.example.com"'
  grep -q '^zone_id=zone123$' "$GITHUB_OUTPUT"
  grep -q '^id=rec' "$GITHUB_OUTPUT"
  octo exec --line='  octoflare zone id --domain=example.com  ' --field=.id
  [ "$output" = "zone123" ]
  octo exec line --line='zone id --domain=nope.invalid'
  [ "$status" -eq 4 ]
  octo exec --line=''
  [ "$status" -eq 3 ]
  octo exec --line='zone id --domain="example.com'
  [ "$status" -eq 3 ]
}

@test "exec hands a multi-line string to batch" {
  octo exec --line=$'zone id --domain=example.com\nzone nameservers --domain=example.com' --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.total == 2 and .failed == 0'
}

@test "api request resolves placeholders before sending and fails cleanly" {
  octo api GET '/zones/{zone_id}/dns_records' --domain=nope.invalid --json
  [ "$status" -eq 4 ]
  ! mock_requests | grep -q '/zones//dns_records'
  ! mock_requests | grep -q '/zones/{zone_id}'
  octo api GET '/zones/{zone_id}/dns_records' --domain=example.com --json --quiet
  [ "$status" -eq 0 ]
  mock_requests | grep -q 'GET /client/v4/zones/zone123/dns_records'
}

@test "list remove matches items of every kind by value" {
  octo list create --name=blocked --kind=ip --json --quiet
  octo list add --name=blocked --items=203.0.113.5,203.0.113.6 --json --quiet
  octo list create --name=hosts --kind=hostname --json --quiet
  octo list add --name=hosts --items=a.example.com,b.example.com --json --quiet
  octo list create --name=asns --kind=asn --json --quiet
  octo list add --name=asns --items=AS64496,64497 --json --quiet
  octo list items --name=asns --json --quiet
  assert_json 'map(.asn) == [64496, 64497]'
  octo list remove --name=hosts --items=b.example.com --json --quiet
  [ "$status" -eq 0 ]
  octo list items --name=hosts --json --quiet
  assert_json 'length == 1 and .[0].hostname.url_hostname == "a.example.com"'
  octo list remove --name=asns --items=as64496 --json --quiet
  [ "$status" -eq 0 ]
  octo list items --name=asns --json --quiet
  assert_json 'length == 1 and .[0].asn == 64497'
  octo list remove --name=blocked --items=203.0.113.6 --json --quiet
  octo list items --name=blocked --json --quiet
  assert_json 'length == 1 and .[0].ip == "203.0.113.5"'
  octo list remove --name=blocked --items=198.51.100.1
  [ "$status" -eq 5 ]
}

@test "r2 list follows the cursor over the buckets object" {
  octo r2 list --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'length == 7 and .[0].name == "assets-01" and .[6].name == "assets-07"'
  [ "$(mock_requests | grep -c '/r2/buckets')" -eq 3 ]
  octo r2 list --name-contains=07 --json --quiet
  assert_json 'length == 1'
  octo r2 list
  [[ "$output" == *"assets-03"* ]]
}

@test "r2 public rejects values that are not on/off" {
  octo r2 public --bucket=assets onn --dry-run
  [ "$status" -eq 3 ]
}

@test "bulk-redirect enable accepts --name as well as --list" {
  octo bulk-redirect enable --name=legacy --dry-run --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.expression == "http.request.full_uri in $legacy" and .action_parameters.from_list.name == "legacy"'
}

@test "analytics dates fall back to jq when date cannot do arithmetic" {
  mkdir -p fakebin
  printf '#!/usr/bin/env bash\nexit 1\n' > fakebin/date
  chmod +x fakebin/date
  run bash -c "source \"$OCTOFLARE_ROOT/src/lib/core.sh\" 2>/dev/null; source \"$OCTOFLARE_ROOT/src/lib/analytics.sh\"; PATH=\"$PWD/fakebin:\$PATH\"; dateDaysAgo 3; echo; dateTimeDaysAgo 1"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  [[ "${lines[1]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}
