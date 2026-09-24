#!/usr/bin/env bats
# Review fixes for the rules, security and pagerule modules

load helpers

setup() { setup_env; }

@test "bot ai-bots accepts block|disabled|only_on_ad_pages and boolean words, rejects anything else" {
  export OCTOFLARE_DRY_RUN=true
  octo bot ai-bots --domain=example.com block --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *'[dry-run] PUT '*'/bot_management {"ai_bots_protection":"block"}'* ]]
  octo bot ai-bots --domain=example.com only_on_ad_pages --json
  [[ "$stderr" == *'{"ai_bots_protection":"only_on_ad_pages"}'* ]]
  octo bot ai-bots --domain=example.com Disabled --json
  [[ "$stderr" == *'{"ai_bots_protection":"disabled"}'* ]]
  octo bot ai-bots --domain=example.com on --json
  [[ "$stderr" == *'{"ai_bots_protection":"block"}'* ]]
  octo bot ai-bots --domain=example.com --value=off --json
  [[ "$stderr" == *'{"ai_bots_protection":"disabled"}'* ]]
  octo bot ai-bots --domain=example.com blocc --json
  [ "$status" -eq 3 ]
  [[ "$stderr" == *'Invalid value "blocc"'* ]]
  [[ "$stderr" != *"[dry-run] PUT"* ]]
}

@test "bot fight-mode validates the on/off value" {
  export OCTOFLARE_DRY_RUN=true
  octo bot fight-mode --domain=example.com off --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *'{"fight_mode":false}'* ]]
  octo bot fight-mode --domain=example.com yes --json
  [[ "$stderr" == *'{"fight_mode":true}'* ]]
  octo bot fight-mode --domain=example.com maybe --json
  [ "$status" -eq 3 ]
  [[ "$stderr" != *"[dry-run] PUT"* ]]
}

@test "firewall list options split on commas only and never glob or word-split" {
  mkdir -p globdir && touch globdir/account.sh globdir/zone.sh
  cd globdir
  octo firewall create --domain=example.com --action=block --paths='/*' --user-agents='Go http client,python-requests, Mozilla/5.0 (compatible; BadBot/1.0)' --path-prefixes='/my page,*.sh' --hosts='*.sh' --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.expression == "(http.request.uri.path in {\"/*\"}) and ((starts_with(http.request.uri.path, \"/my page\") or starts_with(http.request.uri.path, \"*.sh\"))) and (http.host in {\"*.sh\"}) and ((http.user_agent contains \"Go http client\" or http.user_agent contains \"python-requests\" or http.user_agent contains \"Mozilla/5.0 (compatible; BadBot/1.0)\"))"'
  octo firewall create --domain=example.com --action=block --countries=cn,ru --ips='1.2.3.4, 5.6.7.8' --asns=AS64496,as64497 --json --quiet
  assert_json '.expression == "(ip.geoip.country in {\"CN\" \"RU\"}) and (ip.src in {1.2.3.4 5.6.7.8}) and (ip.geoip.asnum in {64496 64497})"'
}

@test "transform --remove splits header names on commas only" {
  mkdir -p globdir && touch globdir/Server
  cd globdir
  octo transform response-header --domain=example.com --expression='true' --remove='Server, X-Powered-By,*' --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.action_parameters.headers == {"Server":{"operation":"remove"},"X-Powered-By":{"operation":"remove"},"*":{"operation":"remove"}}'
}

@test "quoteExpr escapes backslashes and quotes on every Bash version" {
  octo redirect create --domain=example.com --from='/old/\d+' --match=regex --to=https://example.com/new --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.expression == "http.request.uri.path matches \"/old/\\\\d+\""'
  BASH_COMPAT=32 octo redirect create --domain=example.com --from='/say "hi"\now' --to=https://example.com/new --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.expression == "http.request.uri.path eq \"/say \\\"hi\\\"\\\\now\""'
  BASH_COMPAT=32 octo firewall create --domain=example.com --action=block --user-agents='Mozilla\5.0' --json --quiet
  assert_json '.expression == "((http.user_agent contains \"Mozilla\\\\5.0\"))"'
}

@test "redirect --from: scheme-less host/path wildcard targets, query stripping, host wildcards and lowercase hosts" {
  octo redirect create --domain=example.com --from='Old.example.com/blog/*' --to='https://new.example.com/news/${1}' --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.expression == "(http.host eq \"old.example.com\") and (http.request.uri.path wildcard \"/blog/*\")" and .action_parameters.from_value.target_url.expression == "wildcard_replace(http.request.uri.path, \"/blog/*\", \"https://new.example.com/news/${1}\")"'
  octo redirect create --domain=example.com --from='https://Example.com/docs?x=1#top' --to=https://docs.example.com --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.expression == "(http.host eq \"example.com\") and (http.request.uri.path eq \"/docs\")"'
  [[ "$stderr" == *"Ignoring the query string"* ]]
  octo redirect create --domain=example.com --from='/docs#top' --to=https://docs.example.com --json --quiet
  assert_json '.expression == "http.request.uri.path eq \"/docs\""'
  [[ "$stderr" != *"Ignoring the query string"* ]]
  octo redirect create --domain=example.com --from='*.old.example.com' --to=https://new.example.com --json --quiet
  assert_json '.expression == "http.host wildcard \"*.old.example.com\""'
  octo redirect create --domain=example.com --from='https://*.old.example.com/x/*' --to='https://new.example.com/${1}' --match=wildcard --json --quiet
  assert_json '.expression == "(http.host wildcard \"*.old.example.com\") and (http.request.uri.path wildcard \"/x/*\")"'
  octo redirect create --domain=example.com --from='old.example.com' --to='https://new.example.com/${1}' --json --quiet
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"needs a path pattern"* ]]
}

