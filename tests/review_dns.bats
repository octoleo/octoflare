#!/usr/bin/env bats
# Review fixes for the dns, zone, setting, cache and ssl modules

load helpers

setup() { setup_env; }

# ---------------------------------------------------------------- dns: TXT quoting (finding 7)

@test "dns: TXT content is sent in RFC 1035 quoted form and left alone when already quoted" {
  octo dns create --domain=example.com --name=@ --type=TXT --content='v=spf1 -all' --json --quiet
  [ "$status" -eq 0 ]
  mock_log | jq -e '.[-1].body.content == "\"v=spf1 -all\""' >/dev/null
  assert_json '.content == "\"v=spf1 -all\""'
  octo dns create --domain=example.com --name=quoted --type=TXT --content='"already quoted"' --json --quiet
  mock_log | jq -e '.[-1].body.content == "\"already quoted\""' >/dev/null
  octo dns create --domain=example.com --name=esc --type=TXT --content='say "hi" \ bye' --json --quiet
  assert_json '.content == "\"say \\\"hi\\\" \\\\ bye\""'
  # other record types are never quoted
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --json --quiet
  assert_json '.content == "203.0.113.1"'
}

@test "dns: TXT upsert is idempotent against the quoted content the API stores" {
  octo dns create --domain=example.com --name=@ --type=TXT --content='v=spf1 -all' --quiet
  octo dns create --domain=example.com --name=@ --type=TXT --content='verify=abc123' --quiet
  # matches the record with the same (quoted) content among the duplicates: no --replace needed, nothing deleted
  octo dns upsert --domain=example.com --name=@ --type=TXT --content='v=spf1 -all' --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.action == "unchanged"'
  [ "$(mock_requests | grep -c 'DELETE\|PATCH')" -eq 0 ]
  [ "$(mock_requests | grep -c 'POST')" -eq 2 ]
  octo dns list --domain=example.com --type=TXT --json --quiet
  assert_json 'length == 2'
  # a single TXT record is reported unchanged instead of being patched on every run
  octo dns create --domain=example.com --name=_dmarc --type=TXT --content='v=DMARC1; p=none' --quiet
  octo dns upsert --domain=example.com --name=_dmarc --type=TXT --content='v=DMARC1; p=none' --json --quiet
  assert_json '.action == "unchanged"'
  octo dns upsert --domain=example.com --name=_dmarc --type=TXT --content='v=DMARC1; p=reject' --json --quiet
  assert_json '.action == "updated" and .content == "\"v=DMARC1; p=reject\""'
}

@test "dns: delete and get match TXT records by unquoted --content" {
  octo dns create --domain=example.com --name=@ --type=TXT --content='one' --quiet
  octo dns create --domain=example.com --name=@ --type=TXT --content='two' --quiet
  octo dns get --domain=example.com --name=@ --type=TXT --match-content=two --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.content == "\"two\""'
  octo dns delete --domain=example.com --name=@ --type=TXT --content=two --json
  [ "$status" -eq 0 ]
  assert_json '.deleted == 1'
  octo dns list --domain=example.com --type=TXT --json --quiet
  assert_json 'length == 1 and .[0].content == "\"one\""'
}

# ---------------------------------------------------------------- dns: structured duplicates (finding 30)

@test "dns: upsert matches structured records (CAA/SRV) on their data" {
  octo dns create --domain=example.com --name=@ --type=CAA --tag=issue --value=letsencrypt.org --quiet
  octo dns create --domain=example.com --name=@ --type=CAA --tag=iodef --value=mailto:x@example.com --quiet
  octo dns upsert --domain=example.com --name=@ --type=CAA --tag=issue --value=letsencrypt.org --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.action == "unchanged" and .data.tag == "issue"'
  [ "$(mock_requests | grep -c 'DELETE')" -eq 0 ]
  octo dns list --domain=example.com --type=CAA --json --quiet
  assert_json 'length == 2'
  # SRV: the record with the same data is found among the duplicates, the other one is kept
  octo dns create --domain=example.com --name=_sip._tcp --type=SRV --port=5060 --priority=10 --weight=5 --target=sip1.example.com --quiet
  octo dns create --domain=example.com --name=_sip._tcp --type=SRV --port=5060 --priority=20 --weight=5 --target=sip2.example.com --quiet
  octo dns upsert --domain=example.com --name=_sip._tcp --type=SRV --port=5060 --priority=20 --weight=5 --target=sip2.example.com --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.action == "unchanged" and .data.target == "sip2.example.com"'
  [ "$(mock_requests | grep -c 'DELETE')" -eq 0 ]
  octo dns list --domain=example.com --type=SRV --json --quiet
  assert_json 'length == 2'
  # a genuinely new structured record among duplicates still needs --replace
  octo dns upsert --domain=example.com --name=@ --type=CAA --tag=issuewild --value=letsencrypt.org --json --quiet
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--replace"* ]]
}

