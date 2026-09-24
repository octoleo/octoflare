#!/usr/bin/env bash
# Octoflare module: rules
#
# Cloudflare Rulesets engine. A generic "rule" resource works with any phase,
# and friendly wrappers cover the free-plan phases: single redirects, custom
# firewall (WAF) rules, rate limiting, URL/header transforms, cache rules,
# configuration rules and origin rules.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand rule phases "" "List the ruleset phases and their aliases"
registerCommand rule rulesets "--domain=<zone> [--scope=account]" "List every ruleset of the zone (or account)"
registerCommand rule list "--domain=<zone> --phase=<phase>" "List the rules of a phase"
registerCommand rule get "--domain=<zone> --phase=<phase> (--id=<rule-id> | --description=<text>)" "Show one rule"
registerCommand rule create "--domain=<zone> --phase=<phase> --expression=<filter> --action=<action> [--action-parameters=<json>] [--description=<text>] [--enabled=false]" "Add a rule to a phase"
registerCommand rule upsert "--domain=<zone> --phase=<phase> --expression=<filter> --action=<action> [...]" "Add the rule or update the one with the same description/expression"
registerCommand rule update "--domain=<zone> --phase=<phase> --id=<rule-id> [--expression=] [--action=] [--action-parameters=] [--description=] [--enabled=]" "Update a rule"
registerCommand rule delete "--domain=<zone> --phase=<phase> (--id=<rule-id> | --description=<text>)" "Delete a rule"
registerCommand rule enable "--domain=<zone> --phase=<phase> (--id=<rule-id> | --description=<text>)" "Enable a rule"
registerCommand rule disable "--domain=<zone> --phase=<phase> (--id=<rule-id> | --description=<text>)" "Disable a rule"
registerCommand rule apply "--domain=<zone> --phase=<phase> --file=<rules.json>" "Replace all rules of a phase with the given list (declarative)"
registerCommand rule export "--domain=<zone> --phase=<phase>" "Export the rules of a phase as JSON (input for 'rule apply')"

registerCommand redirect list "--domain=<zone>" "List single redirects"
registerCommand redirect create "--domain=<zone> --from=<path|url|host> --to=<url> [--status=301] [--preserve-query] [--preserve-path] [--match=exact|prefix|wildcard|regex] [--description=<text>]" "Create a single redirect (a '*' in the host or path of --from matches as a wildcard; a query string in --from is ignored)"
registerCommand redirect upsert "--domain=<zone> --from=<path|url|host> --to=<url> [--status=301] [...]" "Create or update the redirect for --from (idempotent)"
registerCommand redirect update "--domain=<zone> --id=<rule-id> [--to=] [--status=] [--enabled=] [--description=]" "Update a redirect"
registerCommand redirect delete "--domain=<zone> (--id=<rule-id> | --from=<path|url|host> | --description=<text>)" "Delete a redirect"
registerCommand redirect enable "--domain=<zone> (--id=<rule-id> | --from=<path> | --description=<text>)" "Enable a redirect"
registerCommand redirect disable "--domain=<zone> (--id=<rule-id> | --from=<path> | --description=<text>)" "Disable a redirect"

registerCommand firewall list "--domain=<zone>" "List custom firewall (WAF) rules"
registerCommand firewall create "--domain=<zone> --action=block|challenge|js_challenge|managed_challenge|log|skip (--expression=<filter> | --countries=CN,RU --ips=<a,b> --asns=<n,n> --paths=<a,b> --hosts=<a,b> --methods=<a,b> --user-agents=<a,b>) [--not] [--description=<text>]" "Create a custom firewall rule"
registerCommand firewall upsert "--domain=<zone> --action=<action> --expression=<filter> [--description=<text>]" "Create or update the rule with the same description/expression"
registerCommand firewall update "--domain=<zone> --id=<rule-id> [--action=] [--expression=] [--description=] [--enabled=]" "Update a custom firewall rule"
registerCommand firewall delete "--domain=<zone> (--id=<rule-id> | --description=<text>)" "Delete a custom firewall rule"
registerCommand firewall enable "--domain=<zone> (--id=<rule-id> | --description=<text>)" "Enable a custom firewall rule"
registerCommand firewall disable "--domain=<zone> (--id=<rule-id> | --description=<text>)" "Disable a custom firewall rule"

registerCommand ratelimit list "--domain=<zone>" "List rate limiting rules"
registerCommand ratelimit create "--domain=<zone> --expression=<filter> --requests=<n> [--period=10] [--timeout=10] [--action=block|managed_challenge|log] [--characteristics=ip.src,cf.colo.id] [--description=<text>]" "Create a rate limiting rule"
registerCommand ratelimit upsert "--domain=<zone> --expression=<filter> --requests=<n> [...]" "Create or update the rate limiting rule"
registerCommand ratelimit delete "--domain=<zone> (--id=<rule-id> | --description=<text>)" "Delete a rate limiting rule"
registerCommand ratelimit enable "--domain=<zone> (--id=<rule-id> | --description=<text>)" "Enable a rate limiting rule"
registerCommand ratelimit disable "--domain=<zone> (--id=<rule-id> | --description=<text>)" "Disable a rate limiting rule"

registerCommand transform list "--domain=<zone> [--kind=url|request-headers|response-headers]" "List transform rules"
registerCommand transform url "--domain=<zone> --expression=<filter> (--path=<static> | --path-expression=<expr>) [--query=<static> | --query-expression=<expr>] [--description=<text>]" "Create/update a URL rewrite rule"
registerCommand transform request-header "--domain=<zone> --expression=<filter> [--set=Name=Value] [--headers=<json>] [--remove=Name,Name] [--description=<text>]" "Create/update a request header modification rule"
registerCommand transform response-header "--domain=<zone> --expression=<filter> [--set=Name=Value] [--headers=<json>] [--remove=Name,Name] [--description=<text>]" "Create/update a response header modification rule"
registerCommand transform delete "--domain=<zone> --kind=url|request-headers|response-headers (--id=<rule-id> | --description=<text>)" "Delete a transform rule"

registerCommand cache-rule list "--domain=<zone>" "List cache rules"
registerCommand cache-rule create "--domain=<zone> --expression=<filter> [--cache=true|false] [--edge-ttl=<sec>|respect|bypass] [--browser-ttl=<sec>|respect|bypass] [--action-parameters=<json>] [--description=<text>]" "Create a cache rule"
registerCommand cache-rule upsert "--domain=<zone> --expression=<filter> [...]" "Create or update a cache rule"
registerCommand cache-rule delete "--domain=<zone> (--id=<rule-id> | --description=<text>)" "Delete a cache rule"

