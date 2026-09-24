#!/usr/bin/env bash
# Octoflare module: tunnel
#
# Cloudflare Tunnel (cloudflared) management: create/delete tunnels, fetch the
# connector token, manage the remote ingress configuration and publish
# hostnames through DNS.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand tunnel list "[--name=<filter>] [--include-deleted]" "List tunnels"
registerCommand tunnel get "(--name=<tunnel> | --id=<tunnel-id>)" "Show a tunnel"
registerCommand tunnel create "--name=<tunnel> [--secret=<base64>]" "Create a remotely-managed tunnel (prints the connector token)"
registerCommand tunnel delete "(--name=<tunnel> | --id=<tunnel-id>) [--force]" "Delete a tunnel (--force cleans up active connections first)"
registerCommand tunnel token "(--name=<tunnel> | --id=<tunnel-id>)" "Print the connector token (cloudflared tunnel run --token ...)"
registerCommand tunnel config "(--name=<tunnel> | --id=<tunnel-id>)" "Show the remote ingress configuration"
registerCommand tunnel config-set "(--name=<tunnel> | --id=<tunnel-id>) (--ingress=host=service,... | --file=<config.json>)" "Replace the remote ingress configuration"
registerCommand tunnel route "(--name=<tunnel> | --id=<tunnel-id>) --hostname=<host> [--service=<url>]" "Publish a hostname: DNS CNAME to the tunnel (+ ingress entry when --service is given)"
registerCommand tunnel connections "(--name=<tunnel> | --id=<tunnel-id>)" "List active connections"
registerCommand tunnel cleanup "(--name=<tunnel> | --id=<tunnel-id>)" "Clean up stale connections"

TUNNEL_TEMPLATE='.[] | "\(.id)\t\(.name)\tstatus=\(.status // "-")\tconnections=\((.connections // []) | length)\tcreated=\(.created_at)"'
TUNNEL_ONE='"id=\(.id)\nname=\(.name)\nstatus=\(.status // "-")\nconfig_src=\(.config_src // "-")\nconnections=\((.connections // []) | length)\ncreated_at=\(.created_at)"'

CF_TUNNEL_ID=""

# resolveTunnel - Resolve --id or --name to CF_TUNNEL_ID
resolveTunnel() {
  [[ -n "$CF_TUNNEL_ID" ]] && return 0
  resolveAccount
  local id name
  id="$(optFirst "" id tunnel-id)"
  if [[ -n "$id" ]]; then
    CF_TUNNEL_ID="$id"
    return 0
  fi
  name="$(optFirst "" name tunnel)"
  [[ -z "$name" ]] && die "Specify the tunnel with --name=<tunnel> or --id=<tunnel-id>" "$EX_ARGS"
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=$(urlEncode "$name")&is_deleted=false"
  CF_TUNNEL_ID="$(cfResultRaw '.result[0].id // empty')"
  if [[ -z "$CF_TUNNEL_ID" ]]; then
    [[ "$OCTOFLARE_DRY_RUN" == "true" ]] && { CF_TUNNEL_ID="dry-run-tunnel-id"; return 0; }
    die "Tunnel not found: ${name}" "$EX_NOTFOUND"
  fi
}

cmd_tunnel_list() {
  resolveAccount
  local query
  query="$(cfQuery "name=$(opt name)")"
  [[ "$(optBool include-deleted)" != "true" ]] && query="${query:+${query}&}is_deleted=false"
  cfApiList "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" "$query"
  emitResult "$(cfResult)" "$TUNNEL_TEMPLATE" "No tunnels."
}

cmd_tunnel_get() {
  resolveTunnel
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}"
  emitResult "$(cfResult)" "$TUNNEL_ONE"
}

cmd_tunnel_create() {
  resolveAccount
  local name body secret
  name="$(optFirst "" name tunnel)"
  [[ -z "$name" ]] && die "Missing --name=<tunnel>" "$EX_ARGS"
  secret="$(opt secret)"
  body="$(jq -cn --arg n "$name" --arg s "$secret" '{name:$n, config_src:"cloudflare"} + (if $s != "" then {tunnel_secret:$s} else {} end)')"
  logInfo "Creating tunnel ${name}..."
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" "$body"
  CF_TUNNEL_ID="$(cfResultRaw '.result.id // empty')"
  local tunnel token=""
  tunnel="$(cfResult)"
  if [[ -n "$CF_TUNNEL_ID" && "$OCTOFLARE_DRY_RUN" != "true" ]]; then
    cfApi GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/token"
    token="$(cfResultRaw '.result // empty')"
    ghMask "$token"
  fi
  emitResult "$(jq -cn --argjson t "$tunnel" --arg tok "$token" '$t + {token:$tok}')" '"id=\(.id)\nname=\(.name)\ntoken=\(.token)\nrun: cloudflared tunnel run --token \(.token)"'
}

