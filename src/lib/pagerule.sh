#!/usr/bin/env bash
# Octoflare module: pagerule
#
# Page Rules (3 free per zone): list, create, upsert, update, delete,
# enable/disable, plus a forwarding-URL shortcut. Prefer the rules engine
# (redirect, cache-rule, config-rule) for new automation.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand pagerule list "--domain=<zone> [--status=active|disabled]" "List Page Rules"
registerCommand pagerule get "--domain=<zone> (--id=<rule-id> | --url=<pattern>)" "Show one Page Rule"
registerCommand pagerule create "--domain=<zone> --url=<pattern> (--forward-to=<url> [--status-code=301] | --cache-level=<v> | --always-use-https | --ssl=<v> | --edge-cache-ttl=<s> | --browser-cache-ttl=<s> | --actions=<json> ...) [--priority=<n>] [--status=active|disabled]" "Create a Page Rule"
registerCommand pagerule upsert "--domain=<zone> --url=<pattern> [actions...]" "Create or replace the Page Rule for the URL pattern"
registerCommand pagerule update "--domain=<zone> --id=<rule-id> [--url=<pattern>] [actions...] [--priority=<n>] [--status=<v>]" "Update a Page Rule"
registerCommand pagerule delete "--domain=<zone> (--id=<rule-id> | --url=<pattern>)" "Delete a Page Rule"
registerCommand pagerule enable "--domain=<zone> (--id=<rule-id> | --url=<pattern>)" "Enable a Page Rule"
registerCommand pagerule disable "--domain=<zone> (--id=<rule-id> | --url=<pattern>)" "Disable a Page Rule"
registerCommand pagerule redirect "--domain=<zone> --url=<pattern> --to=<url> [--status-code=301]" "Shortcut: forwarding-URL Page Rule (create or update)"

PAGERULE_TEMPLATE='.[] | "\(.id)\t\(.status)\tpriority=\(.priority)\t\(.targets[0].constraint.value)\t\([.actions[] | .id + (if .value != null then "=" + (.value|tostring) else "" end)] | join(", "))"'
PAGERULE_ONE='"id=\(.id)\nstatus=\(.status)\npriority=\(.priority)\nurl=\(.targets[0].constraint.value)\nactions=\([.actions[] | .id + (if .value != null then "=" + (.value|tostring) else "" end)] | join(", "))"'

# Actions that take no value
PAGERULE_TOGGLES="always_use_https disable_apps disable_performance disable_security disable_zaraz"
# Actions with a value (on/off, level, number or string)
PAGERULE_VALUES="automatic_https_rewrites browser_cache_ttl browser_check bypass_cache_on_cookie cache_by_device_type cache_deception_armor cache_level cache_on_cookie edge_cache_ttl email_obfuscation explicit_cache_control host_header_override ip_geolocation mirage opportunistic_encryption origin_error_page_pass_thru polish resolve_override respect_strong_etag response_buffering rocket_loader security_level server_side_exclude sort_query_string_for_cache ssl true_client_ip_header waf"

# pageruleActions - Build the actions array from --actions JSON and the convenience flags
pageruleActions() {
  local actions='[]' key flag value forward status_code
  hasOpt actions && actions="$(readFileOrValue "$(opt actions)" | jq -c .)"
  forward="$(optFirst "" forward-to forwarding-url to)"
  if [[ -n "$forward" ]]; then
    status_code="$(optFirst 301 status-code code)"
    actions="$(jq -cn --argjson a "$actions" --arg u "$forward" --argjson s "$status_code" '$a + [{id:"forwarding_url", value:{url:$u, status_code:$s}}]')"
  fi
  for key in $PAGERULE_TOGGLES; do
    flag="${key//_/-}"
    hasOpt "$flag" && [[ "$(optBool "$flag")" == "true" ]] && actions="$(jq -cn --argjson a "$actions" --arg id "$key" '$a + [{id:$id}]')"
  done
  for key in $PAGERULE_VALUES; do
    flag="${key//_/-}"
    if hasOpt "$flag"; then
      value="$(opt "$flag")"
      case "$key" in
        browser_cache_ttl|edge_cache_ttl) actions="$(jq -cn --argjson a "$actions" --arg id "$key" --argjson v "$value" '$a + [{id:$id, value:$v}]')" ;;
        *) actions="$(jq -cn --argjson a "$actions" --arg id "$key" --arg v "$value" '$a + [{id:$id, value:$v}]')" ;;
      esac
    fi
  done
  printf '%s' "$actions"
}

# pageruleBody - Full page rule body
pageruleBody() {
  local url actions
  url="$(optFirst "" url pattern target)"
  [[ -z "$url" ]] && die "Missing --url=<pattern> (e.g. --url='*example.com/old/*')" "$EX_ARGS"
  actions="$(pageruleActions)"
  [[ "$(printf '%s' "$actions" | jq 'length')" == "0" ]] && die "Provide at least one action (e.g. --forward-to=<url>, --cache-level=cache_everything, --always-use-https or --actions=<json>)" "$EX_ARGS"
  jq -cn --arg u "$url" --argjson a "$actions" --arg s "$(opt status active)" --argjson p "$(opt priority 1)" '{targets:[{target:"url", constraint:{operator:"matches", value:$u}}], actions:$a, status:$s, priority:$p}'
}

# pageruleFind - Find a page rule by --id or --url (prints JSON or nothing)
pageruleFind() {
  local url
  if hasOpt id; then
    cfApi GET "/zones/${CF_ZONE_ID}/pagerules/$(opt id)"
    cfResult
    return 0
  fi
  url="$(optFirst "" url pattern target)"
  [[ -z "$url" ]] && die "Specify --id=<rule-id> or --url=<pattern>" "$EX_ARGS"
  cfApi GET "/zones/${CF_ZONE_ID}/pagerules"
  printf '%s' "$CF_RESPONSE" | jq -c --arg u "$url" '[.result[]? | select(.targets[0].constraint.value == $u)][0] // empty'
}

