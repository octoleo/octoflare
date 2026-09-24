#!/usr/bin/env bats
# Request shapes of the account-level modules, verified in --dry-run mode
# (the mock API does not implement these endpoints; dry-run reports the
# exact method, URL and body that would be sent).

load helpers

setup() {
  setup_env
  export OCTOFLARE_DRY_RUN=true
  export CLOUDFLARE_ACCOUNT_ID=acc123
}

# request N - the Nth "[dry-run] METHOD URL BODY" line from $stderr (1-based)
request() {
  printf '%s\n' "$stderr" | grep '\[dry-run\] ' | sed -n "${1}p" | sed 's/^.*\[dry-run\] //'
}

@test "workers upload sends multipart metadata with bindings" {
  printf 'export default { fetch() { return new Response("ok") } }\n' > worker.js
  octo workers upload --name=my-worker --file=worker.js --kv=CONFIG=0123456789abcdef0123456789abcdef --vars='{"ENV":"prod"}' --compatibility-date=2025-01-01 --json
  [ "$status" -eq 0 ]
  [[ "$(request 1)" == "PUT ${CLOUDFLARE_API_BASE}/accounts/acc123/workers/scripts/my-worker" ]]
  [[ "$stderr" == *"ES module"* ]]
}

@test "workers secret-set reads the value from the environment" {
  MY_SECRET=s3cret octo workers secret-set --name=my-worker --secret-name=API_KEY --from-env=MY_SECRET --json
  [ "$status" -eq 0 ]
  [[ "$(request 1)" == "PUT ${CLOUDFLARE_API_BASE}/accounts/acc123/workers/scripts/my-worker/secrets {\"name\":\"API_KEY\",\"text\":\"s3cret\",\"type\":\"secret_text\"}" ]]
}

@test "workers schedules and subdomain" {
  octo workers schedules --name=my-worker --crons='*/5 * * * *,0 0 * * *' --json
  [[ "$(request 1)" == *'/workers/scripts/my-worker/schedules [{"cron":"*/5 * * * *"},{"cron":"0 0 * * *"}]' ]]
  octo workers subdomain --name=my-worker on --json
  [[ "$(request 1)" == *'/workers/scripts/my-worker/subdomain {"enabled":true,"previews_enabled":true}' ]]
}

@test "workers routes are zone scoped" {
  octo workers route-create --domain=example.com --pattern='example.com/api/*' --script=my-worker --json
  [[ "$(request 2)" == "POST ${CLOUDFLARE_API_BASE}/zones/dry-run-zone-id/workers/routes {\"pattern\":\"example.com/api/*\",\"script\":\"my-worker\"}" ]]
}

@test "kv put targets the key with a ttl (the value travels in a file, see review_workers.bats)" {
  octo kv put --namespace=0123456789abcdef0123456789abcdef --key='my key' --value=hello --ttl=60 --json
  [ "$status" -eq 0 ]
  [[ "$(request 1)" == "PUT ${CLOUDFLARE_API_BASE}/accounts/acc123/storage/kv/namespaces/0123456789abcdef0123456789abcdef/values/my%20key?expiration_ttl=60" ]]
}

@test "kv bulk-put reads --file" {
  printf '[{"key":"a","value":"1"}]' > items.json
  octo kv bulk-put --namespace=0123456789abcdef0123456789abcdef --file=items.json --json
  [[ "$(request 1)" == *'/bulk [{"key":"a","value":"1"}]' ]]
  octo kv bulk-put --namespace=0123456789abcdef0123456789abcdef --file=missing.json
  [ "$status" -eq 3 ]
}

@test "pages deploy triggers a build for a branch" {
  octo pages deploy --project=my-site --branch=main --json
  [[ "$(request 1)" == "POST ${CLOUDFLARE_API_BASE}/accounts/acc123/pages/projects/my-site/deployments" ]]
}

@test "pages domain-add --dns creates the CNAME through dns upsert" {
  octo pages domain-add --project=my-site --name=www.example.com --dns --json
  [ "$status" -eq 0 ]
  assert_json '.type == "CNAME" and .name == "www.example.com" and .content == "my-site.pages.dev" and .proxied == true'
  [[ "$(request 1)" == "POST ${CLOUDFLARE_API_BASE}/accounts/acc123/pages/projects/my-site/domains {\"name\":\"www.example.com\"}" ]]
}

@test "tunnel create, config-set and route" {
  octo tunnel create --name=home --json
  [[ "$(request 1)" == "POST ${CLOUDFLARE_API_BASE}/accounts/acc123/cfd_tunnel {\"name\":\"home\",\"config_src\":\"cloudflare\"}" ]]
  octo tunnel config-set --id=tun1 --ingress=app.example.com=http://localhost:8080,ssh.example.com=ssh://localhost:22 --json
  [[ "$(request 1)" == *'/cfd_tunnel/tun1/configurations {"config":{"ingress":[{"hostname":"app.example.com","service":"http://localhost:8080"},{"hostname":"ssh.example.com","service":"ssh://localhost:22"},{"service":"http_status:404"}]}}' ]]
  octo tunnel route --id=tun1 --hostname=app.example.com --service=http://localhost:8080 --json
  [ "$status" -eq 0 ]
  assert_json '.type == "CNAME" and .content == "tun1.cfargotunnel.com" and .proxied == true'
}

