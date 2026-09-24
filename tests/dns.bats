#!/usr/bin/env bats
# DNS records against the mock API

load helpers

setup() { setup_env; }

@test "dns create sends the right body and returns the record" {
  octo dns create --domain=example.com --name=www --type=a --content=203.0.113.10 --proxied --ttl=auto --comment="hello world" --tags=a,b --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.type == "A" and .name == "www.example.com" and .content == "203.0.113.10" and .proxied == true and .ttl == 1 and .comment == "hello world" and .tags == ["a","b"]'
  mock_log | jq -e '.[-1].body == {"type":"A","name":"www.example.com","content":"203.0.113.10","ttl":1,"proxied":true,"comment":"hello world","tags":["a","b"]}' >/dev/null
}

@test "dns create requires type, name and content" {
  octo dns create --domain=example.com --name=www --type=A
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--content"* ]]
  octo dns create --domain=example.com --type=A --content=1.2.3.4
  [ "$status" -eq 3 ]
}

@test "apex, relative and absolute names are normalised" {
  octo dns create --domain=example.com --name=@ --type=A --content=203.0.113.1 --field=.name
  [ "$output" = "example.com" ]
  octo dns create --domain=example.com --name=api.example.com --type=A --content=203.0.113.2 --field=.name
  [ "$output" = "api.example.com" ]
  octo dns create --domain=example.com --name=deep.sub --type=A --content=203.0.113.3 --field=.name
  [ "$output" = "deep.sub.example.com" ]
}

@test "dns list filters by type and name" {
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --quiet
  octo dns create --domain=example.com --name=www --type=AAAA --content=2001:db8::1 --quiet
  octo dns create --domain=example.com --name=mail --type=A --content=203.0.113.2 --quiet
  octo dns list --domain=example.com --json --quiet
  assert_json 'length == 3'
  octo dns list --domain=example.com --type=A --json --quiet
  assert_json 'length == 2'
  octo dns list --domain=example.com --name=www --json --quiet
  assert_json 'length == 2 and all(.name == "www.example.com")'
  octo dns list --domain=example.com
  [[ "$output" == *"A	www.example.com	203.0.113.1"* ]]
}

@test "dns get finds a record by name and type" {
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --quiet
  octo dns get --domain=example.com --name=www --type=A --json --quiet
  assert_json '.content == "203.0.113.1"'
  octo dns get --domain=example.com --name=missing
  [ "$status" -eq 5 ]
}

@test "dns get with several matches asks to narrow down" {
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --quiet
  octo dns create --domain=example.com --name=www --type=AAAA --content=2001:db8::1 --quiet
  octo dns get --domain=example.com --name=www
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"Found 2 records"* ]]
}

@test "dns upsert creates, then reports unchanged, then updates in place" {
  octo dns upsert --domain=example.com --name=www --type=A --content=203.0.113.1 --proxied --json --quiet
  assert_json '.action == "created"'
  id="$(printf '%s' "$output" | jq -r .id)"
  octo dns upsert --domain=example.com --name=www --type=A --content=203.0.113.1 --proxied --json --quiet
  assert_json '.action == "unchanged"'
  [ "$(mock_requests | grep -c 'POST\|PATCH')" -eq 1 ]
  octo dns upsert --domain=example.com --name=www --type=A --content=203.0.113.2 --proxied --json --quiet
  assert_json ".action == \"updated\" and .id == \"$id\" and .content == \"203.0.113.2\""
  mock_requests | grep -q "PATCH /client/v4/zones/zone123/dns_records/$id"
  octo dns list --domain=example.com --json --quiet
  assert_json 'length == 1'
}

@test "dns set is an alias of upsert" {
  octo dns set --domain=example.com --name=www --type=CNAME --content=target.example.net --json --quiet
  assert_json '.action == "created" and .type == "CNAME"'
}

@test "dns upsert with several records of the same name needs --replace" {
  octo dns create --domain=example.com --name=@ --type=MX --content=mx1.example.com --priority=10 --quiet
  octo dns create --domain=example.com --name=@ --type=MX --content=mx2.example.com --priority=20 --quiet
  octo dns upsert --domain=example.com --name=@ --type=MX --content=mx3.example.com --priority=5
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--replace"* ]]
  octo dns upsert --domain=example.com --name=@ --type=MX --content=mx3.example.com --priority=5 --replace --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.action == "updated" and .content == "mx3.example.com"'
  octo dns list --domain=example.com --type=MX --json --quiet
  assert_json 'length == 1'
}

@test "dns upsert with the same content among duplicates is unchanged" {
  octo dns create --domain=example.com --name=@ --type=TXT --content=one --quiet
  octo dns create --domain=example.com --name=@ --type=TXT --content=two --quiet
  octo dns upsert --domain=example.com --name=@ --type=TXT --content=two --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.action == "unchanged"'
}

