#!/usr/bin/env bash
# Octoflare module: security
#
# Under Attack Mode / security level, IP Access Rules (zone or account),
# User-Agent Blocking rules, Zone Lockdown and Bot Fight Mode.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand attack-mode status "--domain=<zone>" "Show the current security level"
registerCommand attack-mode enable "--domain=<zone>" "Enable \"I'm Under Attack\" mode"
registerCommand attack-mode disable "--domain=<zone> [--restore-level=high]" "Disable attack mode and restore a security level"
registerCommand attack-mode level "--domain=<zone> --level=essentially_off|low|medium|high|under_attack" "Set the security level"
registerCommand access-rule list "[--domain=<zone> | --scope=account] [--mode=<mode>] [--value=<ip>]" "List IP Access rules"
registerCommand access-rule create "--mode=block|challenge|whitelist|js_challenge|managed_challenge --value=<ip|cidr|ASnnn|CC> [--notes=<text>] [--scope=account]" "Create an IP Access rule"
registerCommand access-rule upsert "--mode=<mode> --value=<ip|cidr|ASnnn|CC> [--notes=<text>]" "Create or update the rule for a value (idempotent)"
registerCommand access-rule block "--value=<ip|cidr|ASnnn|CC> [--notes=<text>]" "Block an IP, range, ASN or country"
registerCommand access-rule allow "--value=<ip|cidr|ASnnn|CC> [--notes=<text>]" "Allow (whitelist) an IP, range, ASN or country"
registerCommand access-rule challenge "--value=<ip|cidr|ASnnn|CC> [--notes=<text>]" "Managed-challenge an IP, range, ASN or country"
registerCommand access-rule delete "(--id=<rule-id> | --value=<ip|cidr|ASnnn|CC>) [--scope=account]" "Delete an IP Access rule"
registerCommand ua-rule list "--domain=<zone>" "List User-Agent Blocking rules"
registerCommand ua-rule create "--domain=<zone> --mode=block|challenge|js_challenge|managed_challenge --user-agent=<ua> [--description=<text>] [--paused]" "Create a User-Agent Blocking rule"
registerCommand ua-rule update "--domain=<zone> --id=<rule-id> [--mode=] [--user-agent=] [--description=] [--paused=]" "Update a User-Agent Blocking rule"
registerCommand ua-rule delete "--domain=<zone> --id=<rule-id>" "Delete a User-Agent Blocking rule"
registerCommand lockdown list "--domain=<zone>" "List Zone Lockdown rules (Pro plan and above)"
registerCommand lockdown create "--domain=<zone> --urls=<a,b> --ips=<ip|cidr,...> [--description=<text>] [--paused]" "Create a Zone Lockdown rule"
registerCommand lockdown delete "--domain=<zone> --id=<rule-id>" "Delete a Zone Lockdown rule"
registerCommand bot status "--domain=<zone>" "Show Bot Fight Mode / bot management configuration"
registerCommand bot fight-mode "--domain=<zone> on|off" "Turn Bot Fight Mode on or off"
registerCommand bot ai-bots "--domain=<zone> block|disabled|only_on_ad_pages" "Block AI crawlers (AI bots protection)"
registerCommand bot set "--domain=<zone> --settings='{\"fight_mode\":true,...}'" "Update any bot management field"

ACCESS_RULE_TEMPLATE='.[] | "\(.mode)\t\(.configuration.target)=\(.configuration.value)\tid=\(.id)\tscope=\(.scope.type // "-")\tnotes=\(.notes // "-")"'
ACCESS_RULE_ONE='"id=\(.id)\nmode=\(.mode)\ntarget=\(.configuration.target)\nvalue=\(.configuration.value)\nnotes=\(.notes // "-")\nscope=\(.scope.type // "-")"'

#####################################################################################################################VDM
######################################## Attack mode / security level

cmd_attack_mode_status() {
  settingGet security_level
  emitResult "$(cfResult)" '"security_level=\(.value)\nunder_attack=\(.value == "under_attack")"'
}

cmd_attack_mode_enable() {
  logInfo "Enabling Cloudflare Under Attack Mode for $(zoneOption)..."
  settingSet security_level under_attack
  emitResult "$(cfResult)" '"security_level=\(.value)"'
}

