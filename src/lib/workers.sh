#!/usr/bin/env bash
# Octoflare module: workers
#
# Workers scripts (upload, list, delete, secrets, cron triggers, workers.dev
# subdomain), zone Worker routes and Workers KV namespaces / keys.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand workers list "[--account-id=<id>]" "List Worker scripts"
registerCommand workers upload "--name=<script> --file=<worker.js> [--module=true|false] [--compatibility-date=<date>] [--compatibility-flags=a,b] [--kv=BINDING=<namespace-id>] [--vars=<json>] [--bindings=<json>]" "Upload (create or update) a Worker script"
registerCommand workers download "--name=<script> [--file=<path>]" "Download a Worker script"
registerCommand workers delete "--name=<script> [--force]" "Delete a Worker script"
registerCommand workers secret-list "--name=<script>" "List the secrets of a Worker"
registerCommand workers secret-set "--name=<script> --secret-name=<NAME> (--secret-value=<v> | --from-env=<VAR>)" "Set a secret on a Worker"
registerCommand workers secret-delete "--name=<script> --secret-name=<NAME>" "Delete a Worker secret"
registerCommand workers schedules "--name=<script> [--crons='*/5 * * * *,0 0 * * *']" "Get or set the cron triggers of a Worker"
registerCommand workers subdomain "--name=<script> [on|off]" "Get or toggle the workers.dev URL of a Worker"
registerCommand workers account-subdomain "[--subdomain=<name>]" "Get or set the account workers.dev subdomain"
registerCommand workers routes "--domain=<zone>" "List Worker routes of a zone"
registerCommand workers route-create "--domain=<zone> --pattern=<pattern> --script=<name>" "Create a Worker route"
registerCommand workers route-upsert "--domain=<zone> --pattern=<pattern> --script=<name>" "Create or update the route for a pattern"
registerCommand workers route-delete "--domain=<zone> (--id=<route-id> | --pattern=<pattern>)" "Delete a Worker route"
registerCommand kv list "" "List KV namespaces"
registerCommand kv create "--title=<name>" "Create a KV namespace"
registerCommand kv delete "--namespace=<id|title>" "Delete a KV namespace"
registerCommand kv keys "--namespace=<id|title> [--prefix=<p>]" "List the keys of a namespace"
registerCommand kv get "--namespace=<id|title> --key=<key>" "Read a value"
registerCommand kv put "--namespace=<id|title> --key=<key> (--value=<v> | --file=<path>) [--ttl=<seconds>] [--metadata=<json>]" "Write a value"
registerCommand kv delete-key "--namespace=<id|title> --key=<key>" "Delete a key"
registerCommand kv bulk-put "--namespace=<id|title> --file=<items.json>" "Write many key/value pairs ([{key,value,...}])"
registerCommand kv bulk-delete "--namespace=<id|title> --keys=<a,b> | --file=<keys.json>" "Delete many keys"

WORKER_TEMPLATE='.[] | "\(.id)\tmodified=\(.modified_on // "-")\tcompat=\(.compatibility_date // "-")"'
ROUTE_TEMPLATE='.[] | "\(.id)\t\(.pattern)\t-> \(.script // "(none)")"'
KV_TEMPLATE='.[] | "\(.id)\t\(.title)"'

#####################################################################################################################VDM
######################################## Worker scripts

# workerName - The script name from --name/--script
workerName() {
  local n
  n="$(optFirst "" name script worker)"
  [[ -z "$n" ]] && die "Missing --name=<script>" "$EX_ARGS"
  printf '%s' "$n"
}

cmd_workers_list() {
  resolveAccount
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/workers/scripts"
  emitResult "$(cfResult)" "$WORKER_TEMPLATE" "No Worker scripts."
}

