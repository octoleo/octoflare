#!/usr/bin/env bash
# Octoflare module: account
#
# Accounts, user, API token verification, Cloudflare IP ranges, account
# lists (IP / ASN / hostname / redirect), Bulk Redirects and Web Analytics.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand account list "" "List accounts visible to the token"
registerCommand account get "[--account-id=<id>]" "Show account details"
registerCommand account id "[--domain=<zone>]" "Print the resolved account ID"
registerCommand user get "" "Show the user of the token (global API key auth only)"
registerCommand token verify "" "Verify the API token and show its status"
registerCommand ip list "[--ipv4] [--ipv6]" "List Cloudflare's IP ranges (for origin firewalls)"
registerCommand list list "" "List account lists"
registerCommand list get "(--name=<list> | --id=<list-id>)" "Show a list"
registerCommand list create "--name=<list> --kind=ip|asn|hostname|redirect [--description=<text>]" "Create a list"
registerCommand list delete "(--name=<list> | --id=<list-id>)" "Delete a list"
registerCommand list items "(--name=<list> | --id=<list-id>)" "Show the items of a list"
registerCommand list add "(--name=<list> | --id=<list-id>) (--items=<a,b> | --file=<items.json>)" "Add items (IPs, ASNs, hostnames or redirect objects)"
registerCommand list remove "(--name=<list> | --id=<list-id>) --items=<a,b>" "Remove items by value"
registerCommand list replace "(--name=<list> | --id=<list-id>) --file=<items.json>" "Replace all items"
registerCommand bulk-redirect list "--list=<name>" "Show the redirects in a redirect list"
registerCommand bulk-redirect add "--list=<name> --from=<url> --to=<url> [--status=301] [--include-subdomains] [--subpath-matching] [--preserve-query] [--preserve-path-suffix]" "Add a redirect to a list (creates the list when missing)"
registerCommand bulk-redirect remove "--list=<name> --from=<url>" "Remove a redirect from a list"
registerCommand bulk-redirect enable "--list=<name>" "Create/enable the account Bulk Redirect rule for a list"
registerCommand bulk-redirect disable "--list=<name>" "Disable the Bulk Redirect rule for a list"
registerCommand web-analytics list "" "List Web Analytics sites"
registerCommand web-analytics create "--host=<hostname> [--domain=<zone>] [--auto-install]" "Create a Web Analytics site (returns the JS snippet token)"
registerCommand web-analytics delete "--site=<site-tag>" "Delete a Web Analytics site"

#####################################################################################################################VDM
######################################## Accounts, user, token, IPs

cmd_account_list() {
  cfApiList "/accounts"
  emitResult "$(cfResult)" '.[] | "\(.id)\t\(.name)\t\(.type // "-")"' "No accounts visible."
}

cmd_account_get() {
  resolveAccount
  cfApi GET "/accounts/${CF_ACCOUNT_ID}"
  emitResult "$(cfResult)" '"id=\(.id)\nname=\(.name)\ntype=\(.type // "-")\ncreated_on=\(.created_on // "-")\nenforce_twofactor=\(.settings.enforce_twofactor // false)"'
}

cmd_account_id() {
  resolveAccount
  emitResult "$(jq -cn --arg id "$CF_ACCOUNT_ID" '{id:$id}')" '.id'
}

cmd_user_get() {
  cfApi GET "/user"
  emitResult "$(cfResult)" '"id=\(.id)\nemail=\(.email // "-")\nusername=\(.username // "-")\ntwo_factor=\(.two_factor_authentication_enabled // false)"'
}

cmd_token_verify() {
  requireAuth
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    die "token verify needs an API token (CLOUDFLARE_API_TOKEN); global API keys cannot be verified this way." "$EX_CONFIG"
  fi
  cfApi GET "/user/tokens/verify"
  emitResult "$(cfResult)" '"status=\(.status)\nid=\(.id)\nexpires_on=\(.expires_on // "never")\nnot_before=\(.not_before // "-")"'
}