registerCommand config-rule list "--domain=<zone>" "List configuration rules"
registerCommand config-rule create "--domain=<zone> --expression=<filter> [--ssl=strict] [--security-level=high] [--rocket-loader=false] [--settings=<json>] [--description=<text>]" "Create a configuration rule"
registerCommand config-rule upsert "--domain=<zone> --expression=<filter> [...]" "Create or update a configuration rule"
registerCommand config-rule delete "--domain=<zone> (--id=<rule-id> | --description=<text>)" "Delete a configuration rule"

registerCommand origin-rule list "--domain=<zone>" "List origin rules"
registerCommand origin-rule create "--domain=<zone> --expression=<filter> [--host-header=<host>] [--origin-host=<host>] [--origin-port=<port>] [--sni=<host>] [--description=<text>]" "Create an origin rule"
registerCommand origin-rule upsert "--domain=<zone> --expression=<filter> [...]" "Create or update an origin rule"
registerCommand origin-rule delete "--domain=<zone> (--id=<rule-id> | --description=<text>)" "Delete an origin rule"

RULE_TEMPLATE='.[] | "\(.id)\tenabled=\(.enabled)\t\(.action)\t\(.description // "-")\t\(.expression)"'
RULE_ONE='"id=\(.id)\nenabled=\(.enabled)\naction=\(.action)\ndescription=\(.description // "-")\nexpression=\(.expression)\naction_parameters=\((.action_parameters // {}) | tostring)\(if .ratelimit then "\nratelimit=" + (.ratelimit|tostring) else "" end)\nlast_updated=\(.last_updated // "-")\(if .action then "\naction_result=" + (.action_result // "-") else "" end)"'
REDIRECT_TEMPLATE='.[] | "\(.id)\tenabled=\(.enabled)\t\(.action_parameters.from_value.status_code // "-")\t\(.expression) -> \(.action_parameters.from_value.target_url.value // .action_parameters.from_value.target_url.expression // "-")\t\(.description // "")"'

RS_ID=""
RS_RULES="[]"
RS_BASE=""

#####################################################################################################################VDM
######################################## Generic ruleset helpers

# rulePhaseAlias - Map a friendly name to a ruleset phase
rulePhaseAlias() {
  case "$(lower "$1")" in
    redirect|redirects|single-redirect|dynamic_redirect) echo http_request_dynamic_redirect ;;
    firewall|custom|waf|custom-rules|firewall_custom) echo http_request_firewall_custom ;;
    ratelimit|rate-limit|rate_limit) echo http_ratelimit ;;
    transform|url|url-rewrite|rewrite) echo http_request_transform ;;
    request-headers|request_headers|request-header|late_transform) echo http_request_late_transform ;;
    response-headers|response_headers|response-header|headers) echo http_response_headers_transform ;;
    cache|cache-rule|cache-rules|cache_settings) echo http_request_cache_settings ;;
    config|config-rule|configuration|config_settings) echo http_config_settings ;;
    origin|origin-rule|origin-rules) echo http_request_origin ;;
    compression) echo http_response_compression ;;
    bulk-redirect|bulk_redirect) echo http_request_redirect ;;
    *) echo "$1" ;;
  esac
}

# rulePhase - The phase requested with --phase (aliases allowed)
rulePhase() {
  local p
  p="$(opt phase)"
  [[ -z "$p" ]] && die "Missing --phase=<phase> (run 'octoflare rule phases' for the list)" "$EX_ARGS"
  rulePhaseAlias "$p"
}

# ruleScopePath - Set RS_BASE to /zones/<id> or /accounts/<id> depending on --scope
ruleScopePath() {
  if [[ "$(opt scope)" == "account" ]]; then
    resolveAccount
    RS_BASE="/accounts/${CF_ACCOUNT_ID}"
  else
    resolveZone
    RS_BASE="/zones/${CF_ZONE_ID}"
  fi
}

# ruleKind - Ruleset kind for the scope
ruleKind() {
  if [[ "$(opt scope)" == "account" ]]; then echo root; else echo zone; fi
}

# rulesetLoad - Load the entrypoint ruleset of a phase into RS_ID and RS_RULES (empty when none exists yet)
rulesetLoad() {
  local phase="$1" base
  ruleScopePath
  base="$RS_BASE"
  RS_ID=""
  RS_RULES="[]"
  if cfApiTry GET "${base}/rulesets/phases/${phase}/entrypoint"; then
    RS_ID="$(cfResultRaw '.result.id // empty')"
    RS_RULES="$(cfResult '.result.rules // []')"
    return 0
  fi
  [[ "$CF_HTTP_CODE" == "404" ]] && return 0
  cfReportError
  exit "$EX_FAILURE"
}

# ruleFromOptions - Build a rule JSON from the generic options (--expression, --action, ...)
ruleFromOptions() {
  local rule='{}' params
  hasOpt expression && rule="$(jq -cn --argjson r "$rule" --arg v "$(opt expression)" '$r + {expression:$v}')"
  hasOpt action && rule="$(jq -cn --argjson r "$rule" --arg v "$(opt action)" '$r + {action:$v}')"
  if hasOpt action-parameters; then
    params="$(readFileOrValue "$(opt action-parameters)")"
    rule="$(jq -cn --argjson r "$rule" --argjson v "$params" '$r + {action_parameters:$v}')"
  fi
  hasOpt description && rule="$(jq -cn --argjson r "$rule" --arg v "$(opt description)" '$r + {description:$v}')"
  hasOpt enabled && rule="$(jq -cn --argjson r "$rule" --argjson v "$(optBool enabled true)" '$r + {enabled:$v}')"
  hasOpt ref && rule="$(jq -cn --argjson r "$rule" --arg v "$(opt ref)" '$r + {ref:$v}')"
  printf '%s' "$rule"
}

# ruleWithDefaults - Ensure enabled/description defaults on a new rule
ruleWithDefaults() {
  jq -cn --argjson r "$1" --arg d "$2" '{enabled:true, description:$d} + $r'
}

# rulesetFind - Print the first rule matching --id / --ref / --description, or the given expression
#
# Arguments:
#   $1: expression to match when no --id/--ref/--description was given (optional)
rulesetFind() {
  local expression="${1:-}"
  if hasOpt id; then
    printf '%s' "$RS_RULES" | jq -c --arg v "$(opt id)" '[.[] | select(.id == $v)][0] // empty'
  elif hasOpt ref; then
    printf '%s' "$RS_RULES" | jq -c --arg v "$(opt ref)" '[.[] | select(.ref == $v)][0] // empty'
  elif hasOpt description; then
    printf '%s' "$RS_RULES" | jq -c --arg v "$(opt description)" '[.[] | select(.description == $v)][0] // empty'
  elif [[ -n "$expression" ]]; then
    printf '%s' "$RS_RULES" | jq -c --arg v "$expression" '[.[] | select(.expression == $v)][0] // empty'
  fi
}