@test "firewall upsert detects a changed skip-rule logging flag" {
  octo firewall upsert --domain=example.com --action=skip --expression='ip.src eq 1.2.3.4' --description='allow office' --json --quiet
  assert_json '.action_result == "created" and .logging == {"enabled":true}'
  octo firewall upsert --domain=example.com --action=skip --expression='ip.src eq 1.2.3.4' --description='allow office' --json --quiet
  assert_json '.action_result == "unchanged"'
  octo firewall upsert --domain=example.com --action=skip --expression='ip.src eq 1.2.3.4' --description='allow office' --no-log --json --quiet
  assert_json '.action_result == "updated" and .logging == {"enabled":false}'
  mock_log | jq -e '.[-1] | .method == "PATCH" and .body.logging == {"enabled":false}' >/dev/null
}

@test "pagerule upsert keeps the existing priority and status unless given" {
  octo pagerule upsert --domain=example.com --url='a.example.com/*' --cache-level=cache_everything --json --quiet
  assert_json '.action_result == "created"'
  mock_log | jq -e '.[-1] | .method == "POST" and (.body | has("priority") | not) and (.body | has("status") | not)' >/dev/null
  id="$(printf '%s' "$output" | jq -r .id)"
  # Cloudflare renumbers priorities when rules are inserted; simulate that and a disabled rule
  octo pagerule update --domain=example.com --id="$id" --priority=2 --status=disabled --json --quiet
  assert_json '.priority == 2 and .status == "disabled"'
  octo pagerule upsert --domain=example.com --url='a.example.com/*' --cache-level=cache_everything --json --quiet
  assert_json '.action_result == "unchanged" and .priority == 2 and .status == "disabled"'
  octo pagerule upsert --domain=example.com --url='a.example.com/*' --cache-level=bypass --json --quiet
  assert_json '.action_result == "updated" and .priority == 2 and .status == "disabled" and .actions[0].value == "bypass"'
  mock_log | jq -e '.[-1] | .method == "PUT" and .body.priority == 2 and .body.status == "disabled"' >/dev/null
  octo pagerule upsert --domain=example.com --url='a.example.com/*' --cache-level=bypass --priority=1 --json --quiet
  assert_json '.action_result == "updated" and .priority == 1 and .status == "disabled"'
  octo pagerule upsert --domain=example.com --url='a.example.com/*' --cache-level=bypass --status=active --json --quiet
  assert_json '.action_result == "updated" and .priority == 1 and .status == "active"'
  octo pagerule create --domain=example.com --url='b.example.com/*' --cache-level=bypass --priority=3 --status=disabled --json --quiet
  assert_json '.priority == 3 and .status == "disabled"'
}

@test "pagerule delete/get by a missing --id honour --if-exists and report not found" {
  octo pagerule delete --domain=example.com --id=deadbeef --if-exists --yes --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to delete"* ]]
  octo pagerule delete --domain=example.com --id=deadbeef --yes
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"No Page Rule found for deadbeef"* ]]
  octo pagerule get --domain=example.com --id=deadbeef
  [ "$status" -eq 5 ]
  octo pagerule create --domain=example.com --url='a.example.com/*' --cache-level=bypass --json --quiet
  id="$(printf '%s' "$output" | jq -r .id)"
  octo pagerule get --domain=example.com --id="$id" --field=.id
  [ "$output" = "$id" ]
  octo pagerule delete --domain=example.com --id="$id" --yes --json
  [ "$status" -eq 0 ]
}

@test "access-rule upsert/delete ignore account-wide rules in the zone listing" {
  run --separate-stderr bash -c '
    source "$OCTOFLARE_ROOT/src/lib/core.sh" 2>/dev/null
    source "$OCTOFLARE_ROOT/src/lib/api.sh"
    source "$OCTOFLARE_ROOT/src/lib/security.sh"
    CF_RESPONSE="{\"result\":[{\"id\":\"acc1\",\"mode\":\"block\",\"scope\":{\"type\":\"organization\"}},{\"id\":\"z1\",\"mode\":\"challenge\",\"scope\":{\"type\":\"zone\"}}]}"
    printf "%s|" "$(accessRuleMatch | jq -r .id)"
    CF_RESPONSE="{\"result\":[{\"id\":\"acc1\",\"mode\":\"block\",\"scope\":{\"type\":\"organization\"}}]}"
    printf "%s|" "$(accessRuleMatch | jq -r .id)"
    OPT_scope=account
    printf "%s" "$(accessRuleMatch | jq -r .id)"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "z1||acc1" ]
  octo access-rule block --domain=example.com --value=203.0.113.0/24 --json --quiet
  assert_json '.scope.type == "zone"'
  octo access-rule block --domain=example.com --value=203.0.113.0/24 --json --quiet
  assert_json '.action == "unchanged"'
  octo access-rule delete --domain=example.com --value=203.0.113.0/24 --json
  [ "$status" -eq 0 ]
}
