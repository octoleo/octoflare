#!/usr/bin/env bash
# Octoflare module: dns
#
# DNS record management with idempotent upsert, lookup by name, BIND
# export/import and batch operations. Record names may be relative (www),
# the apex (@) or fully qualified (www.example.com). When no --domain is
# given the zone is derived from the record's FQDN.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand dns list "--domain=<zone> [--type=A] [--name=<name>] [--content=<v>] [--proxied=true|false] [--search=<text>] [--tag=<tag>]" "List DNS records"
registerCommand dns get "--name=<name> [--type=<type>] | --id=<record-id>" "Show one DNS record"
registerCommand dns create "--name=<name> --type=<type> --content=<value> [--ttl=auto] [--proxied] [--priority=<n>] [--comment=<text>] [--tags=a,b]" "Create a DNS record"
registerCommand dns update "(--id=<record-id> | --name=<name> [--type=<type>]) [--content=] [--ttl=] [--proxied=] [--priority=] [--comment=] [--tags=] [--new-name=]" "Update an existing record"
registerCommand dns upsert "--name=<name> --type=<type> --content=<value> [--ttl=auto] [--proxied] [--replace]" "Create the record or update it in place (idempotent)"
registerCommand dns set "--name=<name> --type=<type> --content=<value> [--ttl=auto] [--proxied]" "Alias of upsert: set a record to the given value"
registerCommand dns delete "(--id=<record-id> | --name=<name> [--type=<type>] [--content=<v>]) [--all] [--yes]" "Delete record(s)"
registerCommand dns export "--domain=<zone> [--file=<path>]" "Export the zone file (BIND format)"
registerCommand dns import "--domain=<zone> --file=<zonefile> [--proxied]" "Import a BIND zone file"
registerCommand dns batch "--domain=<zone> --file=<batch.json>" "Run a batch of posts/patches/puts/deletes in one request"
registerCommand dns types "" "List supported record types"

DNS_LIST_TEMPLATE='.[] | "\(.type)\t\(.name)\t\(.content // (.data|tostring))\tttl=\(.ttl)\tproxied=\(.proxied // false)\tid=\(.id)"'
DNS_TEMPLATE='"id=\(.id)\ntype=\(.type)\nname=\(.name)\ncontent=\(.content // (.data|tostring))\nttl=\(.ttl)\nproxied=\(.proxied // false)\npriority=\(.priority // "-")\ncomment=\(.comment // "-")\ntags=\((.tags // []) | join(","))\nmodified_on=\(.modified_on // "-")"'

# dnsType - Normalised record type from --type (uppercase)
dnsType() {
  printf '%s' "$(opt type)" | tr '[:lower:]' '[:upper:]'
}

# dnsTtl - Normalised ttl (auto -> 1)
dnsTtl() {
  local ttl="$1"
  case "$(lower "$ttl")" in
    ""|auto|automatic) echo 1 ;;
    *) echo "$ttl" ;;
  esac
}

