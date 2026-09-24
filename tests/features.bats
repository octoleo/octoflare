#!/usr/bin/env bats
# Settings, security, cache, rules, page rules against the mock API

load helpers

setup() { setup_env; }

@test "setting get/set with --name/--value and positional arguments" {
  octo setting get --domain=example.com --name=ssl --json --quiet
  assert_json '.id == "ssl" and .value == "full"'
  octo setting set --domain=example.com --name=ssl --value=strict --json --quiet
  assert_json '.value == "strict"'
  octo setting set --domain=example.com browser_cache_ttl 3600 --json --quiet
  assert_json '.value == 3600'
  mock_log | jq -e '.[-1].body == {"value":3600}' >/dev/null
  octo setting get --domain=example.com ssl --field=.value
  [ "$output" = "strict" ]
  octo setting set --domain=example.com --name=ssl
  [ "$status" -eq 3 ]
}

@test "setting apply patches many settings at once" {
  octo setting apply --domain=example.com --settings='{"ssl":"strict","min_tls_version":"1.2"}' --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'length == 2'
  mock_log | jq -e '.[-1] | .method == "PATCH" and .path == "/client/v4/zones/zone123/settings" and (.body.items | length) == 2' >/dev/null
  octo setting list --domain=example.com --json --quiet
  assert_json 'map(select(.id == "min_tls_version"))[0].value == "1.2"'
}

@test "attack-mode enable/disable/status and legacy flags" {
  octo attack-mode status --domain=example.com --json --quiet
  assert_json '.value == "medium"'
  octo --enable-attack-mode --domain=example.com --json --quiet
  assert_json '.value == "under_attack"'
  octo --status-attack-mode --domain=example.com
  [[ "$output" == *"under_attack=true"* ]]
  octo --disable-attack-mode --domain=example.com --json --quiet
  assert_json '.value == "high"'
  CLOUDFLARE_RESTORE_LEVEL=medium octo attack-mode disable --domain=example.com --json --quiet
  assert_json '.value == "medium"'
  octo attack-mode level --domain=example.com --level=bogus
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"[1007]"* ]]
}

@test "dev-mode and ssl shortcuts set the underlying settings" {
  octo dev-mode on --domain=example.com --json --quiet
  assert_json '.value == "on"'
  octo ssl mode strict --domain=example.com --json --quiet
  assert_json '.value == "strict"'
  octo ssl always-https on --domain=example.com --field=.value
  [ "$output" = "on" ]
  octo ssl tls13 --domain=example.com --value=off --field=.value
  [ "$output" = "off" ]
  octo ssl hsts --domain=example.com --max-age=31536000 --include-subdomains --json --quiet
  assert_json '.enabled == true and .max_age == 31536000 and .include_subdomains == true'
}

@test "cache purge everything and urls" {
  octo cache purge --domain=example.com --everything --json
  [ "$status" -eq 0 ]
  mock_log | jq -e '.[-1].body == {"purge_everything":true}' >/dev/null
  octo cache purge --domain=example.com --urls=https://example.com/a,https://example.com/b --json
  mock_log | jq -e '.[-1].body == {"files":["https://example.com/a","https://example.com/b"]}' >/dev/null
  octo cache purge --domain=example.com
  [ "$status" -eq 3 ]
}

@test "access-rule block/upsert/delete are idempotent" {
  octo access-rule block --domain=example.com --value=203.0.113.0/24 --notes=bad --json --quiet
  assert_json '.mode == "block" and .configuration.target == "ip_range"'
  octo access-rule block --domain=example.com --value=203.0.113.0/24 --notes=bad --json --quiet
  assert_json '.action == "unchanged"'
  octo access-rule challenge --domain=example.com --value=203.0.113.0/24 --json --quiet
  assert_json '.action == "updated" and .mode == "managed_challenge"'
  octo access-rule allow --domain=example.com --value=AS64496 --json --quiet
  assert_json '.configuration.target == "asn" and .mode == "whitelist"'
  octo access-rule block --domain=example.com --value=de --json --quiet
  assert_json '.configuration == {"target":"country","value":"DE"}'
  octo access-rule list --domain=example.com --json --quiet
  assert_json 'length == 3'
  octo access-rule delete --domain=example.com --value=203.0.113.0/24 --json
  [ "$status" -eq 0 ]
  octo access-rule list --domain=example.com --json --quiet
  assert_json 'length == 2'
  octo access-rule delete --domain=example.com --value=203.0.113.0/24
  [ "$status" -eq 5 ]
}