cmd_workers_upload() {
  resolveAccount
  local name file module metadata bindings='[]' pair binding ns date
  name="$(workerName)" || exit $?
  file="$(optFirst "" file script-file)"
  [[ -z "$file" ]] && die "Missing --file=<worker.js>" "$EX_ARGS"
  [[ -f "$file" ]] || die "Worker file not found: ${file}" "$EX_ARGS"
  if hasOpt module; then
    module="$(optBool module)"
  elif grep -qE '^\s*export\s+default|^\s*export\s+\{' "$file"; then
    module=true
  else
    module=false
  fi
  hasOpt bindings && bindings="$(readFileOrValue "$(opt bindings)" | jq -c .)"
  if hasOpt kv; then
    for pair in $(opt kv | tr ',' ' '); do
      binding="${pair%%=*}"
      ns="${pair#*=}"
      bindings="$(jq -cn --argjson b "$bindings" --arg n "$binding" --arg id "$ns" '$b + [{type:"kv_namespace", name:$n, namespace_id:$id}]')"
    done
  fi
  if hasOpt vars; then
    bindings="$(jq -cn --argjson b "$bindings" --argjson v "$(readFileOrValue "$(opt vars)")" '$b + ($v | to_entries | map({type:"plain_text", name:.key, text:(.value|tostring)}))')"
  fi
  date="$(opt compatibility-date "$(date -u +%Y-%m-%d)")"
  metadata="$(jq -cn --arg d "$date" --argjson flags "$(toJsonArray "$(opt compatibility-flags)")" --argjson b "$bindings" --argjson m "$module" \
    '{compatibility_date:$d, compatibility_flags:$flags, bindings:$b} + (if $m then {main_module:"worker.js"} else {body_part:"script"} end)')"
  logInfo "Uploading Worker ${name} from ${file} ($( [[ "$module" == "true" ]] && echo "ES module" || echo "service worker" ))..."
  if [[ "$module" == "true" ]]; then
    cfApi PUT "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}" "" multipart -F "metadata=${metadata};type=application/json" -F "worker.js=@${file};type=application/javascript+module"
  else
    cfApi PUT "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}" "" multipart -F "metadata=${metadata};type=application/json" -F "script=@${file};type=application/javascript"
  fi
  emitResult "$(cfResult '.result // {} | {id:(.id // "'"$name"'"), etag, modified_on, compatibility_date, handlers}')" '"id=\(.id)\nmodified_on=\(.modified_on // "-")\ncompatibility_date=\(.compatibility_date // "-")"'
}

cmd_workers_download() {
  resolveAccount
  local name file
  name="$(workerName)" || exit $?
  file="$(opt file)"
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}" "" none
  if [[ -n "$file" ]]; then
    printf '%s\n' "$CF_RESPONSE" >"$file"
    emitMessage "Worker ${name} written to ${file}." "$(jq -cn --arg f "$file" '{file:$f}')"
  elif [[ "$OCTOFLARE_OUTPUT" == "json" || -n "$OCTOFLARE_FIELD" ]]; then
    emitResult "$(jq -cn --arg n "$name" --arg s "$CF_RESPONSE" '{name:$n, script:$s}')"
  else
    printf '%s\n' "$CF_RESPONSE"
  fi
}

cmd_workers_delete() {
  resolveAccount
  local name path
  name="$(workerName)" || exit $?
  confirm "Delete Worker ${name}?" || die "Cancelled." "$EX_OK"
  path="/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}"
  [[ "$(optBool force)" == "true" ]] && path="${path}?force=true"
  cfApi DELETE "$path"
  emitMessage "Worker ${name} deleted." "$(jq -cn --arg n "$name" '{name:$n}')"
}

cmd_workers_secret_list() {
  resolveAccount
  workerName >/dev/null || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/workers/scripts/$(workerName)/secrets"
  emitResult "$(cfResult)" '.[] | "\(.name)\t\(.type)"' "No secrets."
}

cmd_workers_secret_set() {
  resolveAccount
  local name sname value
  name="$(workerName)" || exit $?
  sname="$(optFirst "" secret-name secret key)"
  [[ -z "$sname" ]] && die "Missing --secret-name=<NAME>" "$EX_ARGS"
  if hasOpt from-env; then
    value="${!OPT_from_env:-}"
    [[ -z "$value" ]] && die "Environment variable $(opt from-env) is empty" "$EX_ARGS"
  else
    value="$(readFileOrValue "$(optFirst "" secret-value value)")"
    [[ -z "$value" ]] && die "Missing --secret-value=<value> (or --from-env=<VAR>)" "$EX_ARGS"
  fi
  ghMask "$value"
  cfApi PUT "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}/secrets" "$(jq -cn --arg n "$sname" --arg v "$value" '{name:$n, text:$v, type:"secret_text"}')"
  emitResult "$(cfResult '.result | {name, type}')" '"secret=\(.name) type=\(.type)"'
}

cmd_workers_secret_delete() {
  resolveAccount
  workerName >/dev/null || exit $?
  local sname
  sname="$(optFirst "" secret-name secret key)"
  [[ -z "$sname" ]] && die "Missing --secret-name=<NAME>" "$EX_ARGS"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/workers/scripts/$(workerName)/secrets/${sname}"
  emitMessage "Secret ${sname} deleted." "$(jq -cn --arg n "$sname" '{name:$n}')"
}

cmd_workers_schedules() {
  resolveAccount
  local name crons body
  name="$(workerName)" || exit $?
  crons="$(optFirst "" crons cron)"
  if [[ -n "$crons" ]]; then
    body="$(toJsonArray "$crons" | jq -c 'map({cron:.})')"
    cfApi PUT "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}/schedules" "$body"
  else
    cfApi GET "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}/schedules"
  fi
  emitResult "$(cfResult '.result | if type=="object" then (.schedules // []) else (. // []) end')" '.[] | .cron' "No cron triggers."
}