# dnsRecordBody - Build the JSON body for a create/update from the options
#
# Arguments:
#   $1: "create" (include defaults) or "update" (only provided fields)
dnsRecordBody() {
  local mode="$1" type name content ttl body data
  type="$(dnsType)"
  name="$(optFirst "" name hostname record)"
  content="$(optFirst "" content value target ip)"
  body='{}'
  [[ -n "$type" ]] && body="$(jq -cn --argjson b "$body" --arg v "$type" '$b + {type:$v}')"
  if [[ -n "$(opt new-name)" ]]; then
    body="$(jq -cn --argjson b "$body" --arg v "$(recordFqdn "$(opt new-name)")" '$b + {name:$v}')"
  elif [[ -n "$name" ]]; then
    body="$(jq -cn --argjson b "$body" --arg v "$(recordFqdn "$name")" '$b + {name:$v}')"
  fi
  [[ -n "$content" ]] && body="$(jq -cn --argjson b "$body" --arg v "$content" '$b + {content:$v}')"
  if hasOpt ttl || [[ "$mode" == "create" ]]; then
    ttl="$(dnsTtl "$(opt ttl auto)")"
    body="$(jq -cn --argjson b "$body" --argjson v "$ttl" '$b + {ttl:$v}')"
  fi
  if hasOpt proxied || [[ "$mode" == "create" ]]; then
    body="$(jq -cn --argjson b "$body" --argjson v "$(optBool proxied false)" '$b + {proxied:$v}')"
  fi
  hasOpt priority && body="$(jq -cn --argjson b "$body" --argjson v "$(opt priority)" '$b + {priority:$v}')"
  hasOpt comment && body="$(jq -cn --argjson b "$body" --arg v "$(opt comment)" '$b + {comment:$v}')"
  hasOpt tags && body="$(jq -cn --argjson b "$body" --argjson v "$(toJsonArray "$(opt tags)")" '$b + {tags:$v}')"
  # structured records
  if hasOpt data; then
    data="$(readFileOrValue "$(opt data)")"
    body="$(jq -cn --argjson b "$body" --argjson v "$data" '$b + {data:$v}')"
  elif [[ "$type" == "SRV" && -n "$(opt port)" ]]; then
    data="$(jq -cn --argjson p "$(opt priority 0)" --argjson w "$(opt weight 0)" --argjson port "$(opt port)" --arg t "$(optFirst "" srv-target target content)" '{priority:$p, weight:$w, port:$port, target:$t}')"
    body="$(jq -cn --argjson b "$body" --argjson v "$data" '$b + {data:$v} | del(.content)')"
  elif [[ "$type" == "CAA" && -n "$(opt tag)" ]]; then
    data="$(jq -cn --argjson f "$(opt flags 0)" --arg tag "$(opt tag)" --arg v "$(optFirst "" caa-value value content)" '{flags:$f, tag:$tag, value:$v}')"
    body="$(jq -cn --argjson b "$body" --argjson v "$data" '$b + {data:$v} | del(.content)')"
  fi
  if [[ "$type" == "CNAME" && "$(optBool flatten)" == "true" ]]; then
    body="$(jq -cn --argjson b "$body" '$b + {settings:{flatten_cname:true}}')"
  fi
  printf '%s' "$body"
}

# dnsFind - Find records by name (+type, +content); result array in CF_RESPONSE
#
# Arguments:
#   $1: name (relative or FQDN)
#   $2: type (optional)
#   $3: content (optional)
dnsFind() {
  local fqdn query
  fqdn="$(recordFqdn "$1")"
  query="$(cfQuery "name=${fqdn}" "type=${2:-}" "content=${3:-}")"
  cfApiList "/zones/${CF_ZONE_ID}/dns_records" "$query"
}

# dnsRecordById - Load a record by id into CF_RESPONSE
dnsRecordById() {
  cfApi GET "/zones/${CF_ZONE_ID}/dns_records/$1"
}

# dnsSelectRecord - Resolve --id or --name/--type to exactly one record id (prints id)
dnsSelectRecord() {
  local id name count
  id="$(opt id)"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return 0
  fi
  name="$(optFirst "" name hostname record)"
  [[ -z "$name" ]] && die "Specify the record with --id=<record-id> or --name=<name> [--type=<type>]" "$EX_ARGS"
  dnsFind "$name" "$(dnsType)" "$(opt match-content)"
  count="$(cfResultRaw '.result | length')"
  if [[ "$count" == "0" ]]; then
    [[ "$OCTOFLARE_DRY_RUN" == "true" ]] && { printf 'dry-run-record-id'; return 0; }
    die "No DNS record found for $(recordFqdn "$name")${OPT_type:+ (type $(dnsType))}" "$EX_NOTFOUND"
  fi
  if [[ "$count" != "1" ]]; then
    logError "Found ${count} records for $(recordFqdn "$name"); narrow it down with --type=<type>, --match-content=<value> or --id=<record-id>:"
    cfResultRaw "$DNS_LIST_TEMPLATE | \"  \" + ." >&2
    exit "$EX_ARGS"
  fi
  cfResultRaw '.result[0].id'
}

cmd_dns_list() {
  resolveZone
  local query name
  name="$(optFirst "" name hostname record)"
  [[ -n "$name" ]] && name="$(recordFqdn "$name")"
  query="$(cfQuery "name=${name}" "type=$(dnsType)" "content=$(optFirst "" content value)" "proxied=$(opt proxied)" "search=$(opt search)" "tag=$(opt tag)" "comment=$(opt comment)" "order=$(opt order)" "direction=$(opt direction)")"
  cfApiList "/zones/${CF_ZONE_ID}/dns_records" "$query"
  emitResult "$(cfResult)" "$DNS_LIST_TEMPLATE" "No DNS records found."
}

cmd_dns_get() {
  resolveZone
  local id
  id="$(dnsSelectRecord)" || exit $?
  dnsRecordById "$id"
  emitResult "$(cfResult)" "$DNS_TEMPLATE"
}