# ---------------------------------------------------------------- dns: numeric options (finding 60)

@test "dns: non-numeric --ttl/--priority/--port/--weight/--flags fail with exit 3 and send nothing" {
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --quiet
  octo dns update --domain=example.com --name=www --type=A --ttl=1h
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--ttl"* ]]
  [ "$(mock_requests | grep -c 'PATCH\|POST')" -eq 1 ]
  octo dns create --domain=example.com --name=mail --type=MX --content=mx.example.com --priority=high
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--priority"* ]]
  [[ "$stderr" != *"--content"* ]]
  octo dns upsert --domain=example.com --name=_sip._tcp --type=SRV --port=abc --target=sip.example.com
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--port"* ]]
  octo dns create --domain=example.com --name=_sip._tcp --type=SRV --port=5060 --weight=x --target=sip.example.com
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--weight"* ]]
  octo dns create --domain=example.com --name=@ --type=CAA --tag=issue --value=letsencrypt.org --flags=1.5
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--flags"* ]]
  [ "$(mock_requests | grep -c 'PATCH\|POST')" -eq 1 ]
  # auto and plain numbers still work
  octo dns update --domain=example.com --name=www --type=A --ttl=Auto --json --quiet
  assert_json '.ttl == 1'
  octo dns update --domain=example.com --name=www --type=A --ttl=300 --json --quiet
  assert_json '.ttl == 300'
}

# ---------------------------------------------------------------- setting: value types (findings 11, 12)

@test "setting set sends string enums as strings and numeric settings as numbers" {
  octo setting set --domain=example.com --name=min_tls_version --value=1.2 --json --quiet
  [ "$status" -eq 0 ]
  mock_log | jq -e '.[-1].body == {"value":"1.2"}' >/dev/null
  assert_json '.value == "1.2"'
  octo setting set --domain=example.com --name=min_tls_version --value=1.0 --json --quiet
  mock_log | jq -e '.[-1].body == {"value":"1.0"}' >/dev/null
  octo setting set --domain=example.com --name=origin_max_http_version --value=2 --json --quiet
  [ "$status" -eq 0 ]
  mock_log | jq -e '.[-1].body == {"value":"2"}' >/dev/null
  octo setting set --domain=example.com --name=browser_cache_ttl --value=3600 --json --quiet
  mock_log | jq -e '.[-1].body == {"value":3600}' >/dev/null
  octo setting set --domain=example.com --name=challenge_ttl --value=1800 --json --quiet
  mock_log | jq -e '.[-1].body == {"value":1800}' >/dev/null
  octo setting set --domain=example.com --name=browser_cache_ttl --value=1h
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"whole number"* ]]
  # JSON objects and booleans keep their type, other scalars stay strings
  octo setting set --domain=example.com --name=security_header --value='{"strict_transport_security":{"enabled":true,"max_age":100}}' --json --quiet
  mock_log | jq -e '.[-1].body.value.strict_transport_security.max_age == 100' >/dev/null
  octo setting set --domain=example.com --name=ssl --value=strict --json --quiet
  mock_log | jq -e '.[-1].body == {"value":"strict"}' >/dev/null
}

@test "ssl min-tls sends the version as a string" {
  octo ssl min-tls 1.2 --domain=example.com --json --quiet
  [ "$status" -eq 0 ]
  mock_log | jq -e '.[-1].body == {"value":"1.2"}' >/dev/null
  assert_json '.value == "1.2"'
  octo ssl min-tls --domain=example.com --value=1.3 --field=.value
  [ "$output" = "1.3" ]
  octo ssl min-tls --domain=example.com --field=.value
  [ "$output" = "1.3" ]
}