cmd_ip_list() {
  local v4 v6 result
  CF_NO_AUTH=true cfApi GET "/ips"
  v4="$(cfResult '.result.ipv4_cidrs // []')"
  v6="$(cfResult '.result.ipv6_cidrs // []')"
  if [[ "$(optBool ipv4)" == "true" && "$(optBool ipv6)" != "true" ]]; then
    result="$(jq -cn --argjson a "$v4" '{ipv4_cidrs:$a}')"
  elif [[ "$(optBool ipv6)" == "true" && "$(optBool ipv4)" != "true" ]]; then
    result="$(jq -cn --argjson a "$v6" '{ipv6_cidrs:$a}')"
  else
    result="$(jq -cn --argjson a "$v4" --argjson b "$v6" --arg e "$(cfResultRaw '.result.etag // ""')" '{ipv4_cidrs:$a, ipv6_cidrs:$b, etag:$e}')"
  fi
  emitResult "$result" '(.ipv4_cidrs // [])[], (.ipv6_cidrs // [])[]'
}

#####################################################################################################################VDM
######################################## Account lists

LIST_TEMPLATE='.[] | "\(.id)\t\(.name)\tkind=\(.kind)\titems=\(.num_items // 0)\t\(.description // "")"'
LIST_ITEM_TEMPLATE='.[] | "\(.id)\t\(.ip // .asn // .hostname.url_hostname // (.redirect | "\(.source_url) -> \(.target_url) (\(.status_code // 301))") // (.|tostring))\t\(.comment // "")"'

CF_LIST_ID=""
CF_LIST_KIND=""

# resolveList - Resolve --name/--list/--id to CF_LIST_ID (and CF_LIST_KIND)
#
# Arguments:
#   $1: "optional" to return silently when the list does not exist
resolveList() {
  resolveAccount
  local id name
  id="$(optFirst "" id list-id)"
  name="$(optFirst "" name list)"
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/rules/lists"
  if [[ -n "$id" ]]; then
    CF_LIST_ID="$id"
    CF_LIST_KIND="$(printf '%s' "$CF_RESPONSE" | jq -r --arg id "$id" '[.result[]? | select(.id == $id)][0].kind // empty')"
    return 0
  fi
  [[ -z "$name" ]] && die "Specify the list with --name=<list> or --id=<list-id>" "$EX_ARGS"
  CF_LIST_ID="$(printf '%s' "$CF_RESPONSE" | jq -r --arg n "$name" '[.result[]? | select(.name == $n)][0].id // empty')"
  CF_LIST_KIND="$(printf '%s' "$CF_RESPONSE" | jq -r --arg n "$name" '[.result[]? | select(.name == $n)][0].kind // empty')"
  if [[ -z "$CF_LIST_ID" ]]; then
    [[ "${1:-}" == "optional" ]] && return 1
    [[ "$OCTOFLARE_DRY_RUN" == "true" ]] && { CF_LIST_ID="dry-run-list-id"; return 0; }
    die "List not found: ${name}" "$EX_NOTFOUND"
  fi
}

# listItemsFromValues - Convert comma separated values into list items for the list kind
listItemsFromValues() {
  local kind="$1" values="$2"
  case "$kind" in
    ip) toJsonArray "$values" | jq -c 'map({ip:.})' ;;
    asn) toJsonArray "$values" | jq -c 'map({asn:(ltrimstr("AS")|ltrimstr("as")|tonumber)})' ;;
    hostname) toJsonArray "$values" | jq -c 'map({hostname:{url_hostname:.}})' ;;
    *) die "Provide --file=<items.json> for lists of kind ${kind}" "$EX_ARGS" ;;
  esac
}

cmd_list_list() {
  resolveAccount
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/rules/lists"
  emitResult "$(cfResult)" "$LIST_TEMPLATE" "No lists."
}

cmd_list_get() {
  resolveList
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}"
  emitResult "$(cfResult)" '"id=\(.id)\nname=\(.name)\nkind=\(.kind)\nitems=\(.num_items // 0)\ndescription=\(.description // "-")"'
}

cmd_list_create() {
  resolveAccount
  requireOpt kind
  local name
  name="$(optFirst "" name list)"
  [[ -z "$name" ]] && die "Missing --name=<list> (letters, numbers and underscores)" "$EX_ARGS"
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/rules/lists" "$(jq -cn --arg n "$name" --arg k "$(opt kind)" --arg d "$(opt description "Created by ${PROGRAM_NAME}")" '{name:$n, kind:$k, description:$d}')"
  emitResult "$(cfResult)" '"id=\(.id)\nname=\(.name)\nkind=\(.kind)"'
}