cmd_workers_subdomain() {
  resolveAccount
  local name value
  name="$(workerName)" || exit $?
  value="$(opt value)"
  [[ -z "$value" && -n "${ARGS[2]:-}" ]] && value="${ARGS[2]}"
  if [[ -n "$value" ]]; then
    cfApi POST "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}/subdomain" "$(jq -cn --argjson e "$(normalizeBool "$value")" '{enabled:$e, previews_enabled:$e}')"
  else
    cfApi GET "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}/subdomain"
  fi
  emitResult "$(cfResult)" '"enabled=\(.enabled)\npreviews_enabled=\(.previews_enabled // false)"'
}

cmd_workers_account_subdomain() {
  resolveAccount
  if hasOpt subdomain; then
    cfApi PUT "/accounts/${CF_ACCOUNT_ID}/workers/subdomain" "$(jq -cn --arg s "$(opt subdomain)" '{subdomain:$s}')"
  else
    cfApi GET "/accounts/${CF_ACCOUNT_ID}/workers/subdomain"
  fi
  emitResult "$(cfResult)" '"subdomain=\(.subdomain).workers.dev"'
}

#####################################################################################################################VDM
######################################## Worker routes

cmd_workers_routes() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/workers/routes"
  emitResult "$(cfResult)" "$ROUTE_TEMPLATE" "No Worker routes."
}

# routeBody - {pattern, script}
routeBody() {
  requireOpt pattern script
  jq -cn --arg p "$(opt pattern)" --arg s "$(opt script)" '{pattern:$p, script:$s}'
}

cmd_workers_route_create() {
  resolveZone
  local body
  body="$(routeBody)" || exit $?
  cfApi POST "/zones/${CF_ZONE_ID}/workers/routes" "$body"
  emitResult "$(cfResult)" '"id=\(.id)\npattern=\(.pattern // "-")\nscript=\(.script // "-")"'
}

cmd_workers_route_upsert() {
  resolveZone
  local body existing id
  body="$(routeBody)" || exit $?
  cfApi GET "/zones/${CF_ZONE_ID}/workers/routes"
  existing="$(printf '%s' "$CF_RESPONSE" | jq -c --arg p "$(opt pattern)" '[.result[]? | select(.pattern == $p)][0] // empty')"
  if [[ -z "$existing" ]]; then
    cfApi POST "/zones/${CF_ZONE_ID}/workers/routes" "$body"
    emitResult "$(cfResult '.result + {action_result:"created"}')" '"id=\(.id)\naction=\(.action_result)"'
    return 0
  fi
  id="$(printf '%s' "$existing" | jq -r '.id')"
  if [[ "$(printf '%s' "$existing" | jq -r '.script // ""')" == "$(opt script)" ]]; then
    emitResult "$(printf '%s' "$existing" | jq -c '. + {action_result:"unchanged"}')" '"id=\(.id)\npattern=\(.pattern)\nscript=\(.script)\naction=\(.action_result)"'
    return 0
  fi
  cfApi PUT "/zones/${CF_ZONE_ID}/workers/routes/${id}" "$body"
  emitResult "$(cfResult '.result + {action_result:"updated"}')" '"id=\(.id)\npattern=\(.pattern // "-")\nscript=\(.script // "-")\naction=\(.action_result)"'
}

cmd_workers_route_delete() {
  resolveZone
  local id
  id="$(opt id)"
  if [[ -z "$id" ]]; then
    requireOpt pattern
    cfApi GET "/zones/${CF_ZONE_ID}/workers/routes"
    id="$(printf '%s' "$CF_RESPONSE" | jq -r --arg p "$(opt pattern)" '[.result[]? | select(.pattern == $p)][0].id // empty')"
    [[ -z "$id" && "$OCTOFLARE_DRY_RUN" == "true" ]] && id="dry-run-route-id"
    [[ -z "$id" ]] && die "No Worker route found for pattern $(opt pattern)" "$EX_NOTFOUND"
  fi
  confirm "Delete Worker route ${id}?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/zones/${CF_ZONE_ID}/workers/routes/${id}"
  emitMessage "Worker route ${id} deleted." "$(jq -cn --arg id "$id" '{id:$id}')"
}

#####################################################################################################################VDM
######################################## KV