cmd_dns_create() {
  resolveZone
  requireOpt type
  [[ -z "$(optFirst "" name hostname record)" ]] && die "Missing required option --name=<name>" "$EX_ARGS"
  local body
  body="$(dnsRecordBody create)"
  if [[ "$(printf '%s' "$body" | jq 'has("content") or has("data")')" != "true" ]]; then
    die "Missing required option --content=<value>" "$EX_ARGS"
  fi
  logInfo "Creating $(dnsType) record $(printf '%s' "$body" | jq -r '.name') in ${CF_ZONE_NAME:-$CF_ZONE_ID}..."
  cfApi POST "/zones/${CF_ZONE_ID}/dns_records" "$body"
  emitResult "$(cfResult)" "$DNS_TEMPLATE"
}

cmd_dns_update() {
  resolveZone
  local id body
  id="$(dnsSelectRecord)" || exit $?
  body="$(dnsRecordBody update)"
  [[ "$body" == "{}" ]] && die "Nothing to update. Provide --content, --ttl, --proxied, --priority, --comment, --tags or --new-name." "$EX_ARGS"
  logInfo "Updating DNS record ${id} in ${CF_ZONE_NAME:-$CF_ZONE_ID}..."
  cfApi PATCH "/zones/${CF_ZONE_ID}/dns_records/${id}" "$body"
  emitResult "$(cfResult)" "$DNS_TEMPLATE"
}

cmd_dns_upsert() {
  resolveZone
  requireOpt type
  local name type body existing count match_id current desired fqdn
  name="$(optFirst "" name hostname record)"
  [[ -z "$name" ]] && die "Missing required option --name=<name>" "$EX_ARGS"
  type="$(dnsType)"
  body="$(dnsRecordBody create)"
  if [[ "$(printf '%s' "$body" | jq 'has("content") or has("data")')" != "true" ]]; then
    die "Missing required option --content=<value>" "$EX_ARGS"
  fi
  fqdn="$(recordFqdn "$name")"
  dnsFind "$name" "$type"
  existing="$(cfResult)"
  count="$(printf '%s' "$existing" | jq 'length')"
  if [[ "$count" == "0" ]]; then
    logInfo "Creating ${type} record ${fqdn}..."
    cfApi POST "/zones/${CF_ZONE_ID}/dns_records" "$body"
    emitResult "$(cfResult '.result + {action:"created"}')" "$DNS_TEMPLATE"
    return 0
  fi
  if [[ "$count" != "1" ]]; then
    # several records share name+type (common for MX/TXT): prefer the one with the same content
    match_id="$(printf '%s' "$existing" | jq -r --arg c "$(printf '%s' "$body" | jq -r '.content // ""')" '[.[] | select(.content == $c)][0].id // empty')"
    if [[ -z "$match_id" ]]; then
      if [[ "$(optBool replace)" == "true" ]]; then
        logInfo "Replacing ${count} existing ${type} records for ${fqdn}..."
        for match_id in $(printf '%s' "$existing" | jq -r '.[1:][].id'); do
          cfApi DELETE "/zones/${CF_ZONE_ID}/dns_records/${match_id}"
        done
        match_id="$(printf '%s' "$existing" | jq -r '.[0].id')"
      else
        logError "Found ${count} ${type} records for ${fqdn}. Add --replace to collapse them into one, or use 'dns create' to add another."
        printf '%s' "$existing" | jq -r "$DNS_LIST_TEMPLATE | \"  \" + ." >&2
        exit "$EX_ARGS"
      fi
    fi
  else
    match_id="$(printf '%s' "$existing" | jq -r '.[0].id')"
  fi
  current="$(printf '%s' "$existing" | jq -c --arg id "$match_id" '.[] | select(.id == $id)')"
  desired="$(printf '%s' "$body" | jq -c 'del(.type) | del(.name)')"
  if [[ "$(jq -cn --argjson c "$current" --argjson d "$desired" '($d | to_entries | all(.value == $c[.key]))')" == "true" ]]; then
    logInfo "${type} record ${fqdn} is already up to date."
    emitResult "$(printf '%s' "$current" | jq -c '. + {action:"unchanged"}')" "$DNS_TEMPLATE"
    return 0
  fi
  logInfo "Updating ${type} record ${fqdn} (${match_id})..."
  cfApi PATCH "/zones/${CF_ZONE_ID}/dns_records/${match_id}" "$body"
  emitResult "$(cfResult '.result + {action:"updated"}')" "$DNS_TEMPLATE"
}