# ---------------------------------------------------------------- ssl: hsts GET (finding 13) and strict booleans (finding 54)

@test "ssl hsts without options reads the current setting" {
  octo ssl hsts --domain=example.com --json --quiet
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"unbound"* ]]
  assert_json '.enabled == false'
  mock_requests | tail -1 | grep -q 'GET /client/v4/zones/zone123/settings/security_header'
  octo ssl hsts --domain=example.com --max-age=100 --preload --json --quiet
  assert_json '.enabled == true and .max_age == 100 and .preload == true'
  octo ssl hsts --domain=example.com --disable --json --quiet
  assert_json '.enabled == false'
}

@test "ssl on/off toggles reject typos and accept on/off/true/false/zrt" {
  octo ssl tls13 onn --domain=example.com
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"Invalid value"* ]]
  [ "$(mock_requests | grep -c PATCH)" -eq 0 ]
  octo ssl tls13 zrt --domain=example.com --field=.value
  [ "$output" = "zrt" ]
  octo ssl tls13 false --domain=example.com --field=.value
  [ "$output" = "off" ]
  octo ssl always-https --domain=example.com --value=yes --field=.value
  [ "$output" = "on" ]
  octo ssl auto-rewrites enabled --domain=example.com --field=.value
  [ "$output" = "on" ]
  octo ssl opportunistic-encryption nope --domain=example.com
  [ "$status" -eq 3 ]
  octo ssl universal --domain=example.com nope
  [ "$status" -eq 3 ]
  octo ssl mode strict --domain=example.com --field=.value
  [ "$output" = "strict" ]
}

@test "ssl origin-cert commands authenticate with the Origin CA key alone" {
  unset CLOUDFLARE_API_TOKEN
  CLOUDFLARE_ORIGIN_CA_KEY=v1.0-abc OCTOFLARE_DRY_RUN=true octo ssl origin-cert-get --id=abc --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[dry-run] GET"*"/certificates/abc"* ]]
}

# ---------------------------------------------------------------- cache (findings 53, 54)

@test "cache purge --urls from @file or stdin splits on newlines only" {
  printf 'https://example.com/a?ids=1,2\n\n  https://example.com/b  \n' > urls.txt
  octo cache purge --domain=example.com --urls=@urls.txt --json
  [ "$status" -eq 0 ]
  mock_log | jq -e '.[-1].body == {"files":["https://example.com/a?ids=1,2","https://example.com/b"]}' >/dev/null
  octo cache purge --domain=example.com --urls=- --json <<< 'https://example.com/c,d'
  mock_log | jq -e '.[-1].body == {"files":["https://example.com/c,d"]}' >/dev/null
  # inline values stay comma separated
  octo cache purge --domain=example.com --urls=https://example.com/a,https://example.com/b --json
  mock_log | jq -e '.[-1].body == {"files":["https://example.com/a","https://example.com/b"]}' >/dev/null
  : > empty.txt
  octo cache purge --domain=example.com --urls=@empty.txt
  [ "$status" -eq 3 ]
}

@test "cache tiered rejects values that are not on/off" {
  octo cache tiered --domain=example.com onn
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"Invalid value"* ]]
  [ "$(mock_requests | grep -c PATCH)" -eq 0 ]
  octo cache tiered --domain=example.com --value=true --json --quiet
  [ "$status" -eq 0 ]
  mock_log | jq -e '.[-1].body == {"value":"on"}' >/dev/null
  octo cache tiered --domain=example.com off --json --quiet
  mock_log | jq -e '.[-1].body == {"value":"off"}' >/dev/null
}

# ---------------------------------------------------------------- zone create (finding 42)

@test "zone create takes the new name from --name only" {
  octo zone create --name=brand-new.example --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.name == "brand-new.example"'
  mock_requests | grep -q 'POST /client/v4/zones'
  octo zone create --domain=other-new.example
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--name"* ]]
  [ "$(mock_requests | grep -c 'zones?name=')" -eq 0 ]
}