cmd_list_delete() {
  resolveList
  confirm "Delete list ${CF_LIST_ID}?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}"
  emitMessage "List ${CF_LIST_ID} deleted." "$(jq -cn --arg id "$CF_LIST_ID" '{id:$id}')"
}

cmd_list_items() {
  resolveList
  cfApiCursor "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items"
  emitResult "$(cfResult)" "$LIST_ITEM_TEMPLATE" "List is empty."
}

cmd_list_add() {
  resolveList
  local items
  local kind
  kind="$(opt kind "${CF_LIST_KIND:-ip}")"
  if hasOpt file; then
    items="$(inputFromOpts | jq -c .)" || exit $?
  else
    requireOpt items
    items="$(listItemsFromValues "$kind" "$(opt items)")" || exit $?
  fi
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items" "$items"
  emitResult "$(cfResult)" '"operation_id=\(.operation_id // "-")"'
}

cmd_list_remove() {
  resolveList
  requireOpt items
  local ids
  cfApiCursor "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items"
  # match on the value that the list kind stores (ip, asn number, hostname or redirect source)
  local wanted
  wanted="$(toJsonArray "$(opt items)" | jq -c 'map(ltrimstr("AS") | ltrimstr("as"))')"
  ids="$(printf '%s' "$CF_RESPONSE" | jq -c --argjson v "$wanted" '[.result[]? |
      ((.ip // .hostname.url_hostname // .redirect.source_url // (if .asn != null then (.asn|tostring) else null end)) as $x |
       select($x != null and ($v | index($x) != null))) | {id}]')"
  [[ "$(printf '%s' "$ids" | jq 'length')" == "0" && "$OCTOFLARE_DRY_RUN" != "true" ]] && die "None of the items were found in the list" "$EX_NOTFOUND"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items" "$(jq -cn --argjson i "$ids" '{items:$i}')"
  emitResult "$(cfResult)" '"operation_id=\(.operation_id // "-")"'
}

cmd_list_replace() {
  resolveList
  requireOpt file
  local items
  items="$(inputFromOpts | jq -c .)" || exit $?
  cfApi PUT "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items" "$items"
  emitResult "$(cfResult)" '"operation_id=\(.operation_id // "-")"'
}

#####################################################################################################################VDM
######################################## Bulk redirects

# bulkRedirectList - Resolve --list to CF_LIST_ID, creating the redirect list when missing
bulkRedirectList() {
  local name
  name="$(optFirst "" list name)"
  [[ -z "$name" ]] && die "Missing --list=<name>" "$EX_ARGS"
  setOpt name "$name"
  if ! resolveList optional; then
    logInfo "Creating redirect list ${name}..."
    cfApi POST "/accounts/${CF_ACCOUNT_ID}/rules/lists" "$(jq -cn --arg n "$name" '{name:$n, kind:"redirect", description:"Bulk redirects managed by Octoflare"}')"
    CF_LIST_ID="$(cfResultRaw '.result.id // "dry-run-list-id"')"
    CF_LIST_KIND="redirect"
  fi
  [[ -n "$CF_LIST_KIND" && "$CF_LIST_KIND" != "redirect" ]] && die "List ${name} is of kind ${CF_LIST_KIND}, not redirect" "$EX_ARGS"
  return 0
}

cmd_bulk_redirect_list() {
  bulkRedirectList
  cfApiCursor "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items"
  emitResult "$(cfResult '[.result[] | .redirect + {id}]')" '.[] | "\(.source_url)\t-> \(.target_url)\t\(.status_code // 301)\tid=\(.id)"' "No redirects in the list."
}