@test "redirect upsert creates the ruleset first, then adds rules to it" {
  octo redirect upsert --domain=example.com --from=/old --to=https://example.com/new --status=301 --preserve-query --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.action_result == "created" and .expression == "http.request.uri.path eq \"/old\"" and .action_parameters.from_value.target_url.value == "https://example.com/new" and .action_parameters.from_value.status_code == 301 and .action_parameters.from_value.preserve_query_string == true'
  mock_requests | grep -q 'POST /client/v4/zones/zone123/rulesets$'
  octo redirect upsert --domain=example.com --from=/other --to=https://example.com/elsewhere --json --quiet
  assert_json '.action_result == "created"'
  mock_requests | grep -q 'POST /client/v4/zones/zone123/rulesets/rs[0-9]*/rules$'
  octo redirect list --domain=example.com --json --quiet
  assert_json 'length == 2'
}

@test "redirect upsert is idempotent and updates in place" {
  octo redirect upsert --domain=example.com --from=/old --to=https://example.com/new --json --quiet
  id="$(printf '%s' "$output" | jq -r .id)"
  octo redirect upsert --domain=example.com --from=/old --to=https://example.com/new --json --quiet
  assert_json '.action_result == "unchanged"'
  octo redirect upsert --domain=example.com --from=/old --to=https://example.com/newer --status=302 --json --quiet
  assert_json ".action_result == \"updated\" and .id == \"$id\" and .action_parameters.from_value.status_code == 302"
  mock_log | jq -e '.[-1] | .method == "PATCH" and (.path | endswith("/rules/'"$id"'")) and .body.action == "redirect" and .body.expression == "http.request.uri.path eq \"/old\""' >/dev/null
}

@test "redirect expressions: host, prefix, wildcard and preserve-path" {
  octo redirect create --domain=example.com --from=old.example.com --to=https://new.example.com --preserve-path --json --quiet
  assert_json '.expression == "http.host eq \"old.example.com\"" and .action_parameters.from_value.target_url.expression == "concat(\"https://new.example.com\", http.request.uri.path)"'
  octo redirect create --domain=example.com --from=https://example.com/docs --to=https://docs.example.com --match=prefix --json --quiet
  assert_json '.expression == "(http.host eq \"example.com\") and (starts_with(http.request.uri.path, \"/docs\"))"'
  octo redirect create --domain=example.com --from='/blog/*' --to='https://example.com/news/${1}' --json --quiet
  assert_json '.expression == "http.request.uri.path wildcard \"/blog/*\"" and (.action_parameters.from_value.target_url.expression | startswith("wildcard_replace("))'
}

@test "redirect enable/disable/delete select the rule by --from" {
  octo redirect create --domain=example.com --from=/old --to=https://example.com/new --json --quiet
  octo redirect disable --domain=example.com --from=/old --json --quiet
  assert_json '.enabled == false'
  octo redirect enable --domain=example.com --from=/old --field=.enabled
  [ "$output" = "true" ]
  octo redirect delete --domain=example.com --from=/old --json
  [ "$status" -eq 0 ]
  octo redirect list --domain=example.com --json --quiet
  assert_json 'length == 0'
  octo redirect delete --domain=example.com --from=/old
  [ "$status" -eq 5 ]
  octo redirect delete --domain=example.com --from=/old --if-exists
  [ "$status" -eq 0 ]
}

@test "firewall rules build expressions from convenience filters" {
  octo firewall create --domain=example.com --action=block --countries=cn,ru --paths=/wp-login.php --json --quiet
  assert_json '.expression == "(ip.geoip.country in {\"CN\" \"RU\"}) and (http.request.uri.path in {\"/wp-login.php\"})" and .action == "block"'
  octo firewall upsert --domain=example.com --action=managed_challenge --expression='cf.threat_score gt 10' --description="Challenge risky" --json --quiet
  assert_json '.action_result == "created"'
  octo firewall upsert --domain=example.com --action=block --expression='cf.threat_score gt 10' --description="Challenge risky" --json --quiet
  assert_json '.action_result == "updated" and .action == "block"'
  octo firewall create --domain=example.com --action=block
  [ "$status" -eq 3 ]
}

@test "rule apply replaces a phase and rule export round-trips" {
  printf '[{"expression":"http.request.uri.path eq \\"/a\\"","action":"redirect","action_parameters":{"from_value":{"target_url":{"value":"https://b"},"status_code":301}},"description":"a to b"}]' > rules.json
  octo rule apply --domain=example.com --phase=redirect --file=rules.json --json --quiet
  [ "$status" -eq 0 ]
  assert_json 'length == 1 and .[0].description == "a to b"'
  mock_log | jq -e '.[-1] | .method == "PUT" and (.path | endswith("/rulesets/phases/http_request_dynamic_redirect/entrypoint"))' >/dev/null
  octo rule export --domain=example.com --phase=redirect --quiet
  assert_json 'length == 1 and (.[0] | has("id") | not)'
  octo rule list --domain=example.com --phase=http_request_dynamic_redirect --json --quiet
  assert_json 'length == 1'
}