# pageruleRequire - Like pageruleFind but exits when nothing matches
pageruleRequire() {
  local found
  found="$(pageruleFind)" || exit $?
  if [[ -z "$found" ]]; then
    [[ "$OCTOFLARE_DRY_RUN" == "true" ]] && { echo '{"id":"dry-run-pagerule-id","status":"active","priority":1,"targets":[{"constraint":{"value":"dry-run"}}],"actions":[]}'; return 0; }
    die "No Page Rule found for $(optFirst "$(opt id)" url pattern target)" "$EX_NOTFOUND"
  fi
  printf '%s' "$found"
}

cmd_pagerule_list() {
  resolveZone
  cfApi GET "$(cfPath "/zones/${CF_ZONE_ID}/pagerules" "$(cfQuery "status=$(opt status)")")"
  emitResult "$(cfResult)" "$PAGERULE_TEMPLATE" "No Page Rules found."
}

cmd_pagerule_get() {
  resolveZone
  local rule
  rule="$(pageruleRequire)" || exit $?
  emitResult "$rule" "$PAGERULE_ONE"
}

cmd_pagerule_create() {
  resolveZone
  local body
  body="$(pageruleBody)" || exit $?
  logInfo "Creating Page Rule for $(optFirst "" url pattern target)..."
  cfApi POST "/zones/${CF_ZONE_ID}/pagerules" "$body"
  emitResult "$(cfResult)" "$PAGERULE_ONE"
}

cmd_pagerule_upsert() {
  resolveZone
  local body existing id
  body="$(pageruleBody)" || exit $?
  existing="$(pageruleFind)" || exit $?
  if [[ -z "$existing" ]]; then
    logInfo "Creating Page Rule for $(optFirst "" url pattern target)..."
    cfApi POST "/zones/${CF_ZONE_ID}/pagerules" "$body"
    emitResult "$(cfResult '.result + {action_result:"created"}')" "$PAGERULE_ONE"
    return 0
  fi
  id="$(printf '%s' "$existing" | jq -r '.id')"
  if [[ "$(printf '%s' "$existing" | jq -cS '{actions, status, priority, target:.targets[0].constraint.value}')" == "$(printf '%s' "$body" | jq -cS '{actions, status, priority, target:.targets[0].constraint.value}')" ]]; then
    logInfo "Page Rule ${id} is already up to date."
    emitResult "$(printf '%s' "$existing" | jq -c '. + {action_result:"unchanged"}')" "$PAGERULE_ONE"
    return 0
  fi
  logInfo "Updating Page Rule ${id}..."
  cfApi PUT "/zones/${CF_ZONE_ID}/pagerules/${id}" "$body"
  emitResult "$(cfResult '.result + {action_result:"updated"}')" "$PAGERULE_ONE"
}

cmd_pagerule_update() {
  resolveZone
  requireOpt id
  local patch='{}' actions
  actions="$(pageruleActions)"
  [[ "$(printf '%s' "$actions" | jq 'length')" != "0" ]] && patch="$(jq -cn --argjson p "$patch" --argjson a "$actions" '$p + {actions:$a}')"
  [[ -n "$(optFirst "" url pattern)" ]] && patch="$(jq -cn --argjson p "$patch" --arg u "$(optFirst "" url pattern)" '$p + {targets:[{target:"url", constraint:{operator:"matches", value:$u}}]}')"
  hasOpt status && patch="$(jq -cn --argjson p "$patch" --arg v "$(opt status)" '$p + {status:$v}')"
  hasOpt priority && patch="$(jq -cn --argjson p "$patch" --argjson v "$(opt priority)" '$p + {priority:$v}')"
  [[ "$patch" == "{}" ]] && die "Nothing to update" "$EX_ARGS"
  cfApi PATCH "/zones/${CF_ZONE_ID}/pagerules/$(opt id)" "$patch"
  emitResult "$(cfResult)" "$PAGERULE_ONE"
}

cmd_pagerule_delete() {
  resolveZone
  local rule id
  rule="$(pageruleFind)" || exit $?
  if [[ -z "$rule" ]]; then
    [[ "$(optBool if-exists)" == "true" ]] && { emitMessage "No Page Rule found; nothing to delete."; return 0; }
    [[ "$OCTOFLARE_DRY_RUN" == "true" ]] && rule='{"id":"dry-run-pagerule-id"}'
    [[ -z "$rule" ]] && die "No Page Rule found for $(optFirst "$(opt id)" url pattern target)" "$EX_NOTFOUND"
  fi
  id="$(printf '%s' "$rule" | jq -r '.id')"
  confirm "Delete Page Rule ${id}?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/zones/${CF_ZONE_ID}/pagerules/${id}"
  emitMessage "Page Rule ${id} deleted." "$(jq -cn --arg id "$id" '{id:$id}')"
}

# pageruleSetStatus - Enable/disable the selected rule
pageruleSetStatus() {
  resolveZone
  local rule id
  rule="$(pageruleRequire)" || exit $?
  id="$(printf '%s' "$rule" | jq -r '.id')"
  cfApi PATCH "/zones/${CF_ZONE_ID}/pagerules/${id}" "{\"status\":\"$1\"}"
  emitResult "$(cfResult)" "$PAGERULE_ONE"
}

cmd_pagerule_enable() { pageruleSetStatus active; }
cmd_pagerule_disable() { pageruleSetStatus disabled; }

cmd_pagerule_redirect() {
  requireOpt url to
  setOpt forward-to "$(opt to)"
  cmd_pagerule_upsert
}