cmd_bulk_redirect_add() {
  bulkRedirectList
  requireOpt from to
  local item existing
  item="$(jq -cn --arg s "$(opt from)" --arg t "$(opt to)" --argjson code "$(optFirst 301 status status-code)" --argjson sub "$(optBool include-subdomains false)" --argjson path "$(optBool subpath-matching false)" --argjson q "$(optBool preserve-query false)" --argjson suffix "$(optBool preserve-path-suffix false)" \
    '[{redirect:{source_url:$s, target_url:$t, status_code:$code, include_subdomains:$sub, subpath_matching:$path, preserve_query_string:$q, preserve_path_suffix:$suffix}}]')"
  cfApiCursor "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items"
  existing="$(printf '%s' "$CF_RESPONSE" | jq -c --arg s "$(opt from)" '[.result[] | select(.redirect.source_url == $s) | {id}]')"
  if [[ "$(printf '%s' "$existing" | jq 'length')" != "0" ]]; then
    logInfo "Replacing existing redirect for $(opt from)..."
    cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items" "$(jq -cn --argjson i "$existing" '{items:$i}')"
  fi
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items" "$item"
  emitResult "$(jq -cn --argjson r "$(cfResult)" --argjson i "$item" '{operation_id:(if ($r|type) == "object" then ($r.operation_id // null) else null end), redirect:$i[0].redirect}')" '"\(.redirect.source_url) -> \(.redirect.target_url) (\(.redirect.status_code))\noperation_id=\(.operation_id // "-")"'
}

cmd_bulk_redirect_remove() {
  bulkRedirectList
  requireOpt from
  local ids
  cfApiCursor "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items"
  ids="$(printf '%s' "$CF_RESPONSE" | jq -c --arg s "$(opt from)" '[.result[] | select(.redirect.source_url == $s) | {id}]')"
  [[ "$(printf '%s' "$ids" | jq 'length')" == "0" && "$OCTOFLARE_DRY_RUN" != "true" ]] && die "No redirect found for $(opt from)" "$EX_NOTFOUND"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items" "$(jq -cn --argjson i "$ids" '{items:$i}')"
  emitMessage "Redirect for $(opt from) removed." "$(cfResult)"
}

# bulkRedirectRule - Create or toggle the account-level rule for the list
bulkRedirectRule() {
  local enabled="$1" name rule
  bulkRedirectList
  name="$(optFirst "" list name)"
  setOpt scope account
  rule="$(jq -cn --arg n "$name" --argjson en "$enabled" '{expression:("http.request.full_uri in $" + $n), action:"redirect", action_parameters:{from_list:{name:$n, key:"http.request.full_uri"}}, description:("Bulk redirects: " + $n), enabled:$en}')"
  setOpt description "Bulk redirects: ${name}"
  rulesetUpsert http_request_redirect "$rule"
}

cmd_bulk_redirect_enable() { bulkRedirectRule true; }
cmd_bulk_redirect_disable() { bulkRedirectRule false; }

#####################################################################################################################VDM
######################################## Web Analytics (RUM)

cmd_web_analytics_list() {
  resolveAccount
  cfApiList "/accounts/${CF_ACCOUNT_ID}/rum/site_info/list"
  emitResult "$(cfResult)" '.[] | "\(.site_tag)\t\(.ruleset.zone_name // .host // "-")\ttoken=\(.site_token)\tauto_install=\(.auto_install // false)"' "No Web Analytics sites."
}

cmd_web_analytics_create() {
  resolveAccount
  local body host zone_tag=""
  host="$(optFirst "" host hostname)"
  if [[ -n "$(zoneOption)" || -n "$(optFirst "${CLOUDFLARE_ZONE_ID:-}" zone-id)" ]]; then
    resolveZone
    zone_tag="$CF_ZONE_ID"
  fi
  [[ -z "$host" && -z "$zone_tag" ]] && die "Provide --host=<hostname> (external site) or --domain=<zone> (Cloudflare zone)" "$EX_ARGS"
  body="$(jq -cn --arg h "$host" --arg z "$zone_tag" --argjson a "$(optBool auto-install false)" '(if $z != "" then {zone_tag:$z} else {host:$h} end) + {auto_install:$a}')"
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/rum/site_info" "$body"
  emitResult "$(cfResult)" '"site_tag=\(.site_tag)\nsite_token=\(.site_token)\nsnippet=\(.snippet // "-")"'
}

cmd_web_analytics_delete() {
  resolveAccount
  local site
  site="$(optFirst "" site site-tag id)"
  [[ -z "$site" ]] && die "Missing --site=<site-tag>" "$EX_ARGS"
  confirm "Delete Web Analytics site ${site}?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/rum/site_info/${site}"
  emitMessage "Web Analytics site ${site} deleted." "$(jq -cn --arg s "$site" '{site_tag:$s}')"
}
