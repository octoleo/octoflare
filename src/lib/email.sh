#!/usr/bin/env bash
# Octoflare module: email
#
# Email Routing: enable/disable per zone, routing rules, catch-all and the
# account's destination addresses.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand email status "--domain=<zone>" "Show Email Routing status"
registerCommand email enable "--domain=<zone>" "Enable Email Routing (adds the required DNS records)"
registerCommand email disable "--domain=<zone>" "Disable Email Routing"
registerCommand email dns "--domain=<zone>" "Show the DNS records Email Routing needs"
registerCommand email rules "--domain=<zone>" "List routing rules"
registerCommand email rule-create "--domain=<zone> --to=<address> (--forward=<dest,dest> | --drop | --worker=<name>) [--name=<text>] [--priority=<n>]" "Create a routing rule"
registerCommand email rule-upsert "--domain=<zone> --to=<address> (--forward=<dest> | --drop | --worker=<name>)" "Create or update the rule for an address"
registerCommand email rule-delete "--domain=<zone> (--id=<rule-id> | --to=<address>)" "Delete a routing rule"
registerCommand email catch-all "--domain=<zone> [--forward=<dest> | --drop | --worker=<name>] [--disable]" "Get or set the catch-all rule"
registerCommand email addresses "" "List destination addresses (account)"
registerCommand email address-add "--email=<address>" "Add a destination address (sends a verification email)"
registerCommand email address-delete "(--email=<address> | --id=<address-id>)" "Delete a destination address"

EMAIL_RULE_TEMPLATE='.[] | "\(.id)\tenabled=\(.enabled)\t\(.matchers[0].value // "*")\t-> \([.actions[] | .type + (if .value then ":" + (.value|join(",")) else "" end)] | join(" "))\t\(.name // "")"'
EMAIL_RULE_ONE='"id=\(.id)\nname=\(.name // "-")\nenabled=\(.enabled)\nmatch=\(.matchers[0].value // "*")\nactions=\([.actions[] | .type + (if .value then ":" + (.value|join(",")) else "" end)] | join(" "))"'

cmd_email_status() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/email/routing"
  emitResult "$(cfResult)" '"enabled=\(.enabled)\nstatus=\(.status // "-")\nskip_wizard=\(.skip_wizard // false)\nname=\(.name // "-")"'
}

cmd_email_enable() {
  resolveZone
  cfApi POST "/zones/${CF_ZONE_ID}/email/routing/enable" "" none
  emitResult "$(cfResult)" '"enabled=\(.enabled)\nstatus=\(.status // "-")"'
}

cmd_email_disable() {
  resolveZone
  confirm "Disable Email Routing for ${CF_ZONE_NAME:-$CF_ZONE_ID}?" || die "Cancelled." "$EX_OK"
  cfApi POST "/zones/${CF_ZONE_ID}/email/routing/disable" "" none
  emitResult "$(cfResult)" '"enabled=\(.enabled)\nstatus=\(.status // "-")"'
}

cmd_email_dns() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/email/routing/dns"
  emitResult "$(cfResult)" 'if type=="array" then .[] | "\(.type)\t\(.name)\t\(.content)\tpriority=\(.priority // "-")" else (.record[]? // .[]?) | "\(.type)\t\(.name)\t\(.content)" end'
}

# emailActions - Build the actions array from --forward/--drop/--worker
emailActions() {
  if [[ "$(optBool drop)" == "true" ]]; then
    echo '[{"type":"drop"}]'
  elif hasOpt worker; then
    jq -cn --arg w "$(opt worker)" '[{type:"worker", value:[$w]}]'
  elif [[ -n "$(optFirst "" forward forward-to destination)" ]]; then
    jq -cn --argjson v "$(toJsonArray "$(optFirst "" forward forward-to destination)")" '[{type:"forward", value:$v}]'
  else
    die "Provide --forward=<destination>, --drop or --worker=<name>" "$EX_ARGS"
  fi
}

# emailRuleBody - Build a rule body
emailRuleBody() {
  local to actions
  to="$(optFirst "" to address match)"
  [[ -z "$to" ]] && die "Missing --to=<address@zone>" "$EX_ARGS"
  [[ "$to" != *@* ]] && to="${to}@${CF_ZONE_NAME}"
  actions="$(emailActions)" || exit $?
  jq -cn --arg to "$to" --argjson a "$actions" --arg n "$(opt name "Route ${to}")" --argjson en "$(optBool enabled true)" --argjson p "$(opt priority 0)" \
    '{name:$n, enabled:$en, priority:$p, matchers:[{type:"literal", field:"to", value:$to}], actions:$a}'
}

cmd_email_rules() {
  resolveZone
  cfApiList "/zones/${CF_ZONE_ID}/email/routing/rules"
  emitResult "$(cfResult)" "$EMAIL_RULE_TEMPLATE" "No routing rules."
}

cmd_email_rule_create() {
  resolveZone
  local body
  body="$(emailRuleBody)" || exit $?
  cfApi POST "/zones/${CF_ZONE_ID}/email/routing/rules" "$body"
  emitResult "$(cfResult)" "$EMAIL_RULE_ONE"
}