# kvNamespaceId - Resolve --namespace (id or title) to a namespace id
kvNamespaceId() {
  local ns id
  ns="$(optFirst "" namespace namespace-id title)"
  [[ -z "$ns" ]] && die "Missing --namespace=<id|title>" "$EX_ARGS"
  if [[ "$ns" =~ ^[0-9a-f]{32}$ ]]; then
    printf '%s' "$ns"
    return 0
  fi
  cfApiList "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces"
  id="$(printf '%s' "$CF_RESPONSE" | jq -r --arg t "$ns" '[.result[] | select(.title == $t)][0].id // empty')"
  if [[ -z "$id" ]]; then
    [[ "$OCTOFLARE_DRY_RUN" == "true" ]] && { printf 'dry-run-namespace-id'; return 0; }
    die "KV namespace not found: ${ns}" "$EX_NOTFOUND"
  fi
  printf '%s' "$id"
}

cmd_kv_list() {
  resolveAccount
  cfApiList "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces"
  emitResult "$(cfResult)" "$KV_TEMPLATE" "No KV namespaces."
}

cmd_kv_create() {
  resolveAccount
  local title
  title="$(optFirst "" title name namespace)"
  [[ -z "$title" ]] && die "Missing --title=<name>" "$EX_ARGS"
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" "$(jq -cn --arg t "$title" '{title:$t}')"
  emitResult "$(cfResult)" '"id=\(.id)\ntitle=\(.title)"'
}

cmd_kv_delete() {
  resolveAccount
  local id
  id="$(kvNamespaceId)" || exit $?
  confirm "Delete KV namespace ${id} and all its keys?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${id}"
  emitMessage "KV namespace ${id} deleted." "$(jq -cn --arg id "$id" '{id:$id}')"
}

cmd_kv_keys() {
  resolveAccount
  local id
  id="$(kvNamespaceId)" || exit $?
  cfApiCursor "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${id}/keys" "$(cfQuery "prefix=$(opt prefix)" "limit=$(opt limit)")"
  emitResult "$(cfResult)" '.[] | .name' "No keys."
}

cmd_kv_get() {
  resolveAccount
  requireOpt key
  local id
  id="$(kvNamespaceId)" || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${id}/values/$(urlEncode "$(opt key)")" "" none
  if [[ "$OCTOFLARE_OUTPUT" == "json" || -n "$OCTOFLARE_FIELD" ]]; then
    emitResult "$(jq -cn --arg k "$(opt key)" --arg v "$CF_RESPONSE" '{key:$k, value:$v}')"
  else
    printf '%s\n' "$CF_RESPONSE"
  fi
}

cmd_kv_put() {
  resolveAccount
  requireOpt key
  local id value path query
  id="$(kvNamespaceId)" || exit $?
  if hasOpt file; then
    value="$(cat "$(opt file)")"
  else
    value="$(readFileOrValue "$(opt value)")"
  fi
  query="$(cfQuery "expiration_ttl=$(opt ttl)" "expiration=$(opt expiration)")"
  path="$(cfPath "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${id}/values/$(urlEncode "$(opt key)")" "$query")"
  if hasOpt metadata; then
    cfApi PUT "$path" "" multipart -F "value=${value}" -F "metadata=$(readFileOrValue "$(opt metadata)")"
  else
    cfApi PUT "$path" "$value" "text/plain"
  fi
  emitMessage "Key $(opt key) written." "$(jq -cn --arg k "$(opt key)" '{key:$k}')"
}

cmd_kv_delete_key() {
  resolveAccount
  requireOpt key
  local id
  id="$(kvNamespaceId)" || exit $?
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${id}/values/$(urlEncode "$(opt key)")"
  emitMessage "Key $(opt key) deleted." "$(jq -cn --arg k "$(opt key)" '{key:$k}')"
}

cmd_kv_bulk_put() {
  resolveAccount
  local id body
  id="$(kvNamespaceId)" || exit $?
  body="$(inputFromOpts items)" || exit $?
  [[ -z "$body" ]] && die "Provide --file=<items.json> ([{\"key\":..,\"value\":..}])" "$EX_ARGS"
  cfApi PUT "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${id}/bulk" "$(printf '%s' "$body" | jq -c .)"
  emitResult "$(cfResult)" '"successful_key_count=\(.successful_key_count // "-")\nunsuccessful_keys=\((.unsuccessful_keys // []) | join(","))"'
}

cmd_kv_bulk_delete() {
  resolveAccount
  local id body
  id="$(kvNamespaceId)" || exit $?
  if hasOpt file; then
    body="$(inputFromOpts | jq -c .)" || exit $?
  else
    body="$(toJsonArray "$(opt keys)")"
  fi
  [[ "$body" == "[]" ]] && die "Provide --keys=<a,b> or --file=<keys.json>" "$EX_ARGS"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${id}/bulk" "$body"
  emitResult "$(cfResult)" '"successful_key_count=\(.successful_key_count // "-")"'
}