# rulesetRequire - Like rulesetFind but exits when nothing matches
rulesetRequire() {
  local found
  found="$(rulesetFind "${1:-}")"
  if [[ -z "$found" ]]; then
    if [[ "$OCTOFLARE_DRY_RUN" == "true" ]]; then
      jq -cn --arg e "${1:-}" '{id:"dry-run-rule-id", expression:$e, action:"dry-run", enabled:true}'
      return 0
    fi
    die "No rule found matching $(hasOpt id && printf 'id %s' "$(opt id)" || hasOpt description && printf 'description "%s"' "$(opt description)" || printf 'expression "%s"' "${1:-}")" "$EX_NOTFOUND"
  fi
  printf '%s' "$found"
}

# rulesetAdd - Append a rule to the phase (creating the ruleset when needed); result = the new rule
rulesetAdd() {
  local phase="$1" rule="$2" base
  ruleScopePath
  base="$RS_BASE"
  [[ -z "$RS_ID" ]] && rulesetLoad "$phase"
  if [[ -n "$RS_ID" ]]; then
    cfApi POST "${base}/rulesets/${RS_ID}/rules" "$rule"
    CF_RESPONSE="$(cfResult '{success:true, result:((.result.rules // [])[-1] // .result)}')"
  else
    cfApi POST "${base}/rulesets" "$(jq -cn --arg p "$phase" --arg k "$(ruleKind)" --argjson r "$rule" '{name:("Octoflare " + $p), kind:$k, phase:$p, description:"Managed by Octoflare", rules:[$r]}')"
    CF_RESPONSE="$(cfResult '{success:true, result:((.result.rules // [])[0] // .result)}')"
  fi
}

# rulesetPatch - Merge a patch into an existing rule and PATCH it; result = the updated rule
rulesetPatch() {
  local phase="$1" id="$2" patch="$3" base existing merged
  ruleScopePath
  base="$RS_BASE"
  [[ -z "$RS_ID" ]] && rulesetLoad "$phase"
  existing="$(printf '%s' "$RS_RULES" | jq -c --arg id "$id" '[.[] | select(.id == $id)][0] // {} | {action, action_parameters, expression, description, enabled, ratelimit, logging, ref} | with_entries(select(.value != null))')"
  merged="$(jq -cn --argjson e "$existing" --argjson p "$patch" '$e + $p')"
  cfApi PATCH "${base}/rulesets/${RS_ID}/rules/${id}" "$merged"
  CF_RESPONSE="$(printf '%s' "$CF_RESPONSE" | jq -c --arg id "$id" '{success:true, result:(([.result.rules[]? | select(.id == $id)][0]) // .result)}')"
}

# rulesetDelete - Delete a rule by id
rulesetDelete() {
  local phase="$1" id="$2" base
  ruleScopePath
  base="$RS_BASE"
  [[ -z "$RS_ID" ]] && rulesetLoad "$phase"
  [[ -z "$RS_ID" && "$OCTOFLARE_DRY_RUN" == "true" ]] && RS_ID="dry-run-ruleset-id"
  cfApi DELETE "${base}/rulesets/${RS_ID}/rules/${id}"
}

# ruleSignature - The fields compared to decide whether an upsert changes anything
ruleSignature() {
  printf '%s' "$1" | jq -cS '{action, action_parameters:(.action_parameters // null), expression, description:(.description // null), enabled:(if .enabled == null then true else .enabled end), ratelimit:(.ratelimit // null), logging:(.logging // null)}'
}

# rulesetUpsert - Create the rule or update the matching one (by --id, --description, else expression)
#
# Arguments:
#   $1: phase
#   $2: rule JSON (must contain expression and action)
#   $3: template for the result (optional)
rulesetUpsert() {
  local phase="$1" rule="$2" template="${3:-$RULE_ONE}" existing id
  rulesetLoad "$phase"
  existing="$(rulesetFind "$(printf '%s' "$rule" | jq -r '.expression')")"
  if [[ -z "$existing" ]]; then
    logInfo "Creating rule in ${phase}..."
    rulesetAdd "$phase" "$rule"
    emitResult "$(cfResult '.result + {action_result:"created"}')" "$template"
    return 0
  fi
  id="$(printf '%s' "$existing" | jq -r '.id')"
  if [[ "$(ruleSignature "$existing")" == "$(ruleSignature "$(jq -cn --argjson e "$existing" --argjson r "$rule" '$e + $r')")" ]]; then
    logInfo "Rule ${id} in ${phase} is already up to date."
    emitResult "$(printf '%s' "$existing" | jq -c '. + {action_result:"unchanged"}')" "$template"
    return 0
  fi
  logInfo "Updating rule ${id} in ${phase}..."
  rulesetPatch "$phase" "$id" "$rule"
  emitResult "$(cfResult '.result + {action_result:"updated"}')" "$template"
}

# rulesetCreate - Always add a new rule
rulesetCreate() {
  local phase="$1" rule="$2" template="${3:-$RULE_ONE}"
  logInfo "Creating rule in ${phase}..."
  rulesetAdd "$phase" "$rule"
  emitResult "$(cfResult '.result + {action_result:"created"}')" "$template"
}

# rulesetCreateOrUpsert - Dispatch on the action name (create vs upsert)
rulesetCreateOrUpsert() {
  local mode="$1" phase="$2" rule="$3" template="${4:-$RULE_ONE}"
  if [[ "$mode" == "upsert" ]]; then
    rulesetUpsert "$phase" "$rule" "$template"
  else
    rulesetCreate "$phase" "$rule" "$template"
  fi
}

# rulesetList - Emit the rules of a phase
rulesetList() {
  local phase="$1" template="${2:-$RULE_TEMPLATE}"
  rulesetLoad "$phase"
  emitResult "$RS_RULES" "$template" "No rules in ${phase}."
}

# rulesetDeleteCmd - Delete the rule selected by --id/--description/expression
rulesetDeleteCmd() {
  local phase="$1" expression="${2:-}" rule id
  rulesetLoad "$phase"
  rule="$(rulesetFind "$expression")"
  if [[ -z "$rule" ]]; then
    [[ "$(optBool if-exists)" == "true" ]] && { emitMessage "No matching rule in ${phase}; nothing to delete."; return 0; }
    [[ "$OCTOFLARE_DRY_RUN" == "true" ]] && rule='{"id":"dry-run-rule-id"}'
    [[ -z "$rule" ]] && die "No matching rule found in ${phase}" "$EX_NOTFOUND"
  fi
  id="$(printf '%s' "$rule" | jq -r '.id')"
  confirm "Delete rule ${id} from ${phase}?" || die "Cancelled." "$EX_OK"
  rulesetDelete "$phase" "$id"
  emitMessage "Rule ${id} deleted from ${phase}." "$(jq -cn --arg id "$id" '{id:$id}')"
}

