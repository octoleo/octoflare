#!/usr/bin/env bats
# Review fixes: Workers, KV, Pages, Tunnel

load helpers

setup() {
  setup_env
  export CLOUDFLARE_ACCOUNT_ID=acc123
}

# restricted_path - a PATH with the basic tools but without the given commands
restricted_path() {
  mkdir -p "$BATS_TEST_TMPDIR/pathbin"
  local tool p
  for tool in bash curl jq sed awk grep tr cat mkdir cut wc date head tail sort uniq mv rm cp chmod id uname readlink dirname basename mktemp env printf ls stat; do
    p="$(command -v "$tool" || true)"
    [ -n "$p" ] && ln -sf "$p" "$BATS_TEST_TMPDIR/pathbin/$tool"
  done
  printf '%s' "$BATS_TEST_TMPDIR/pathbin"
}

@test "workers upload keeps secrets (and vars/KV unless given) and sends the metadata from a file" {
  fake_curl
  printf 'export default { fetch() { return new Response("ok") } }\n' > worker.js
  octo workers upload --name=my-worker --file=worker.js --json --quiet
  [ "$status" -eq 0 ]
  jq -e '.keep_bindings == ["secret_text","secret_key","plain_text","json","kv_namespace"] and .main_module == "worker.js"' "$FAKE_CURL_DIR/form-metadata" >/dev/null
  grep -q '^metadata=<' "$FAKE_CURL_DIR/argv"
  ! grep -q 'keep_bindings' "$FAKE_CURL_DIR/argv"
  octo workers upload --name=my-worker --file=worker.js --vars='{"A":"x;y"}' --kv=CONF=0123456789abcdef0123456789abcdef --json --quiet
  [ "$status" -eq 0 ]
  jq -e '.keep_bindings == ["secret_text","secret_key"] and (.bindings | map(.name)) == ["CONF","A"] and .bindings[1].text == "x;y"' "$FAKE_CURL_DIR/form-metadata" >/dev/null
}

@test "workers download unwraps a multipart ES module response" {
  fake_curl
  printf -- '--boundary42\r\nContent-Disposition: form-data; name="worker.js"; filename="worker.js"\r\nContent-Type: application/javascript+module\r\n\r\nexport default { fetch() { return new Response("hi") } }\r\n--boundary42--\r\n' > "$FAKE_CURL_DIR/responses/scripts.json"
  octo workers download --name=my-worker --quiet
  [ "$status" -eq 0 ]
  [ "$output" = 'export default { fetch() { return new Response("hi") } }' ]
  octo workers download --name=my-worker --raw --quiet
  [[ "$output" == --boundary42* ]]
}

@test "workers subdomain rejects values that are not on/off" {
  octo workers subdomain --name=my-worker onn --dry-run
  [ "$status" -eq 3 ]
  octo workers subdomain --name=my-worker off --dry-run --json
  [ "$status" -eq 0 ]
}

@test "kv put uploads values from files, binary-safe, never on the command line" {
  fake_curl
  octo kv put --namespace=0123456789abcdef0123456789abcdef --key=greeting --value='hello; <world>' --json --quiet
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_CURL_DIR/body")" = 'hello; <world>' ]
  ! grep -q 'hello; <world>' "$FAKE_CURL_DIR/argv"
  grep -q '^Content-Type: application/octet-stream$' "$FAKE_CURL_DIR/argv"
  printf 'a\0b\n\n' > blob.bin
  octo kv put --namespace=0123456789abcdef0123456789abcdef --key=blob --file=blob.bin --json --quiet
  [ "$status" -eq 0 ]
  cmp -s blob.bin "$FAKE_CURL_DIR/body"
  octo kv put --namespace=0123456789abcdef0123456789abcdef --key=meta --value='<v;x' --metadata='{"k":"a;b"}' --json --quiet
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_CURL_DIR/form-value")" = '<v;x' ]
  jq -e '.k == "a;b"' "$FAKE_CURL_DIR/form-metadata" >/dev/null
  octo kv put --namespace=0123456789abcdef0123456789abcdef --key=none --file=missing.bin
  [ "$status" -eq 3 ]
}

@test "kv namespace titles are resolved without the caller's --limit" {
  octo kv keys --namespace=MyNamespace --limit=1 --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"/storage/kv/namespaces?page=1&per_page=50"* ]]
}

@test "pages deployments filters with --environment (not the env-file option)" {
  octo pages deployments --project=site --environment=production --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"/pages/projects/site/deployments?env=production&page=1"* ]]
  # --env is accepted as an alias because the command declares it (see review_bootstrap.bats)
  octo pages deployments --project=site --env=preview --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"/pages/projects/site/deployments?env=preview&page=1"* ]]
}

@test "pages deploy --dir: dry run needs no wrangler, unattended runs do not auto-install" {
  mkdir -p dist
  local p; p="$(restricted_path)"
  PATH="$p" octo pages deploy --project=site --dir=dist --dry-run --json
  [ "$status" -eq 0 ]
  assert_json '.message | contains("wrangler pages deploy dist --project-name=site")'
  PATH="$p" octo pages deploy --project=site --dir=dist --json
  [ "$status" -eq 69 ]
  [[ "$stderr" == *"--install-wrangler"* ]]
  [[ "$stderr" == *"wrangler@4"* ]]
}

@test "tunnel create masks the secret and does not print it" {
  export GITHUB_ACTIONS=true
  octo tunnel create --name=home --secret=c2VjcmV0 --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"::add-mask::c2VjcmV0"* ]]
  assert_json 'has("tunnel_secret") | not'
}

@test "tunnel route keeps the existing configuration and replaces only the same hostname and path" {
  fake_curl
  printf '{"success":true,"errors":[],"messages":[],"result":{"config":{"originRequest":{"connectTimeout":30},"warp-routing":{"enabled":true},"ingress":[{"hostname":"app.example.com","path":"/api","service":"http://localhost:9000"},{"hostname":"app.example.com","service":"http://localhost:8080"},{"hostname":"other.example.com","service":"http://localhost:7000","originRequest":{"noTLSVerify":true}},{"service":"http_status:404"}]}}}' > "$FAKE_CURL_DIR/responses/configurations.json"
  octo tunnel route --id=tun1 --hostname=app.example.com --service=http://localhost:8081 --zone-id=zone123 --domain=example.com --json --quiet
  [ "$status" -eq 0 ]
  local n put_body
  n="$(grep -l 'configurations' "$FAKE_CURL_DIR"/argv.* | while read -r f; do grep -q '^PUT$' "$f" && echo "${f##*.}"; done | head -n1)"
  [ -n "$n" ]
  put_body="$FAKE_CURL_DIR/body.$n"
  jq -e '.config.originRequest.connectTimeout == 30 and .config["warp-routing"].enabled == true' "$put_body" >/dev/null
  jq -e '[.config.ingress[] | select(.hostname == "app.example.com")] | length == 2' "$put_body" >/dev/null
  jq -e '.config.ingress | map(select(.hostname == "app.example.com" and (.path // "") == "")) | .[0].service == "http://localhost:8081"' "$put_body" >/dev/null
  jq -e '.config.ingress | map(select(.path == "/api")) | .[0].service == "http://localhost:9000"' "$put_body" >/dev/null
  jq -e '.config.ingress | map(select(.hostname == "other.example.com")) | .[0].originRequest.noTLSVerify == true' "$put_body" >/dev/null
  jq -e '.config.ingress[-1] == {"service":"http_status:404"} and ([.config.ingress[] | select(.service == "http_status:404")] | length) == 1' "$put_body" >/dev/null
}