cmd_dns_set() { cmd_dns_upsert; }

cmd_dns_delete() {
  resolveZone
  local id name ids count
  id="$(opt id)"
  if [[ -n "$id" ]]; then
    ids="$id"
    count=1
  else
    name="$(optFirst "" name hostname record)"
    [[ -z "$name" ]] && die "Specify the record(s) with --id=<record-id> or --name=<name> [--type=<type>] [--content=<value>]" "$EX_ARGS"
    dnsFind "$name" "$(dnsType)" "$(optFirst "" content value)"
    count="$(cfResultRaw '.result | length')"
    if [[ "$count" == "0" ]]; then
      if [[ "$(optBool if-exists)" == "true" || "$OCTOFLARE_DRY_RUN" == "true" ]]; then
        emitMessage "No DNS record found for $(recordFqdn "$name"); nothing to delete." '{"deleted":0}'
        return 0
      fi
      die "No DNS record found for $(recordFqdn "$name")" "$EX_NOTFOUND"
    fi
    if [[ "$count" != "1" && "$(optBool all)" != "true" ]]; then
      logError "Found ${count} records for $(recordFqdn "$name"); add --all to delete them all, or narrow with --type/--content/--id:"
      cfResultRaw "$DNS_LIST_TEMPLATE | \"  \" + ." >&2
      exit "$EX_ARGS"
    fi
    ids="$(cfResultRaw '.result[].id')"
  fi
  confirm "Delete ${count} DNS record(s) in ${CF_ZONE_NAME:-$CF_ZONE_ID}?" || die "Cancelled." "$EX_OK"
  local deleted='[]'
  for id in $ids; do
    cfApi DELETE "/zones/${CF_ZONE_ID}/dns_records/${id}"
    deleted="$(jq -cn --argjson d "$deleted" --arg id "$id" '$d + [$id]')"
  done
  emitMessage "Deleted ${count} DNS record(s)." "$(jq -cn --argjson d "$deleted" '{deleted:($d|length), ids:$d}')"
}

cmd_dns_export() {
  resolveZone
  local file
  file="$(opt file)"
  cfApi GET "/zones/${CF_ZONE_ID}/dns_records/export" "" none
  if [[ -n "$file" ]]; then
    printf '%s\n' "$CF_RESPONSE" >"$file"
    emitMessage "Zone file for ${CF_ZONE_NAME:-$CF_ZONE_ID} written to ${file}." "$(jq -cn --arg f "$file" '{file:$f}')"
  elif [[ "$OCTOFLARE_OUTPUT" == "json" || -n "$OCTOFLARE_FIELD" ]]; then
    emitResult "$(jq -cn --arg z "$CF_ZONE_NAME" --arg b "$CF_RESPONSE" '{zone:$z, bind:$b}')"
  else
    printf '%s\n' "$CF_RESPONSE"
  fi
}

cmd_dns_import() {
  resolveZone
  requireOpt file
  local file
  file="$(opt file)"
  [[ -f "$file" ]] || die "Zone file not found: ${file}" "$EX_ARGS"
  logInfo "Importing ${file} into ${CF_ZONE_NAME:-$CF_ZONE_ID}..."
  cfApi POST "/zones/${CF_ZONE_ID}/dns_records/import" "" multipart -F "file=@${file}" -F "proxied=$(optBool proxied false)"
  emitResult "$(cfResult)" '"records_added=\(.recs_added // 0)\ntotal_records_parsed=\(.total_records_parsed // 0)"'
}

cmd_dns_batch() {
  resolveZone
  local body
  body="$(inputFromOpts body)" || exit $?
  [[ -z "$body" ]] && die "Provide the batch with --file=<batch.json> (keys: posts, patches, puts, deletes)" "$EX_ARGS"
  cfApi POST "/zones/${CF_ZONE_ID}/dns_records/batch" "$body"
  emitResult "$(cfResult)" '"posts=\((.posts // []) | length)\npatches=\((.patches // []) | length)\nputs=\((.puts // []) | length)\ndeletes=\((.deletes // []) | length)"'
}

cmd_dns_types() {
  emitResult '["A","AAAA","CAA","CERT","CNAME","DNSKEY","DS","HTTPS","LOC","MX","NAPTR","NS","OPENPGPKEY","PTR","SMIMEA","SRV","SSHFP","SVCB","TLSA","TXT","URI"]' '.[]'
}