cmd_email_rule_upsert() {
  resolveZone
  local body to existing id
  body="$(emailRuleBody)" || exit $?
  to="$(printf '%s' "$body" | jq -r '.matchers[0].value')"
  cfApiList "/zones/${CF_ZONE_ID}/email/routing/rules"
  existing="$(printf '%s' "$CF_RESPONSE" | jq -c --arg to "$to" '[.result[] | select(.matchers[]? | .value == $to)][0] // empty')"
  if [[ -z "$existing" ]]; then
    cfApi POST "/zones/${CF_ZONE_ID}/email/routing/rules" "$body"
    emitResult "$(cfResult '.result + {action_result:"created"}')" "$EMAIL_RULE_ONE"
    return 0
  fi
  id="$(printf '%s' "$existing" | jq -r '.id')"
  if [[ "$(printf '%s' "$existing" | jq -cS '{actions, enabled}')" == "$(printf '%s' "$body" | jq -cS '{actions, enabled}')" ]]; then
    emitResult "$(printf '%s' "$existing" | jq -c '. + {action_result:"unchanged"}')" "$EMAIL_RULE_ONE"
    return 0
  fi
  cfApi PUT "/zones/${CF_ZONE_ID}/email/routing/rules/${id}" "$body"
  emitResult "$(cfResult '.result + {action_result:"updated"}')" "$EMAIL_RULE_ONE"
}

cmd_email_rule_delete() {
  resolveZone
  local id to
  id="$(opt id)"
  if [[ -z "$id" ]]; then
    to="$(optFirst "" to address match)"
    [[ -z "$to" ]] && die "Specify --id=<rule-id> or --to=<address>" "$EX_ARGS"
    [[ "$to" != *@* ]] && to="${to}@${CF_ZONE_NAME}"
    cfApiList "/zones/${CF_ZONE_ID}/email/routing/rules"
    id="$(printf '%s' "$CF_RESPONSE" | jq -r --arg to "$to" '[.result[] | select(.matchers[]? | .value == $to)][0].id // empty')"
    [[ -z "$id" && "$OCTOFLARE_DRY_RUN" == "true" ]] && id="dry-run-rule-id"
    [[ -z "$id" ]] && die "No routing rule found for ${to}" "$EX_NOTFOUND"
  fi
  confirm "Delete routing rule ${id}?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/zones/${CF_ZONE_ID}/email/routing/rules/${id}"
  emitMessage "Routing rule ${id} deleted." "$(jq -cn --arg id "$id" '{id:$id}')"
}

cmd_email_catch_all() {
  resolveZone
  local body="" actions
  if [[ "$(optBool disable)" == "true" ]]; then
    body='{"name":"Catch-all","enabled":false,"matchers":[{"type":"all"}],"actions":[{"type":"drop"}]}'
  elif hasOpt forward || hasOpt drop || hasOpt worker; then
    actions="$(emailActions)" || exit $?
    body="$(jq -cn --argjson a "$actions" '{name:"Catch-all", enabled:true, matchers:[{type:"all"}], actions:$a}')"
  fi
  if [[ -n "$body" ]]; then
    cfApi PUT "/zones/${CF_ZONE_ID}/email/routing/rules/catch_all" "$body"
  else
    cfApi GET "/zones/${CF_ZONE_ID}/email/routing/rules/catch_all"
  fi
  emitResult "$(cfResult)" '"enabled=\(.enabled)\nactions=\([.actions[]? | .type + (if .value then ":" + (.value|join(",")) else "" end)] | join(" "))"'
}

cmd_email_addresses() {
  resolveAccount
  cfApiList "/accounts/${CF_ACCOUNT_ID}/email/routing/addresses"
  emitResult "$(cfResult)" '.[] | "\(.email)\tverified=\(if .verified then "yes" else "no" end)\tid=\(.id)"' "No destination addresses."
}

cmd_email_address_add() {
  resolveAccount
  requireOpt email
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/email/routing/addresses" "$(jq -cn --arg e "$(opt email)" '{email:$e}')"
  emitResult "$(cfResult)" '"email=\(.email)\nid=\(.id)\nverified=\(.verified // "pending")"'
}

cmd_email_address_delete() {
  resolveAccount
  local id
  id="$(opt id)"
  if [[ -z "$id" ]]; then
    requireOpt email
    cfApiList "/accounts/${CF_ACCOUNT_ID}/email/routing/addresses"
    id="$(printf '%s' "$CF_RESPONSE" | jq -r --arg e "$(opt email)" '[.result[] | select(.email == $e)][0].id // empty')"
    [[ -z "$id" && "$OCTOFLARE_DRY_RUN" == "true" ]] && id="dry-run-address-id"
    [[ -z "$id" ]] && die "Destination address not found: $(opt email)" "$EX_NOTFOUND"
  fi
  confirm "Delete destination address ${id}?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/email/routing/addresses/${id}"
  emitMessage "Destination address ${id} deleted." "$(jq -cn --arg id "$id" '{id:$id}')"
}
