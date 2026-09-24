#!/usr/bin/env bash
# Octoflare module: r2
#
# R2 buckets: list, create, delete, CORS policy, custom domains and the
# public r2.dev domain. Objects are handled by S3-compatible tools.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand r2 list "[--name-contains=<text>]" "List R2 buckets"
registerCommand r2 get "--bucket=<name>" "Show a bucket"
registerCommand r2 create "--bucket=<name> [--location=wnam|enam|weur|eeur|apac|oc] [--storage-class=Standard|InfrequentAccess]" "Create a bucket"
registerCommand r2 delete "--bucket=<name>" "Delete a bucket (must be empty)"
registerCommand r2 cors "--bucket=<name> [--file=<rules.json> | --delete]" "Get, set or delete the CORS policy"
registerCommand r2 domains "--bucket=<name>" "List custom domains of a bucket"
registerCommand r2 domain-add "--bucket=<name> --name=<hostname> [--domain=<zone>] [--min-tls=1.2]" "Attach a custom domain (zone must be on Cloudflare)"
registerCommand r2 domain-delete "--bucket=<name> --name=<hostname>" "Detach a custom domain"
registerCommand r2 public "--bucket=<name> [on|off]" "Get or toggle the public r2.dev domain"

R2_TEMPLATE='.[] | "\(.name)\tlocation=\(.location // "-")\tclass=\(.storage_class // "-")\tcreated=\(.creation_date // "-")"'

r2Bucket() {
  local b
  b="$(optFirst "" bucket name)"
  [[ -z "$b" ]] && die "Missing --bucket=<name>" "$EX_ARGS"
  printf '%s' "$b"
}

cmd_r2_list() {
  resolveAccount
  # the R2 listing returns {buckets:[...]} with a result_info.cursor, not a plain array
  local cursor="" all='[]' page query
  while :; do
    query="$(cfQuery "name_contains=$(opt name-contains)" "cursor=${cursor}")"
    cfApi GET "$(cfPath "/accounts/${CF_ACCOUNT_ID}/r2/buckets" "$query")"
    page="$(cfResult '.result | if type=="object" then (.buckets // []) else (. // []) end')"
    all="$(printf '%s\n%s' "$all" "$page" | jq -cs '.[0] + .[1]')"
    cursor="$(cfResultRaw '.result_info.cursor // empty')"
    [[ -z "$cursor" || -n "$(opt limit)" ]] && break
  done
  emitResult "$all" "$R2_TEMPLATE" "No R2 buckets."
}

cmd_r2_get() {
  resolveAccount
  r2Bucket >/dev/null || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/r2/buckets/$(r2Bucket)"
  emitResult "$(cfResult)" '"name=\(.name)\nlocation=\(.location // "-")\nstorage_class=\(.storage_class // "-")\ncreation_date=\(.creation_date // "-")"'
}

cmd_r2_create() {
  resolveAccount
  r2Bucket >/dev/null || exit $?
  local body
  body="$(jq -cn --arg n "$(r2Bucket)" --arg l "$(opt location)" --arg c "$(opt storage-class)" '{name:$n} + (if $l != "" then {locationHint:$l} else {} end) + (if $c != "" then {storageClass:$c} else {} end)')"
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/r2/buckets" "$body"
  emitResult "$(cfResult)" '"name=\(.name)\nlocation=\(.location // "-")"'
}

cmd_r2_delete() {
  resolveAccount
  local b
  b="$(r2Bucket)" || exit $?
  confirm "Delete R2 bucket ${b}?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/r2/buckets/${b}"
  emitMessage "R2 bucket ${b} deleted." "$(jq -cn --arg n "$b" '{name:$n}')"
}

cmd_r2_cors() {
  resolveAccount
  r2Bucket >/dev/null || exit $?
  local path
  path="/accounts/${CF_ACCOUNT_ID}/r2/buckets/$(r2Bucket)/cors"
  if [[ "$(optBool delete)" == "true" ]]; then
    cfApi DELETE "$path"
    emitMessage "CORS policy removed from $(r2Bucket)."
    return 0
  fi
  if hasOpt file || hasOpt rules; then
    local rules
    rules="$(inputFromOpts rules | jq -c 'if type=="array" then {rules:.} else . end')" || exit $?
    cfApi PUT "$path" "$rules"
  else
    cfApi GET "$path"
  fi
  emitResult "$(cfResult)" '.rules[]? | "\(.id // "-")\tmethods=\(.allowed.methods|join(","))\torigins=\(.allowed.origins|join(","))"'
}

cmd_r2_domains() {
  resolveAccount
  r2Bucket >/dev/null || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/r2/buckets/$(r2Bucket)/domains/custom"
  emitResult "$(cfResult '.result.domains // .result // []')" '.[] | "\(.domain)\tenabled=\(.enabled)\tstatus=\(.status.ownership // "-")/\(.status.ssl // "-")\tminTLS=\(.minTLS // "-")"' "No custom domains."
}

cmd_r2_domain_add() {
  resolveAccount
  r2Bucket >/dev/null || exit $?
  requireOpt name
  local host zone_id
  host="$(opt name)"
  if [[ -n "$(optFirst "" zone-id)" ]]; then
    zone_id="$(opt zone-id)"
  else
    CF_ZONE_ID=""
    [[ -z "$(zoneOption)" ]] && setOpt domain "$host"
    resolveZone
    zone_id="$CF_ZONE_ID"
  fi
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/r2/buckets/$(r2Bucket)/domains/custom" "$(jq -cn --arg d "$host" --arg z "$zone_id" --arg t "$(opt min-tls 1.2)" '{domain:$d, zoneId:$z, enabled:true, minTLS:$t}')"
  emitResult "$(cfResult)" '"domain=\(.domain)\nenabled=\(.enabled)"'
}

cmd_r2_domain_delete() {
  resolveAccount
  r2Bucket >/dev/null || exit $?
  requireOpt name
  confirm "Detach $(opt name) from bucket $(r2Bucket)?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/r2/buckets/$(r2Bucket)/domains/custom/$(opt name)"
  emitMessage "Custom domain $(opt name) detached." "$(jq -cn --arg d "$(opt name)" '{domain:$d}')"
}

cmd_r2_public() {
  resolveAccount
  r2Bucket >/dev/null || exit $?
  local value path
  path="/accounts/${CF_ACCOUNT_ID}/r2/buckets/$(r2Bucket)/domains/managed"
  value="$(opt value)"
  [[ -z "$value" && -n "${ARGS[2]:-}" ]] && value="${ARGS[2]}"
  if [[ -n "$value" ]]; then
    value="$(parseBool "$value")" || exit $?
    cfApi PUT "$path" "$(jq -cn --argjson e "$value" '{enabled:$e}')"
  else
    cfApi GET "$path"
  fi
  emitResult "$(cfResult)" '"enabled=\(.enabled)\ndomain=\(.domain // "-")\nbucket=\(.bucketId // "-")"'
}