@test "email routing rules and addresses" {
  octo email rule-create --domain=example.com --to=hello --forward=me@gmail.com --json
  [[ "$(request 2)" == *'/email/routing/rules {"name":"Route hello@example.com","enabled":true,"priority":0,"matchers":[{"type":"literal","field":"to","value":"hello@example.com"}],"actions":[{"type":"forward","value":["me@gmail.com"]}]}' ]]
  octo email catch-all --domain=example.com --drop --json
  [[ "$(request 2)" == *'/email/routing/rules/catch_all {"name":"Catch-all","enabled":true,"matchers":[{"type":"all"}],"actions":[{"type":"drop"}]}' ]]
  octo email address-add --email=me@gmail.com --json
  [[ "$(request 1)" == *'/accounts/acc123/email/routing/addresses {"email":"me@gmail.com"}' ]]
}

@test "turnstile create and rotate-secret" {
  octo turnstile create --name=Login --domains=example.com,www.example.com --mode=invisible --json
  [[ "$(request 1)" == *'/challenges/widgets {"name":"Login","domains":["example.com","www.example.com"],"mode":"invisible","bot_fight_mode":false,"region":"world"}' ]]
  octo turnstile rotate-secret --sitekey=0x123 --invalidate-immediately --json
  [[ "$(request 1)" == *'/challenges/widgets/0x123/rotate_secret {"invalidate_immediately":true}' ]]
}

@test "r2 bucket, custom domain and public access" {
  octo r2 create --bucket=assets --location=weur --json
  [[ "$(request 1)" == *'/r2/buckets {"name":"assets","locationHint":"weur"}' ]]
  octo r2 domain-add --bucket=assets --name=cdn.example.com --json
  [[ "$(request 2)" == *'/r2/buckets/assets/domains/custom {"domain":"cdn.example.com","zoneId":"dry-run-zone-id","enabled":true,"minTLS":"1.2"}' ]]
  octo r2 public --bucket=assets off --json
  [[ "$(request 1)" == *'/r2/buckets/assets/domains/managed {"enabled":false}' ]]
}

@test "account lists and bulk redirects" {
  octo list create --name=blocked --kind=ip --json
  [[ "$(request 1)" == *'/rules/lists {"name":"blocked","kind":"ip","description":"Created by Octoflare"}' ]]
  octo bulk-redirect add --list=legacy --from=https://old.example.com/a --to=https://example.com/b --status=302 --preserve-query --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *'/rules/lists {"name":"legacy","kind":"redirect"'* ]]
  [[ "$stderr" == *'"redirect":{"source_url":"https://old.example.com/a","target_url":"https://example.com/b","status_code":302,"include_subdomains":false,"subpath_matching":false,"preserve_query_string":true,"preserve_path_suffix":false}'* ]]
  octo bulk-redirect enable --list=legacy --json
  [ "$status" -eq 0 ]
  assert_json '.action == "redirect" and .action_parameters.from_list.name == "legacy" and .expression == "http.request.full_uri in $legacy"'
  [[ "$stderr" == *'/accounts/acc123/rulesets {"name":"Octoflare http_request_redirect","kind":"root","phase":"http_request_redirect"'* ]]
}

@test "ssl origin-cert-create generates a key and CSR with openssl" {
  command -v openssl >/dev/null || skip "openssl not installed"
  octo ssl origin-cert-create --hostnames=example.com,*.example.com --key-out=origin.key --json
  [ "$status" -eq 0 ]
  [ -s origin.key ]
  [[ "$(request 1)" == "POST ${CLOUDFLARE_API_BASE}/certificates {\"csr\":\"-----BEGIN CERTIFICATE REQUEST-----"* ]]
  [[ "$(request 1)" == *'"hostnames":["example.com","*.example.com"],"request_type":"origin-rsa","requested_validity":5475}' ]]
}

@test "analytics zone sends a GraphQL query for the zone" {
  octo analytics zone --domain=example.com --days=3 --json
  [ "$status" -eq 0 ]
  [[ "$(request 2)" == "POST ${CLOUDFLARE_API_BASE}/graphql {\"query\":\"query (\$zoneTag: String!, \$since: Date!, \$until: Date!)"* ]]
  [[ "$(request 2)" == *'"variables":{"zoneTag":"dry-run-zone-id","since":"'* ]]
}

@test "dry-run runs need no real zone or account" {
  unset CLOUDFLARE_ACCOUNT_ID
  octo workers list --json
  [ "$status" -eq 0 ]
  [[ "$(request 1)" == "GET ${CLOUDFLARE_API_BASE}/accounts?per_page=50" ]]
  [[ "$(request 2)" == "GET ${CLOUDFLARE_API_BASE}/accounts/dry-run-account-id/workers/scripts" ]]
}