cmd_tunnel_delete() {
  resolveTunnel
  confirm "Delete tunnel ${CF_TUNNEL_ID}?" || die "Cancelled." "$EX_OK"
  if [[ "$(optBool force)" == "true" ]]; then
    cfApiTry DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/connections" || true
  fi
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}"
  emitMessage "Tunnel ${CF_TUNNEL_ID} deleted." "$(jq -cn --arg id "$CF_TUNNEL_ID" '{id:$id}')"
}

cmd_tunnel_token() {
  resolveTunnel
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/token"
  ghMask "$(cfResultRaw '.result // ""')"
  emitResult "$(cfResult '{id:"'"$CF_TUNNEL_ID"'", token:.result}')" '.token'
}

cmd_tunnel_config() {
  resolveTunnel
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations"
  emitResult "$(cfResult '.result.config // {}')" '.ingress[]? | "\(.hostname // "*")\t-> \(.service)"'
}

# ingressFromOption - Build an ingress array from host=service pairs (adds the catch-all)
ingressFromOption() {
  local pairs="$1" pair host service ingress='[]'
  for pair in $(printf '%s' "$pairs" | tr ',' ' '); do
    host="${pair%%=*}"
    service="${pair#*=}"
    [[ "$host" == "$service" ]] && die "Invalid --ingress entry '${pair}' (expected hostname=service)" "$EX_ARGS"
    ingress="$(jq -cn --argjson i "$ingress" --arg h "$host" --arg s "$service" '$i + [{hostname:$h, service:$s}]')"
  done
  jq -cn --argjson i "$ingress" '$i + [{service:"http_status:404"}]'
}

cmd_tunnel_config_set() {
  resolveTunnel
  local config ingress
  if hasOpt file; then
    config="$(inputFromOpts config | jq -c 'if has("config") then .config else . end')" || exit $?
  elif hasOpt ingress; then
    ingress="$(ingressFromOption "$(opt ingress)")" || exit $?
    config="$(jq -cn --argjson i "$ingress" '{ingress:$i}')"
  else
    die "Provide --ingress=host=service,... or --file=<config.json>" "$EX_ARGS"
  fi
  cfApi PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" "$(jq -cn --argjson c "$config" '{config:$c}')"
  emitResult "$(cfResult '.result.config // {}')" '.ingress[]? | "\(.hostname // "*")\t-> \(.service)"'
}

cmd_tunnel_route() {
  resolveTunnel
  requireOpt hostname
  local host service ingress existing
  host="$(opt hostname)"
  service="$(opt service)"
  if [[ -n "$service" ]]; then
    cfApi GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations"
    existing="$(cfResult '.result.config.ingress // []')"
    ingress="$(jq -cn --argjson i "$existing" --arg h "$host" --arg s "$service" '
      $i | (map(select(.hostname != $h and .hostname != null)) + [{hostname:$h, service:$s}]) + [{service:"http_status:404"}]')"
    cfApi PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" "$(jq -cn --argjson i "$ingress" '{config:{ingress:$i}}')"
    logInfo "Ingress ${host} -> ${service} saved."
  fi
  CF_ZONE_ID=""
  setOpt name "$host"
  setOpt type CNAME
  setOpt content "${CF_TUNNEL_ID}.cfargotunnel.com"
  setOpt proxied true
  logInfo "Publishing ${host} -> ${CF_TUNNEL_ID}.cfargotunnel.com..."
  cmd_dns_upsert
}

cmd_tunnel_connections() {
  resolveTunnel
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/connections"
  emitResult "$(cfResult)" '.[] | "\(.id)\t\(.version // "-")\t\(.arch // "-")\tconns=\((.conns // []) | map(.colo_name) | join(","))\trun_at=\(.run_at // "-")"' "No active connections."
}

cmd_tunnel_cleanup() {
  resolveTunnel
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/connections"
  emitMessage "Stale connections cleaned up for tunnel ${CF_TUNNEL_ID}."
}