@test "ratelimit, cache-rule, config-rule, origin-rule and transforms create typed rules" {
  octo ratelimit create --domain=example.com --expression='http.request.uri.path eq "/login"' --requests=20 --json --quiet
  assert_json '.ratelimit == {"characteristics":["ip.src","cf.colo.id"],"period":10,"requests_per_period":20,"mitigation_timeout":10}'
  octo cache-rule create --domain=example.com --expression='true' --edge-ttl=3600 --browser-ttl=bypass --json --quiet
  assert_json '.action == "set_cache_settings" and .action_parameters.edge_ttl.default == 3600 and .action_parameters.browser_ttl.mode == "bypass_by_default"'
  octo config-rule create --domain=example.com --expression='true' --ssl=strict --rocket-loader=false --json --quiet
  assert_json '.action == "set_config" and .action_parameters == {"ssl":"strict","rocket_loader":false}'
  octo origin-rule create --domain=example.com --expression='true' --origin-host=backend.internal --origin-port=8443 --json --quiet
  assert_json '.action == "route" and .action_parameters.origin == {"host":"backend.internal","port":8443}'
  octo transform response-header --domain=example.com --expression='true' --set=X-Frame-Options=DENY --remove=Server --json --quiet
  assert_json '.action == "rewrite" and .action_parameters.headers["X-Frame-Options"].value == "DENY" and .action_parameters.headers.Server.operation == "remove"'
  octo transform url --domain=example.com --expression='http.request.uri.path eq "/old"' --path=/new --json --quiet
  assert_json '.action_parameters.uri.path.value == "/new"'
  octo transform list --domain=example.com --json --quiet
  assert_json 'length == 2'
}

@test "pagerule redirect creates, updates and deletes a forwarding rule" {
  octo pagerule redirect --domain=example.com --url='*example.com/legacy/*' --to='https://example.com/$2' --status-code=302 --json --quiet
  assert_json '.action_result == "created" and .actions[0].id == "forwarding_url" and .actions[0].value.status_code == 302'
  octo pagerule redirect --domain=example.com --url='*example.com/legacy/*' --to='https://example.com/$2' --status-code=302 --json --quiet
  assert_json '.action_result == "unchanged"'
  octo pagerule redirect --domain=example.com --url='*example.com/legacy/*' --to='https://example.com/new/$2' --json --quiet
  assert_json '.action_result == "updated" and .actions[0].value.status_code == 301'
  octo pagerule list --domain=example.com --json --quiet
  assert_json 'length == 1'
  octo pagerule disable --domain=example.com --url='*example.com/legacy/*' --field=.status
  [ "$output" = "disabled" ]
  octo pagerule delete --domain=example.com --url='*example.com/legacy/*' --json
  [ "$status" -eq 0 ]
  octo pagerule list --domain=example.com --json --quiet
  assert_json 'length == 0'
}

@test "pagerule create builds actions from flags" {
  octo pagerule create --domain=example.com --url='example.com/assets/*' --cache-level=cache_everything --edge-cache-ttl=7200 --always-use-https --json --quiet
  assert_json '(.actions | map(.id)) == ["always_use_https","cache_level","edge_cache_ttl"] and (.actions[] | select(.id == "edge_cache_ttl") | .value) == 7200'
  octo pagerule create --domain=example.com --url='example.com/x'
  [ "$status" -eq 3 ]
}

@test "zone commands: list, get, nameservers, pause/resume, create, delete" {
  octo zone list --json --quiet
  assert_json 'map(.name) == ["example.com","other.org"]'
  octo zone list --name=other.org --json --quiet
  assert_json 'length == 1'
  octo zone nameservers --domain=example.com
  [[ "$output" == *"a.ns.cloudflare.com"* ]]
  octo zone pause --domain=example.com --field=.paused
  [ "$output" = "true" ]
  octo zone resume --domain=example.com --field=.paused
  [ "$output" = "false" ]
  octo zone create --name=New.Example.net --json --quiet
  assert_json '.name == "new.example.net" and .account.id == "acc123"'
  octo zone delete --domain=new.example.net --json
  [ "$status" -eq 0 ]
  octo zone list --json --quiet
  assert_json 'length == 2'
}