@test "dns update patches by id or by name" {
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --json --quiet
  id="$(printf '%s' "$output" | jq -r .id)"
  octo dns update --domain=example.com --id="$id" --content=203.0.113.9 --ttl=300 --json --quiet
  assert_json '.content == "203.0.113.9" and .ttl == 300'
  mock_log | jq -e '.[-1].body == {"content":"203.0.113.9","ttl":300}' >/dev/null
  octo dns update --domain=example.com --name=www --type=A --new-name=web --json --quiet
  assert_json '.name == "web.example.com"'
  octo dns update --domain=example.com --id="$id"
  [ "$status" -eq 3 ]
}

@test "dns delete by name, by id and with --all" {
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --json --quiet
  id="$(printf '%s' "$output" | jq -r .id)"
  octo dns create --domain=example.com --name=www --type=AAAA --content=2001:db8::1 --quiet
  octo dns delete --domain=example.com --name=www
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--all"* ]]
  octo dns delete --domain=example.com --id="$id" --json
  [ "$status" -eq 0 ]
  assert_json '.deleted == 1'
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --quiet
  octo dns delete --domain=example.com --name=www --all --json
  assert_json '.deleted == 2'
  octo dns list --domain=example.com --json --quiet
  assert_json 'length == 0'
  octo dns delete --domain=example.com --name=www
  [ "$status" -eq 5 ]
  octo dns delete --domain=example.com --name=www --if-exists
  [ "$status" -eq 0 ]
}

@test "dns delete asks for confirmation when interactive prompts are impossible" {
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --quiet
  OCTOFLARE_UNATTENDED=false octo dns delete --domain=example.com --name=www </dev/null
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--yes"* ]]
  OCTOFLARE_UNATTENDED=false octo dns delete --domain=example.com --name=www --yes </dev/null
  [ "$status" -eq 0 ]
}

@test "SRV and CAA records use structured data" {
  octo dns create --domain=example.com --name=_sip._tcp --type=SRV --port=5060 --priority=10 --weight=5 --target=sip.example.com --json --quiet
  assert_json '.data == {"priority":10,"weight":5,"port":5060,"target":"sip.example.com"} and (.content == null)'
  octo dns create --domain=example.com --name=@ --type=CAA --tag=issue --value=letsencrypt.org --json --quiet
  assert_json '.data == {"flags":0,"tag":"issue","value":"letsencrypt.org"}'
  octo dns create --domain=example.com --name=x --type=TXT --data='{"custom":true}' --json --quiet
  assert_json '.data.custom == true'
}

@test "dns export prints the zone file or writes it to a file" {
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1 --quiet
  octo dns export --domain=example.com --quiet
  [[ "$output" == *";; Zone file for example.com"* ]]
  [[ "$output" == *"www.example.com."* ]]
  octo dns export --domain=example.com --file=zone.txt --quiet
  grep -q 'www.example.com' zone.txt
  octo dns export --domain=example.com --json --quiet
  assert_json '.zone == "example.com" and (.bind | contains("www.example.com"))'
}

@test "dns import posts the file as multipart" {
  printf 'www 300 IN A 203.0.113.1\n' > zone.txt
  octo dns import --domain=example.com --file=zone.txt --proxied --json --quiet
  [ "$status" -eq 0 ]
  assert_json '.recs_added == 2'
  mock_log | jq -e '.[-1] | .path == "/client/v4/zones/zone123/dns_records/import" and (.headers["content-type"] | startswith("multipart/form-data"))' >/dev/null
  octo dns import --domain=example.com --file=missing.txt
  [ "$status" -eq 3 ]
}

@test "dns batch sends posts, patches and deletes in one request" {
  octo dns create --domain=example.com --name=old --type=A --content=203.0.113.1 --json --quiet
  id="$(printf '%s' "$output" | jq -r .id)"
  printf '{"posts":[{"type":"A","name":"new.example.com","content":"203.0.113.2"}],"deletes":[{"id":"%s"}]}' "$id" > batch.json
  octo dns batch --domain=example.com --file=batch.json --json --quiet
  [ "$status" -eq 0 ]
  assert_json '(.posts | length) == 1 and (.deletes | length) == 1'
  octo dns list --domain=example.com --json --quiet
  assert_json 'length == 1 and .[0].name == "new.example.com"'
}

@test "API validation errors are reported with code and message" {
  octo dns create --domain=example.com --name=www --type=CNAME --content=a.example.net --quiet
  octo dns create --domain=example.com --name=www --type=A --content=203.0.113.1
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"[81053] A CNAME record with that host already exists"* ]]
}