cmd_attack_mode_disable() {
  local level
  level="$(optFirst "${CLOUDFLARE_RESTORE_LEVEL:-high}" restore-level level)"
  [[ "$level" == "under_attack" ]] && level="high"
  logInfo "Disabling Cloudflare Under Attack Mode for $(zoneOption), restoring '${level}'..."
  settingSet security_level "$level"
  emitResult "$(cfResult)" '"security_level=\(.value)"'
}

cmd_attack_mode_level() {
  local level
  level="$(optFirst "" level value)"
  [[ -z "$level" && -n "${ARGS[2]:-}" ]] && level="${ARGS[2]}"
  [[ -z "$level" ]] && die "Missing --level=essentially_off|low|medium|high|under_attack" "$EX_ARGS"
  settingSet security_level "$level"
  emitResult "$(cfResult)" '"security_level=\(.value)"'
}

#####################################################################################################################VDM
######################################## IP Access rules

# accessRuleTarget - Detect the target type for a value (ip, ip6, ip_range, asn, country)
accessRuleTarget() {
  local v="$1" explicit
  explicit="$(opt target)"
  [[ -n "$explicit" ]] && { printf '%s' "$explicit"; return; }
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo ip
  elif [[ "$v" == */* ]]; then echo ip_range
  elif [[ "$v" == *:* ]]; then echo ip6
  elif [[ "$v" =~ ^[Aa][Ss][0-9]+$ ]]; then echo asn
  elif [[ "$v" =~ ^[A-Za-z]{2}$ ]]; then echo country
  else echo ip
  fi
}

AR_PATH=""

# accessRulePath - Set AR_PATH to the zone or account scoped access rules path
accessRulePath() {
  if [[ "$(opt scope)" == "account" ]]; then
    resolveAccount
    AR_PATH="/accounts/${CF_ACCOUNT_ID}/firewall/access_rules/rules"
  else
    resolveZone
    AR_PATH="/zones/${CF_ZONE_ID}/firewall/access_rules/rules"
  fi
}

# accessRuleValue - Normalise the value (uppercase ASN/country)
accessRuleValue() {
  local v="$1" target="$2"
  case "$target" in
    asn|country) printf '%s' "$v" | tr '[:lower:]' '[:upper:]' ;;
    *) printf '%s' "$v" ;;
  esac
}

cmd_access_rule_list() {
  local path query
  accessRulePath
  path="$AR_PATH"
  query="$(cfQuery "mode=$(opt mode)" "configuration.value=$(optFirst "" value ip)" "configuration.target=$(opt target)" "notes=$(opt notes)")"
  cfApiList "$path" "$query"
  emitResult "$(cfResult)" "$ACCESS_RULE_TEMPLATE" "No IP Access rules found."
}

# accessRuleCreate - POST a rule
accessRuleCreate() {
  local mode="$1" value="$2" target body path
  target="$(accessRuleTarget "$value")"
  value="$(accessRuleValue "$value" "$target")"
  accessRulePath
  path="$AR_PATH"
  body="$(jq -cn --arg m "$mode" --arg t "$target" --arg v "$value" --arg n "$(opt notes "Created by ${PROGRAM_NAME}")" '{mode:$m, configuration:{target:$t, value:$v}, notes:$n}')"
  logInfo "Creating access rule ${mode} ${target}=${value}..."
  cfApi POST "$path" "$body"
  emitResult "$(cfResult)" "$ACCESS_RULE_ONE"
}

cmd_access_rule_create() {
  requireOpt mode
  local value
  value="$(optFirst "" value ip)"
  [[ -z "$value" ]] && die "Missing required option --value=<ip|cidr|ASnnn|country>" "$EX_ARGS"
  accessRuleCreate "$(opt mode)" "$value"
}

cmd_access_rule_upsert() {
  requireOpt mode
  local value target path id existing_mode body
  value="$(optFirst "" value ip)"
  [[ -z "$value" ]] && die "Missing required option --value=<ip|cidr|ASnnn|country>" "$EX_ARGS"
  target="$(accessRuleTarget "$value")"
  value="$(accessRuleValue "$value" "$target")"
  accessRulePath
  path="$AR_PATH"
  cfApiList "$path" "$(cfQuery "configuration.value=${value}" "configuration.target=${target}")"
  id="$(cfResultRaw '.result[0].id // empty')"
  existing_mode="$(cfResultRaw '.result[0].mode // empty')"
  if [[ -z "$id" ]]; then
    accessRuleCreate "$(opt mode)" "$value"
    return 0
  fi
  if [[ "$existing_mode" == "$(opt mode)" && ( -z "$(opt notes)" || "$(opt notes)" == "$(cfResultRaw '.result[0].notes // ""')" ) ]]; then
    logInfo "Access rule for ${value} is already ${existing_mode}."
    emitResult "$(cfResult '.result[0] + {action:"unchanged"}')" "$ACCESS_RULE_ONE"
    return 0
  fi
  body="$(jq -cn --arg m "$(opt mode)" --arg n "$(opt notes)" '{mode:$m} + (if $n != "" then {notes:$n} else {} end)')"
  logInfo "Updating access rule ${id} for ${value} to $(opt mode)..."
  cfApi PATCH "${path}/${id}" "$body"
  emitResult "$(cfResult '.result + {action:"updated"}')" "$ACCESS_RULE_ONE"
}

cmd_access_rule_block() { setOpt mode block; cmd_access_rule_upsert; }
cmd_access_rule_allow() { setOpt mode whitelist; cmd_access_rule_upsert; }
cmd_access_rule_challenge() { setOpt mode managed_challenge; cmd_access_rule_upsert; }

cmd_access_rule_delete() {
  local path id value target
  accessRulePath
  path="$AR_PATH"
  id="$(opt id)"
  if [[ -z "$id" ]]; then
    value="$(optFirst "" value ip)"
    [[ -z "$value" ]] && die "Specify --id=<rule-id> or --value=<ip|cidr|ASnnn|country>" "$EX_ARGS"
    target="$(accessRuleTarget "$value")"
    value="$(accessRuleValue "$value" "$target")"
    cfApiList "$path" "$(cfQuery "configuration.value=${value}" "configuration.target=${target}")"
    id="$(cfResultRaw '.result[0].id // empty')"
    if [[ -z "$id" ]]; then
      [[ "$OCTOFLARE_DRY_RUN" == "true" ]] && id="dry-run-rule-id"
      [[ -z "$id" && "$(optBool if-exists)" == "true" ]] && { emitMessage "No access rule for ${value}; nothing to delete."; return 0; }
      [[ -z "$id" ]] && die "No access rule found for ${value}" "$EX_NOTFOUND"
    fi
  fi
  confirm "Delete access rule ${id}?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "${path}/${id}"
  emitMessage "Access rule ${id} deleted." "$(jq -cn --arg id "$id" '{id:$id}')"
}

#####################################################################################################################VDM
######################################## User-Agent Blocking rules

UA_RULE_TEMPLATE='.[] | "\(.mode)\tua=\(.configuration.value)\tid=\(.id)\tpaused=\(.paused)\t\(.description // "")"'

cmd_ua_rule_list() {
  resolveZone
  cfApiList "/zones/${CF_ZONE_ID}/firewall/ua_rules"
  emitResult "$(cfResult)" "$UA_RULE_TEMPLATE" "No User-Agent rules found."
}

cmd_ua_rule_create() {
  resolveZone
  requireOpt mode
  local ua body
  ua="$(optFirst "" user-agent ua value)"
  [[ -z "$ua" ]] && die "Missing required option --user-agent=<string>" "$EX_ARGS"
  body="$(jq -cn --arg m "$(opt mode)" --arg v "$ua" --arg d "$(opt description "Created by ${PROGRAM_NAME}")" --argjson p "$(optBool paused false)" '{mode:$m, configuration:{target:"ua", value:$v}, description:$d, paused:$p}')"
  cfApi POST "/zones/${CF_ZONE_ID}/firewall/ua_rules" "$body"
  emitResult "$(cfResult)" '"id=\(.id)\nmode=\(.mode)\nuser_agent=\(.configuration.value)\npaused=\(.paused)"'
}

cmd_ua_rule_update() {
  resolveZone
  requireOpt id
  cfApi GET "/zones/${CF_ZONE_ID}/firewall/ua_rules/$(opt id)"
  local body
  body="$(cfResult '.result | {mode, configuration, description, paused}')"
  hasOpt mode && body="$(jq -cn --argjson b "$body" --arg v "$(opt mode)" '$b + {mode:$v}')"
  [[ -n "$(optFirst "" user-agent ua value)" ]] && body="$(jq -cn --argjson b "$body" --arg v "$(optFirst "" user-agent ua value)" '$b + {configuration:{target:"ua", value:$v}}')"
  hasOpt description && body="$(jq -cn --argjson b "$body" --arg v "$(opt description)" '$b + {description:$v}')"
  hasOpt paused && body="$(jq -cn --argjson b "$body" --argjson v "$(optBool paused)" '$b + {paused:$v}')"
  cfApi PUT "/zones/${CF_ZONE_ID}/firewall/ua_rules/$(opt id)" "$body"
  emitResult "$(cfResult)" '"id=\(.id)\nmode=\(.mode)\nuser_agent=\(.configuration.value)\npaused=\(.paused)"'
}

cmd_ua_rule_delete() {
  resolveZone
  requireOpt id
  confirm "Delete User-Agent rule $(opt id)?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/zones/${CF_ZONE_ID}/firewall/ua_rules/$(opt id)"
  emitMessage "User-Agent rule $(opt id) deleted." "$(jq -cn --arg id "$(opt id)" '{id:$id}')"
}

#####################################################################################################################VDM
######################################## Zone Lockdown

cmd_lockdown_list() {
  resolveZone
  cfApiList "/zones/${CF_ZONE_ID}/firewall/lockdowns"
  emitResult "$(cfResult)" '.[] | "id=\(.id)\turls=\(.urls|join(","))\tips=\([.configurations[].value]|join(","))\tpaused=\(.paused)\t\(.description // "")"' "No lockdown rules found."
}

cmd_lockdown_create() {
  resolveZone
  requireOpt urls ips
  local confs body
  confs="$(toJsonArray "$(opt ips)" | jq -c 'map({target:(if contains("/") then "ip_range" else "ip" end), value:.})')"
  body="$(jq -cn --argjson u "$(toJsonArray "$(opt urls)")" --argjson c "$confs" --arg d "$(opt description "Created by ${PROGRAM_NAME}")" --argjson p "$(optBool paused false)" '{urls:$u, configurations:$c, description:$d, paused:$p}')"
  cfApi POST "/zones/${CF_ZONE_ID}/firewall/lockdowns" "$body"
  emitResult "$(cfResult)" '"id=\(.id)\nurls=\(.urls|join(","))\nips=\([.configurations[].value]|join(","))\npaused=\(.paused)"'
}

cmd_lockdown_delete() {
  resolveZone
  requireOpt id
  confirm "Delete lockdown rule $(opt id)?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/zones/${CF_ZONE_ID}/firewall/lockdowns/$(opt id)"
  emitMessage "Lockdown rule $(opt id) deleted." "$(jq -cn --arg id "$(opt id)" '{id:$id}')"
}

#####################################################################################################################VDM
######################################## Bot management

BOT_TEMPLATE='to_entries[] | select(.key | IN("fight_mode","enable_js","ai_bots_protection","crawler_protection","sbfm_definitely_automated","sbfm_likely_automated","sbfm_verified_bots","sbfm_static_resource_protection","optimize_wordpress","using_latest_model")) | "\(.key)=\(.value|tostring)"'

cmd_bot_status() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/bot_management"
  emitResult "$(cfResult)" "$BOT_TEMPLATE"
}

# botUpdate - PUT bot management config with the given JSON patch
botUpdate() {
  resolveZone
  cfApi PUT "/zones/${CF_ZONE_ID}/bot_management" "$1"
  emitResult "$(cfResult)" "$BOT_TEMPLATE"
}

cmd_bot_fight_mode() {
  local value
  value="$(opt value)"
  [[ -z "$value" && -n "${ARGS[2]:-}" ]] && value="${ARGS[2]}"
  [[ -z "$value" ]] && die "Usage: bot fight-mode on|off" "$EX_ARGS"
  botUpdate "$(jq -cn --argjson v "$(normalizeBool "$value")" '{fight_mode:$v}')"
}

cmd_bot_ai_bots() {
  local value
  value="$(opt value)"
  [[ -z "$value" && -n "${ARGS[2]:-}" ]] && value="${ARGS[2]}"
  [[ -z "$value" ]] && die "Usage: bot ai-bots block|disabled|only_on_ad_pages" "$EX_ARGS"
  case "$(normalizeBool "$value")" in
    true) [[ "$value" != "only_on_ad_pages" ]] && value=block ;;
    false) [[ "$value" != "only_on_ad_pages" ]] && value=disabled ;;
  esac
  botUpdate "$(jq -cn --arg v "$value" '{ai_bots_protection:$v}')"
}

cmd_bot_set() {
  local settings
  settings="$(inputFromOpts settings)" || exit $?
  [[ -z "$settings" ]] && die "Provide --settings='{\"fight_mode\":true}'" "$EX_ARGS"
  botUpdate "$(printf '%s' "$settings" | jq -c .)"
}