# rulesetToggle - Enable or disable the selected rule
rulesetToggle() {
  local phase="$1" enabled="$2" expression="${3:-}" rule id
  rulesetLoad "$phase"
  rule="$(rulesetRequire "$expression")" || exit $?
  id="$(printf '%s' "$rule" | jq -r '.id')"
  rulesetPatch "$phase" "$id" "{\"enabled\":${enabled}}"
  emitResult "$(cfResult)" "$RULE_ONE"
}

#####################################################################################################################VDM
######################################## Generic "rule" commands

cmd_rule_phases() {
  local json='[
    {"phase":"http_request_dynamic_redirect","alias":"redirect","description":"Single Redirects"},
    {"phase":"http_request_firewall_custom","alias":"firewall","description":"Custom WAF rules"},
    {"phase":"http_ratelimit","alias":"ratelimit","description":"Rate limiting rules"},
    {"phase":"http_request_transform","alias":"url","description":"URL rewrite (transform) rules"},
    {"phase":"http_request_late_transform","alias":"request-headers","description":"Request header modification rules"},
    {"phase":"http_response_headers_transform","alias":"response-headers","description":"Response header modification rules"},
    {"phase":"http_request_cache_settings","alias":"cache","description":"Cache rules"},
    {"phase":"http_config_settings","alias":"config","description":"Configuration rules"},
    {"phase":"http_request_origin","alias":"origin","description":"Origin rules"},
    {"phase":"http_response_compression","alias":"compression","description":"Compression rules"},
    {"phase":"http_request_redirect","alias":"bulk-redirect","description":"Bulk redirects (account scope)"},
    {"phase":"http_request_sbfm","alias":"","description":"Super Bot Fight Mode"},
    {"phase":"http_request_firewall_managed","alias":"","description":"Managed WAF rulesets (paid plans)"},
    {"phase":"http_custom_errors","alias":"","description":"Custom error responses (paid plans)"}
  ]'
  emitResult "$(printf '%s' "$json" | jq -c .)" '.[] | "\(.phase)\t\(.alias)\t\(.description)"'
}

cmd_rule_rulesets() {
  local base
  ruleScopePath
  base="$RS_BASE"
  cfApiCursor "${base}/rulesets"
  emitResult "$(cfResult)" '.[] | "\(.id)\t\(.phase)\t\(.kind)\t\(.name)\tv\(.version)"' "No rulesets found."
}

cmd_rule_list() {
  local phase
  phase="$(rulePhase)" || exit $?
  rulesetList "$phase"
}

cmd_rule_get() {
  local phase rule
  phase="$(rulePhase)" || exit $?
  rulesetLoad "$phase"
  rule="$(rulesetRequire "$(opt expression)")" || exit $?
  emitResult "$rule" "$RULE_ONE"
}

cmd_rule_create() {
  requireOpt expression action
  local phase
  phase="$(rulePhase)" || exit $?
  rulesetCreate "$phase" "$(ruleWithDefaults "$(ruleFromOptions)" "Created by ${PROGRAM_NAME}")"
}

cmd_rule_upsert() {
  requireOpt expression action
  local phase
  phase="$(rulePhase)" || exit $?
  rulesetUpsert "$phase" "$(ruleWithDefaults "$(ruleFromOptions)" "Created by ${PROGRAM_NAME}")"
}

cmd_rule_update() {
  requireOpt id
  local phase patch
  phase="$(rulePhase)" || exit $?
  patch="$(ruleFromOptions)"
  [[ "$patch" == "{}" ]] && die "Nothing to update: provide --expression, --action, --action-parameters, --description or --enabled" "$EX_ARGS"
  rulesetLoad "$phase"
  rulesetPatch "$phase" "$(opt id)" "$patch"
  emitResult "$(cfResult)" "$RULE_ONE"
}

cmd_rule_delete() { local p; p="$(rulePhase)" || exit $?; rulesetDeleteCmd "$p" "$(opt expression)"; }
cmd_rule_enable() { local p; p="$(rulePhase)" || exit $?; rulesetToggle "$p" true "$(opt expression)"; }
cmd_rule_disable() { local p; p="$(rulePhase)" || exit $?; rulesetToggle "$p" false "$(opt expression)"; }

cmd_rule_apply() {
  local phase rules base
  phase="$(rulePhase)" || exit $?
  rules="$(inputFromOpts rules)" || exit $?
  [[ -z "$rules" ]] && die "Provide the rules with --file=<rules.json> (a JSON array of rules)" "$EX_ARGS"
  rules="$(printf '%s' "$rules" | jq -c 'if type=="array" then . else (.rules // []) end | map(del(.id, .version, .last_updated, .ref?))')" || die "Rules must be a JSON array" "$EX_ARGS"
  ruleScopePath
  base="$RS_BASE"
  logInfo "Replacing the rules of ${phase} with $(printf '%s' "$rules" | jq 'length') rule(s)..."
  cfApi PUT "${base}/rulesets/phases/${phase}/entrypoint" "$(jq -cn --argjson r "$rules" '{rules:$r}')"
  emitResult "$(cfResult '.result.rules // []')" "$RULE_TEMPLATE"
}

cmd_rule_export() {
  local phase
  phase="$(rulePhase)" || exit $?
  rulesetLoad "$phase"
  setOpt output json
  OCTOFLARE_OUTPUT=json
  emitResult "$(printf '%s' "$RS_RULES" | jq -c 'map({expression, action, action_parameters, description, enabled, ratelimit, logging} | with_entries(select(.value != null)))')"
}

#####################################################################################################################VDM
######################################## Single redirects

REDIRECT_PHASE="http_request_dynamic_redirect"

# quoteExpr - Quote a string for a Cloudflare filter expression
#
# JSON string escaping matches the rules-language escapes (\\ and \"), and jq behaves the
# same on every Bash version (a quoted ${v//\\/\\\\} replacement does not double
# backslashes on Bash < 4.3).
quoteExpr() {
  jq -rn --arg v "$1" '$v | tojson'
}

# listItems - Print the items of a comma-separated list, one per line, trimmed, without word-splitting or globbing
listItems() {
  toJsonArray "$1" | jq -r '.[]'
}

FROM_HOST=""
FROM_PATH=""

