#!/usr/bin/env bash
# Octoflare module: zone
#
# Zone management: list, get, create, delete, activation check, pause/resume,
# name servers and zone holds.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand zone list "[--name=<filter>] [--status=<status>] [--account-id=<id>]" "List zones visible to the token"
registerCommand zone get "--domain=<zone>" "Show zone details"
registerCommand zone id "--domain=<zone>" "Print the zone ID"
registerCommand zone create "--name=<domain> [--account-id=<id>] [--type=full|partial] [--jump-start]" "Add a new zone"
registerCommand zone delete "--domain=<zone> [--yes]" "Delete a zone"
registerCommand zone check "--domain=<zone>" "Re-run the zone activation check"
registerCommand zone pause "--domain=<zone>" "Pause Cloudflare on the zone (DNS only)"
registerCommand zone resume "--domain=<zone>" "Resume Cloudflare on the zone"
registerCommand zone nameservers "--domain=<zone>" "Show the assigned Cloudflare name servers"
registerCommand zone hold-status "--domain=<zone>" "Show the zone hold"
registerCommand zone hold "--domain=<zone> [--include-subdomains]" "Create a zone hold (prevents the zone being added to another account)"
registerCommand zone unhold "--domain=<zone> [--after=<iso8601>]" "Remove the zone hold"

ZONE_LIST_TEMPLATE='.[] | "\(.name)\t\(.id)\t\(.status)\t\(.plan.name // "-")\t\(.account.name // "-")"'
ZONE_TEMPLATE='"name=\(.name)\nid=\(.id)\nstatus=\(.status)\npaused=\(.paused)\ntype=\(.type)\nplan=\(.plan.name // "-")\naccount=\(.account.name // "-") (\(.account.id // "-"))\nname_servers=\((.name_servers // []) | join(","))\noriginal_registrar=\(.original_registrar // "-")\nmodified_on=\(.modified_on // "-")"'

cmd_zone_list() {
  local query
  query="$(cfQuery "name=$(opt name)" "status=$(opt status)" "account.id=$(optFirst "${CLOUDFLARE_ACCOUNT_ID:-}" account-id)" "match=$(opt match)")"
  cfApiList "/zones" "$query"
  emitResult "$(cfResult)" "$ZONE_LIST_TEMPLATE" "No zones found."
}

cmd_zone_get() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}"
  emitResult "$(cfResult)" "$ZONE_TEMPLATE"
}

cmd_zone_id() {
  resolveZone
  emitResult "$(jq -cn --arg id "$CF_ZONE_ID" --arg name "$CF_ZONE_NAME" '{id:$id, name:$name}')" '.id'
}

cmd_zone_create() {
  local name body type
  # only --name: --domain/--zone name an existing zone (resolveAccount would look it up)
  name="$(opt name)"
  [[ -z "$name" ]] && die "Missing required option --name=<domain>" "$EX_ARGS"
  type="$(opt type full)"
  resolveAccount
  body="$(jq -cn --arg name "$(lower "$name")" --arg acc "$CF_ACCOUNT_ID" --arg type "$type" --argjson js "$(optBool jump-start)" \
    '{name:$name, account:{id:$acc}, type:$type} + (if $js then {jump_start:true} else {} end)')"
  logInfo "Creating zone ${name} in account ${CF_ACCOUNT_ID}..."
  cfApi POST "/zones" "$body"
  CF_ZONE_ID="$(cfResultRaw '.result.id // empty')"
  CF_ZONE_NAME="$(cfResultRaw '.result.name // empty')"
  emitResult "$(cfResult)" "$ZONE_TEMPLATE"
}

cmd_zone_delete() {
  resolveZone
  confirm "Delete zone ${CF_ZONE_NAME:-$CF_ZONE_ID}? This cannot be undone." || die "Cancelled." "$EX_OK"
  cfApi DELETE "/zones/${CF_ZONE_ID}"
  emitMessage "Zone ${CF_ZONE_NAME:-$CF_ZONE_ID} deleted." "$(cfResult)"
}

cmd_zone_check() {
  resolveZone
  cfApi PUT "/zones/${CF_ZONE_ID}/activation_check"
  emitMessage "Activation check triggered for ${CF_ZONE_NAME:-$CF_ZONE_ID}." "$(cfResult)"
}

# zoneSetPaused - PATCH the paused flag
zoneSetPaused() {
  resolveZone
  cfApi PATCH "/zones/${CF_ZONE_ID}" "{\"paused\":$1}"
  emitResult "$(cfResult)" '"\(.name) paused=\(.paused)"'
}

cmd_zone_pause() { zoneSetPaused true; }
cmd_zone_resume() { zoneSetPaused false; }

cmd_zone_nameservers() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}"
  emitResult "$(cfResult '{name:.result.name, name_servers:(.result.name_servers // []), original_name_servers:(.result.original_name_servers // [])}')" '.name_servers[]'
}

cmd_zone_hold_status() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/hold"
  emitResult "$(cfResult)" '"hold=\(.hold)\ninclude_subdomains=\(.include_subdomains // false)\nhold_after=\(.hold_after // "-")"'
}

cmd_zone_hold() {
  resolveZone
  local path="/zones/${CF_ZONE_ID}/hold"
  [[ "$(optBool include-subdomains)" == "true" ]] && path="${path}?include_subdomains=true"
  cfApi POST "$path" "" none
  emitResult "$(cfResult)" '"hold=\(.hold)\ninclude_subdomains=\(.include_subdomains // false)"'
}

cmd_zone_unhold() {
  resolveZone
  local path="/zones/${CF_ZONE_ID}/hold"
  [[ -n "$(opt after)" ]] && path="${path}?hold_after=$(urlEncode "$(opt after)")"
  cfApi DELETE "$path"
  emitResult "$(cfResult)" '"hold=\(.hold)\nhold_after=\(.hold_after // "-")"'
}