# redirectParseFrom - Split a --from value (path, URL or host[/path]) into FROM_HOST and FROM_PATH
#
# The host is lowercased (http.host is always lowercase). A query string or fragment is
# dropped: http.request.uri.path never contains them, so an expression built from
# "/docs?x=1" could never match.
redirectParseFrom() {
  local from="$1" rest
  FROM_HOST=""
  FROM_PATH=""
  if [[ "$from" =~ ^https?:// ]]; then
    rest="${from#*://}"
    FROM_HOST="${rest%%/*}"
    [[ "$rest" == */* ]] && FROM_PATH="/${rest#*/}"
  elif [[ "$from" == /* ]]; then
    FROM_PATH="$from"
  else
    FROM_HOST="${from%%/*}"
    [[ "$from" == */* ]] && FROM_PATH="/${from#*/}"
  fi
  FROM_HOST="$(lower "${FROM_HOST%%\?*}")"
  FROM_HOST="${FROM_HOST%%#*}"
  if [[ "$FROM_PATH" == *[\?#]* ]]; then
    [[ "$FROM_PATH" == *\?* ]] && logWarn "Ignoring the query string of --from=${from}: redirects match the path only (use --expression to match on http.request.uri.query)"
    FROM_PATH="${FROM_PATH%%\?*}"
    FROM_PATH="${FROM_PATH%%#*}"
  fi
}

# redirectExpression - Build the matching expression from --from (path, URL or host) and --match
redirectExpression() {
  local from host="" path="" match parts=()
  if hasOpt expression; then
    printf '%s' "$(opt expression)"
    return 0
  fi
  from="$(optFirst "" from source)"
  host="$(lower "$(opt host)")"
  match="$(opt match exact)"
  [[ -z "$from" ]] && die "Missing --from=<path|url|hostname> (or --expression=<filter>)" "$EX_ARGS"
  redirectParseFrom "$from"
  [[ -n "$FROM_HOST" ]] && host="$FROM_HOST"
  path="$FROM_PATH"
  [[ "$path" == *\** && "$match" == "exact" ]] && match=wildcard
  if [[ "$host" == *\** ]]; then
    parts+=("http.host wildcard $(quoteExpr "$host")")
  elif [[ -n "$host" ]]; then
    parts+=("http.host eq $(quoteExpr "$host")")
  fi
  if [[ -n "$path" ]]; then
    case "$match" in
      exact) parts+=("http.request.uri.path eq $(quoteExpr "$path")") ;;
      prefix) parts+=("starts_with(http.request.uri.path, $(quoteExpr "$path"))") ;;
      wildcard) parts+=("http.request.uri.path wildcard $(quoteExpr "$path")") ;;
      regex) parts+=("http.request.uri.path matches $(quoteExpr "$path")") ;;
      *) die "Invalid --match=${match} (expected exact, prefix, wildcard or regex)" "$EX_ARGS" ;;
    esac
  fi
  [[ ${#parts[@]} -eq 0 ]] && die "Could not build a matching expression from --from=${from}" "$EX_ARGS"
  local IFS=' '
  if [[ ${#parts[@]} -eq 1 ]]; then
    printf '%s' "${parts[0]}"
  else
    printf '(%s)' "$(printf '%s' "${parts[0]}")"
    local i
    for ((i = 1; i < ${#parts[@]}; i++)); do
      printf ' and (%s)' "${parts[$i]}"
    done
  fi
}

# redirectTarget - Build the target_url object from --to (static) or --to-expression / --preserve-path
redirectTarget() {
  local to from path
  if hasOpt to-expression; then
    jq -cn --arg e "$(opt to-expression)" '{expression:$e}'
    return 0
  fi
  to="$(optFirst "" to target destination)"
  [[ -z "$to" ]] && die "Missing --to=<url> (or --to-expression=<expr>)" "$EX_ARGS"
  if [[ "$(optBool preserve-path)" == "true" ]]; then
    jq -cn --arg e "concat($(quoteExpr "${to%/}"), http.request.uri.path)" '{expression:$e}'
  elif [[ "$to" == *"\${"* ]]; then
    from="$(optFirst "" from source)"
    redirectParseFrom "$from" 2>/dev/null
    path="$FROM_PATH"
    [[ -z "$path" ]] && die "A wildcard target (--to=${to}) needs a path pattern in --from (e.g. --from='/blog/*' or --from='old.example.com/blog/*')" "$EX_ARGS"
    jq -cn --arg e "wildcard_replace(http.request.uri.path, $(quoteExpr "$path"), $(quoteExpr "$to"))" '{expression:$e}'
  else
    jq -cn --arg v "$to" '{value:$v}'
  fi
}

# redirectRule - Full redirect rule JSON from the options
redirectRule() {
  local expression target status description
  expression="$(redirectExpression)" || exit $?
  target="$(redirectTarget)" || exit $?
  status="$(optFirst 301 status status-code code)"
  description="$(opt description "Redirect $(optFirst "" from source) -> $(optFirst "" to target destination)")"
  jq -cn --arg e "$expression" --argjson t "$target" --argjson s "$status" --argjson q "$(optBool preserve-query false)" --arg d "$description" --argjson en "$(optBool enabled true)" \
    '{expression:$e, action:"redirect", action_parameters:{from_value:{target_url:$t, status_code:$s, preserve_query_string:$q}}, description:$d, enabled:$en}'
}

cmd_redirect_list() { rulesetList "$REDIRECT_PHASE" "$REDIRECT_TEMPLATE"; }
cmd_redirect_create() { local r; r="$(redirectRule)" || exit $?; rulesetCreate "$REDIRECT_PHASE" "$r"; }
cmd_redirect_upsert() { local r; r="$(redirectRule)" || exit $?; rulesetUpsert "$REDIRECT_PHASE" "$r"; }

cmd_redirect_update() {
  requireOpt id
  local patch='{}' existing target status expr
  rulesetLoad "$REDIRECT_PHASE"
  existing="$(rulesetRequire)" || exit $?
  if hasOpt to || hasOpt to-expression || hasOpt status || hasOpt status-code || hasOpt preserve-query; then
    target="$(printf '%s' "$existing" | jq -c '.action_parameters.from_value.target_url // {}')"
    if hasOpt to || hasOpt to-expression; then target="$(redirectTarget)" || exit $?; fi
    status="$(optFirst "$(printf '%s' "$existing" | jq -r '.action_parameters.from_value.status_code // 301')" status status-code)"
    patch="$(jq -cn --argjson t "$target" --argjson s "$status" --argjson q "$(optBool preserve-query "$(printf '%s' "$existing" | jq -r '.action_parameters.from_value.preserve_query_string // false')")" \
      '{action_parameters:{from_value:{target_url:$t, status_code:$s, preserve_query_string:$q}}}')"
  fi
  if hasOpt from || hasOpt expression; then
    expr="$(redirectExpression)" || exit $?
    patch="$(jq -cn --argjson p "$patch" --arg e "$expr" '$p + {expression:$e}')"
  fi
  hasOpt description && patch="$(jq -cn --argjson p "$patch" --arg d "$(opt description)" '$p + {description:$d}')"
  hasOpt enabled && patch="$(jq -cn --argjson p "$patch" --argjson v "$(optBool enabled)" '$p + {enabled:$v}')"
  [[ "$patch" == "{}" ]] && die "Nothing to update" "$EX_ARGS"
  rulesetPatch "$REDIRECT_PHASE" "$(opt id)" "$patch"
  emitResult "$(cfResult)" "$RULE_ONE"
}

# redirectSelector - Expression used to find a redirect when neither --id nor --description is given
redirectSelector() {
  if ! hasOpt id && ! hasOpt description && { hasOpt from || hasOpt expression; }; then
    redirectExpression
  fi
}

cmd_redirect_delete() { local s; s="$(redirectSelector)" || exit $?; rulesetDeleteCmd "$REDIRECT_PHASE" "$s"; }
cmd_redirect_enable() { local s; s="$(redirectSelector)" || exit $?; rulesetToggle "$REDIRECT_PHASE" true "$s"; }
cmd_redirect_disable() { local s; s="$(redirectSelector)" || exit $?; rulesetToggle "$REDIRECT_PHASE" false "$s"; }

#####################################################################################################################VDM
######################################## Custom firewall rules

FIREWALL_PHASE="http_request_firewall_custom"

# exprSet - Build a `field in {...}` clause from a comma separated list
#
# Arguments:
#   $1: field
#   $2: list
#   $3: "string" (quote values) or "raw"
exprSet() {
  local field="$1" list="$2" kind="$3" item out=""
  while IFS= read -r item; do
    if [[ "$kind" == "string" ]]; then
      out="${out} $(quoteExpr "$item")"
    else
      out="${out} ${item}"
    fi
  done < <(listItems "$list")
  printf '%s in {%s}' "$field" "${out# }"
}

# firewallExpression - Build the expression from --expression or the convenience filters
firewallExpression() {
  local parts=() list expr i
  if hasOpt expression; then
    expr="$(opt expression)"
  else
    list="$(opt countries)"; [[ -n "$list" ]] && parts+=("$(exprSet ip.geoip.country "$(printf '%s' "$list" | tr '[:lower:]' '[:upper:]')" string)")
    list="$(optFirst "" ips ip)"; [[ -n "$list" ]] && parts+=("$(exprSet ip.src "$list" raw)")
    list="$(optFirst "" asns asn)"; [[ -n "$list" ]] && parts+=("$(exprSet ip.geoip.asnum "$(printf '%s' "$list" | tr -d 'ASas')" raw)")
    list="$(optFirst "" paths path)"; [[ -n "$list" ]] && parts+=("$(exprSet http.request.uri.path "$list" string)")
    list="$(optFirst "" path-prefixes path-prefix)"
    if [[ -n "$list" ]]; then
      expr=""
      while IFS= read -r i; do expr="${expr} or starts_with(http.request.uri.path, $(quoteExpr "$i"))"; done < <(listItems "$list")
      parts+=("(${expr# or })")
    fi
    list="$(optFirst "" hosts host)"; [[ -n "$list" ]] && parts+=("$(exprSet http.host "$list" string)")
    list="$(optFirst "" methods method)"; [[ -n "$list" ]] && parts+=("$(exprSet http.request.method "$(printf '%s' "$list" | tr '[:lower:]' '[:upper:]')" string)")
    list="$(optFirst "" user-agents user-agent)"
    if [[ -n "$list" ]]; then
      expr=""
      while IFS= read -r i; do expr="${expr} or http.user_agent contains $(quoteExpr "$i")"; done < <(listItems "$list")
      parts+=("(${expr# or })")
    fi
    [[ "$(optBool bots)" == "true" ]] && parts+=("cf.client.bot")
    [[ -n "$(opt threat-score)" ]] && parts+=("cf.threat_score gt $(opt threat-score)")
    [[ ${#parts[@]} -eq 0 ]] && die "Provide --expression=<filter> or one of --countries, --ips, --asns, --paths, --path-prefixes, --hosts, --methods, --user-agents" "$EX_ARGS"
    expr="(${parts[0]})"
    for ((i = 1; i < ${#parts[@]}; i++)); do expr="${expr} and (${parts[$i]})"; done
  fi
  if [[ "$(optBool not)" == "true" ]]; then
    expr="not (${expr})"
  fi
  printf '%s' "$expr"
}

# firewallRule - Full custom rule JSON
firewallRule() {
  local action expression params='null' description
  action="$(opt action)"
  [[ -z "$action" ]] && die "Missing --action=block|challenge|js_challenge|managed_challenge|log|skip" "$EX_ARGS"
  expression="$(firewallExpression)" || exit $?
  description="$(opt description "Firewall ${action}: $(optFirst "$expression" countries ips asns paths hosts user-agents)")"
  if hasOpt action-parameters; then
    params="$(readFileOrValue "$(opt action-parameters)")"
  elif [[ "$action" == "skip" ]]; then
    params="$(jq -cn --argjson phases "$(toJsonArray "$(opt skip-phases)")" --argjson products "$(toJsonArray "$(opt skip-products)")" \
      '(if ($phases|length) > 0 then {phases:$phases} else {} end) + (if ($products|length) > 0 then {products:$products} else {} end) | if . == {} then {ruleset:"current"} else . end')"
  fi
  jq -cn --arg e "$expression" --arg a "$action" --argjson p "$params" --arg d "$description" --argjson en "$(optBool enabled true)" --argjson log "$(optBool log true)" \
    '{expression:$e, action:$a, description:$d, enabled:$en} + (if $p != null then {action_parameters:$p} else {} end) + (if $a == "skip" then {logging:{enabled:$log}} else {} end)'
}

cmd_firewall_list() { rulesetList "$FIREWALL_PHASE"; }
cmd_firewall_create() { local r; r="$(firewallRule)" || exit $?; rulesetCreate "$FIREWALL_PHASE" "$r"; }
cmd_firewall_upsert() { local r; r="$(firewallRule)" || exit $?; rulesetUpsert "$FIREWALL_PHASE" "$r"; }

cmd_firewall_update() {
  requireOpt id
  local patch expr
  patch="$(ruleFromOptions)"
  if { hasOpt countries || hasOpt ips || hasOpt asns || hasOpt paths || hasOpt hosts || hasOpt methods || hasOpt user-agents; } && ! hasOpt expression; then
    expr="$(firewallExpression)" || exit $?
    patch="$(jq -cn --argjson p "$patch" --arg e "$expr" '$p + {expression:$e}')"
  fi
  [[ "$patch" == "{}" ]] && die "Nothing to update" "$EX_ARGS"
  rulesetLoad "$FIREWALL_PHASE"
  rulesetPatch "$FIREWALL_PHASE" "$(opt id)" "$patch"
  emitResult "$(cfResult)" "$RULE_ONE"
}

cmd_firewall_delete() { rulesetDeleteCmd "$FIREWALL_PHASE" "$(opt expression)"; }
cmd_firewall_enable() { rulesetToggle "$FIREWALL_PHASE" true "$(opt expression)"; }
cmd_firewall_disable() { rulesetToggle "$FIREWALL_PHASE" false "$(opt expression)"; }

#####################################################################################################################VDM
######################################## Rate limiting

RATELIMIT_PHASE="http_ratelimit"

ratelimitRule() {
  requireOpt expression requests
  local action chars
  action="$(opt action block)"
  chars="$(toJsonArray "$(opt characteristics "ip.src,cf.colo.id")")"
  jq -cn --arg e "$(opt expression)" --arg a "$action" --argjson c "$chars" --argjson period "$(opt period 10)" --argjson req "$(opt requests)" --argjson timeout "$(opt timeout 10)" \
    --arg ce "$(opt counting-expression)" --arg d "$(opt description "Rate limit: $(opt expression)")" --argjson en "$(optBool enabled true)" \
    '{expression:$e, action:$a, description:$d, enabled:$en, ratelimit:({characteristics:$c, period:$period, requests_per_period:$req, mitigation_timeout:$timeout} + (if $ce != "" then {counting_expression:$ce} else {} end))}'
}

cmd_ratelimit_list() { rulesetList "$RATELIMIT_PHASE" '.[] | "\(.id)\tenabled=\(.enabled)\t\(.ratelimit.requests_per_period)req/\(.ratelimit.period)s timeout=\(.ratelimit.mitigation_timeout)\t\(.action)\t\(.expression)\t\(.description // "")"'; }
cmd_ratelimit_create() { local r; r="$(ratelimitRule)" || exit $?; rulesetCreate "$RATELIMIT_PHASE" "$r"; }
cmd_ratelimit_upsert() { local r; r="$(ratelimitRule)" || exit $?; rulesetUpsert "$RATELIMIT_PHASE" "$r"; }
cmd_ratelimit_delete() { rulesetDeleteCmd "$RATELIMIT_PHASE" "$(opt expression)"; }
cmd_ratelimit_enable() { rulesetToggle "$RATELIMIT_PHASE" true "$(opt expression)"; }
cmd_ratelimit_disable() { rulesetToggle "$RATELIMIT_PHASE" false "$(opt expression)"; }

#####################################################################################################################VDM
######################################## Transform rules

# transformPhase - Phase for --kind
transformPhase() {
  case "$(lower "$(opt kind url)")" in
    url|uri|rewrite|path) echo http_request_transform ;;
    request-header|request-headers|request) echo http_request_late_transform ;;
    response-header|response-headers|response) echo http_response_headers_transform ;;
    *) die "Invalid --kind (expected url, request-headers or response-headers)" "$EX_ARGS" ;;
  esac
}

# transformMode - "upsert" unless --create was given
transformMode() {
  if [[ "$(optBool create)" == "true" ]]; then echo create; else echo upsert; fi
}

cmd_transform_list() {
  if hasOpt kind; then
    local phase
    phase="$(transformPhase)" || exit $?
    rulesetList "$phase"
  else
    local all='[]' phase
    for phase in http_request_transform http_request_late_transform http_response_headers_transform; do
      rulesetLoad "$phase"
      all="$(jq -cn --argjson a "$all" --argjson b "$RS_RULES" --arg p "$phase" '$a + ($b | map(. + {phase:$p}))')"
    done
    emitResult "$all" '.[] | "\(.phase)\t\(.id)\tenabled=\(.enabled)\t\(.description // "-")\t\(.expression)"' "No transform rules."
  fi
}

cmd_transform_url() {
  requireOpt expression
  local uri='{}' rule
  if hasOpt path-expression; then
    uri="$(jq -cn --argjson u "$uri" --arg v "$(opt path-expression)" '$u + {path:{expression:$v}}')"
  elif hasOpt path; then
    uri="$(jq -cn --argjson u "$uri" --arg v "$(opt path)" '$u + {path:{value:$v}}')"
  fi
  if hasOpt query-expression; then
    uri="$(jq -cn --argjson u "$uri" --arg v "$(opt query-expression)" '$u + {query:{expression:$v}}')"
  elif hasOpt query; then
    uri="$(jq -cn --argjson u "$uri" --arg v "$(opt query)" '$u + {query:{value:$v}}')"
  fi
  [[ "$uri" == "{}" ]] && die "Provide --path=<value>, --path-expression=<expr>, --query=<value> or --query-expression=<expr>" "$EX_ARGS"
  rule="$(jq -cn --arg e "$(opt expression)" --argjson u "$uri" --arg d "$(opt description "URL rewrite: $(opt expression)")" --argjson en "$(optBool enabled true)" '{expression:$e, action:"rewrite", action_parameters:{uri:$u}, description:$d, enabled:$en}')"
  rulesetCreateOrUpsert "$(transformMode)" http_request_transform "$rule"
}

# transformHeadersRule - Header modification rule for a phase
transformHeadersRule() {
  local phase="$1" headers='{}' pair name value
  if hasOpt headers; then
    headers="$(readFileOrValue "$(opt headers)" | jq -c 'with_entries(.value |= (if type=="object" then . elif . == null then {operation:"remove"} else {operation:"set", value:(.|tostring)} end))')"
  fi
  if hasOpt set; then
    pair="$(opt set)"
    name="${pair%%=*}"
    value="${pair#*=}"
    headers="$(jq -cn --argjson h "$headers" --arg n "$name" --arg v "$value" '$h + {($n):{operation:"set", value:$v}}')"
  fi
  if hasOpt set-expression; then
    pair="$(opt set-expression)"
    name="${pair%%=*}"
    value="${pair#*=}"
    headers="$(jq -cn --argjson h "$headers" --arg n "$name" --arg v "$value" '$h + {($n):{operation:"set", expression:$v}}')"
  fi
  if hasOpt remove; then
    while IFS= read -r name; do
      headers="$(jq -cn --argjson h "$headers" --arg n "$name" '$h + {($n):{operation:"remove"}}')"
    done < <(listItems "$(opt remove)")
  fi
  [[ "$headers" == "{}" ]] && die "Provide --set=Name=Value, --set-expression=Name=<expr>, --headers=<json> or --remove=Name" "$EX_ARGS"
  jq -cn --arg e "$(opt expression)" --argjson h "$headers" --arg d "$(opt description "Header transform: $(opt expression)")" --argjson en "$(optBool enabled true)" '{expression:$e, action:"rewrite", action_parameters:{headers:$h}, description:$d, enabled:$en}'
}

cmd_transform_request_header() {
  requireOpt expression
  local rule
  rule="$(transformHeadersRule http_request_late_transform)" || exit $?
  rulesetCreateOrUpsert "$(transformMode)" http_request_late_transform "$rule"
}

cmd_transform_response_header() {
  requireOpt expression
  local rule
  rule="$(transformHeadersRule http_response_headers_transform)" || exit $?
  rulesetCreateOrUpsert "$(transformMode)" http_response_headers_transform "$rule"
}

cmd_transform_delete() {
  hasOpt kind || die "Missing --kind=url|request-headers|response-headers" "$EX_ARGS"
  local phase
  phase="$(transformPhase)" || exit $?
  rulesetDeleteCmd "$phase" "$(opt expression)"
}

#####################################################################################################################VDM
######################################## Cache rules

CACHE_RULE_PHASE="http_request_cache_settings"

# ttlParam - Build an edge/browser ttl object from a value (seconds, respect, bypass)
ttlParam() {
  local v="$1" kind="$2"
  case "$(lower "$v")" in
    respect|respect_origin|origin) echo '{"mode":"respect_origin"}' ;;
    bypass|bypass_by_default) echo '{"mode":"bypass_by_default"}' ;;
    *)
      [[ "$v" =~ ^[0-9]+$ ]] || die "Invalid --${kind}-ttl=${v} (expected seconds, respect or bypass)" "$EX_ARGS"
      jq -cn --argjson d "$v" '{mode:"override_origin", default:$d}'
      ;;
  esac
}

cacheRule() {
  requireOpt expression
  local params='{}' ttl
  hasOpt cache && params="$(jq -cn --argjson p "$params" --argjson v "$(optBool cache)" '$p + {cache:$v}')"
  if hasOpt edge-ttl; then
    ttl="$(ttlParam "$(opt edge-ttl)" edge)" || exit $?
    params="$(jq -cn --argjson p "$params" --argjson v "$ttl" '$p + {edge_ttl:$v}')"
  fi
  if hasOpt browser-ttl; then
    ttl="$(ttlParam "$(opt browser-ttl)" browser)" || exit $?
    params="$(jq -cn --argjson p "$params" --argjson v "$ttl" '$p + {browser_ttl:$v}')"
  fi
  [[ "$(optBool ignore-query-string)" == "true" ]] && params="$(jq -cn --argjson p "$params" '$p + {cache_key:{custom_key:{query_string:{exclude:{all:true}}}}}')"
  [[ "$(optBool serve-stale)" == "true" ]] && params="$(jq -cn --argjson p "$params" '$p + {serve_stale:{disable_stale_while_updating:false}}')"
  hasOpt action-parameters && params="$(jq -cn --argjson p "$params" --argjson v "$(readFileOrValue "$(opt action-parameters)")" '$p + $v')"
  [[ "$params" == "{}" ]] && params='{"cache":true}'
  jq -cn --arg e "$(opt expression)" --argjson p "$params" --arg d "$(opt description "Cache rule: $(opt expression)")" --argjson en "$(optBool enabled true)" '{expression:$e, action:"set_cache_settings", action_parameters:$p, description:$d, enabled:$en}'
}

cmd_cache_rule_list() { rulesetList "$CACHE_RULE_PHASE"; }
cmd_cache_rule_create() { local r; r="$(cacheRule)" || exit $?; rulesetCreate "$CACHE_RULE_PHASE" "$r"; }
cmd_cache_rule_upsert() { local r; r="$(cacheRule)" || exit $?; rulesetUpsert "$CACHE_RULE_PHASE" "$r"; }
cmd_cache_rule_delete() { rulesetDeleteCmd "$CACHE_RULE_PHASE" "$(opt expression)"; }

#####################################################################################################################VDM
######################################## Configuration rules

CONFIG_RULE_PHASE="http_config_settings"
CONFIG_RULE_KEYS="ssl security_level automatic_https_rewrites email_obfuscation hotlink_protection opportunistic_encryption rocket_loader mirage polish bic disable_apps disable_zaraz disable_rum server_side_excludes sxg fonts"

configRule() {
  requireOpt expression
  local params='{}' key flag
  hasOpt settings && params="$(readFileOrValue "$(opt settings)" | jq -c .)"
  for key in $CONFIG_RULE_KEYS; do
    flag="${key//_/-}"
    if hasOpt "$flag"; then
      case "$key" in
        ssl|security_level|polish) params="$(jq -cn --argjson p "$params" --arg v "$(opt "$flag")" "\$p + {${key}:\$v}")" ;;
        *) params="$(jq -cn --argjson p "$params" --argjson v "$(optBool "$flag")" "\$p + {${key}:\$v}")" ;;
      esac
    fi
  done
  [[ "$params" == "{}" ]] && die "Provide --settings=<json> or flags such as --ssl=strict, --security-level=high, --rocket-loader=false" "$EX_ARGS"
  jq -cn --arg e "$(opt expression)" --argjson p "$params" --arg d "$(opt description "Configuration rule: $(opt expression)")" --argjson en "$(optBool enabled true)" '{expression:$e, action:"set_config", action_parameters:$p, description:$d, enabled:$en}'
}

cmd_config_rule_list() { rulesetList "$CONFIG_RULE_PHASE"; }
cmd_config_rule_create() { local r; r="$(configRule)" || exit $?; rulesetCreate "$CONFIG_RULE_PHASE" "$r"; }
cmd_config_rule_upsert() { local r; r="$(configRule)" || exit $?; rulesetUpsert "$CONFIG_RULE_PHASE" "$r"; }
cmd_config_rule_delete() { rulesetDeleteCmd "$CONFIG_RULE_PHASE" "$(opt expression)"; }

#####################################################################################################################VDM
######################################## Origin rules

ORIGIN_RULE_PHASE="http_request_origin"

originRule() {
  requireOpt expression
  local params='{}' origin='{}'
  hasOpt host-header && params="$(jq -cn --argjson p "$params" --arg v "$(opt host-header)" '$p + {host_header:$v}')"
  hasOpt sni && params="$(jq -cn --argjson p "$params" --arg v "$(opt sni)" '$p + {sni:{value:$v}}')"
  hasOpt origin-host && origin="$(jq -cn --argjson o "$origin" --arg v "$(opt origin-host)" '$o + {host:$v}')"
  hasOpt origin-port && origin="$(jq -cn --argjson o "$origin" --argjson v "$(opt origin-port)" '$o + {port:$v}')"
  [[ "$origin" != "{}" ]] && params="$(jq -cn --argjson p "$params" --argjson o "$origin" '$p + {origin:$o}')"
  hasOpt action-parameters && params="$(jq -cn --argjson p "$params" --argjson v "$(readFileOrValue "$(opt action-parameters)")" '$p + $v')"
  [[ "$params" == "{}" ]] && die "Provide --host-header, --origin-host, --origin-port or --sni" "$EX_ARGS"
  jq -cn --arg e "$(opt expression)" --argjson p "$params" --arg d "$(opt description "Origin rule: $(opt expression)")" --argjson en "$(optBool enabled true)" '{expression:$e, action:"route", action_parameters:$p, description:$d, enabled:$en}'
}

cmd_origin_rule_list() { rulesetList "$ORIGIN_RULE_PHASE"; }
cmd_origin_rule_create() { local r; r="$(originRule)" || exit $?; rulesetCreate "$ORIGIN_RULE_PHASE" "$r"; }
cmd_origin_rule_upsert() { local r; r="$(originRule)" || exit $?; rulesetUpsert "$ORIGIN_RULE_PHASE" "$r"; }
cmd_origin_rule_delete() { rulesetDeleteCmd "$ORIGIN_RULE_PHASE" "$(opt expression)"; }
