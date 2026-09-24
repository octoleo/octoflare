#!/usr/bin/env bash
# Octoflare module: cache
#
# Cache purging (everything, URLs, hosts, tags, prefixes), cache related
# settings overview and Smart Tiered Cache.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand cache purge "--domain=<zone> (--everything | --urls=a,b | --hosts=a,b | --tags=a,b | --prefixes=a,b)" "Purge cached content"
registerCommand cache status "--domain=<zone>" "Show cache related settings"
registerCommand cache level "--domain=<zone> [--value=aggressive|basic|simplified]" "Get or set the cache level"
registerCommand cache browser-ttl "--domain=<zone> [--value=<seconds>]" "Get or set the browser cache TTL"
registerCommand cache tiered "--domain=<zone> [on|off]" "Get or set Smart Tiered Cache"

cmd_cache_purge() {
  resolveZone
  local body="" urls hosts tags prefixes
  urls="$(optFirst "" urls files url file)"
  hosts="$(optFirst "" hosts host)"
  tags="$(optFirst "" tags tag)"
  prefixes="$(optFirst "" prefixes prefix)"
  if [[ "$(optBool everything)" == "true" || "$(optBool all)" == "true" ]]; then
    body='{"purge_everything":true}'
  elif [[ -n "$urls" ]]; then
    body="$(jq -cn --argjson f "$(toJsonArray "$(readFileOrValue "$urls" | tr '\n' ',')")" '{files:$f}')"
  elif [[ -n "$hosts" ]]; then
    body="$(jq -cn --argjson h "$(toJsonArray "$hosts")" '{hosts:$h}')"
  elif [[ -n "$tags" ]]; then
    body="$(jq -cn --argjson t "$(toJsonArray "$tags")" '{tags:$t}')"
  elif [[ -n "$prefixes" ]]; then
    body="$(jq -cn --argjson p "$(toJsonArray "$prefixes")" '{prefixes:$p}')"
  else
    die "Choose what to purge: --everything, --urls=<a,b>, --hosts=<a,b>, --tags=<a,b> or --prefixes=<a,b> (hosts, tags and prefixes need an Enterprise plan)" "$EX_ARGS"
  fi
  logInfo "Purging cache for ${CF_ZONE_NAME:-$CF_ZONE_ID}: $(printf '%s' "$body" | jq -c .)"
  cfApi POST "/zones/${CF_ZONE_ID}/purge_cache" "$body"
  emitMessage "Cache purge submitted for ${CF_ZONE_NAME:-$CF_ZONE_ID}." "$(cfResult '{result:.result, request:'"$body"'}')"
}

cmd_cache_status() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/settings"
  local settings tiered='null'
  settings="$(cfResult '[.result[] | select(.id | IN("cache_level","browser_cache_ttl","development_mode","always_online","sort_query_string_for_cache","early_hints","brotli"))] | map({(.id):.value}) | add')"
  if cfApiTry GET "/zones/${CF_ZONE_ID}/cache/tiered_cache_smart_topology_enable"; then
    tiered="$(cfResult '.result.value // null')"
  fi
  emitResult "$(jq -cn --argjson s "$settings" --argjson t "$tiered" '$s + {smart_tiered_cache:$t}')" 'to_entries[] | "\(.key)=\(.value|tostring)"'
}

# cacheSettingGetOrSet - Get a setting, or set it when a value is provided
cacheSettingGetOrSet() {
  local name="$1" value
  value="$(opt value)"
  [[ -z "$value" && -n "${ARGS[2]:-}" ]] && value="${ARGS[2]}"
  if [[ -n "$value" ]]; then
    settingSet "$name" "$value"
  else
    settingGet "$name"
  fi
  emitResult "$(cfResult)" '"\(.id)=\(.value|tostring)"'
}

cmd_cache_level() { cacheSettingGetOrSet cache_level; }
cmd_cache_browser_ttl() { cacheSettingGetOrSet browser_cache_ttl; }

cmd_cache_tiered() {
  resolveZone
  local value
  value="$(opt value)"
  [[ -z "$value" && -n "${ARGS[2]:-}" ]] && value="${ARGS[2]}"
  if [[ -n "$value" ]]; then
    case "$(normalizeBool "$value")" in
      true) value=on ;;
      *) value=off ;;
    esac
    cfApi PATCH "/zones/${CF_ZONE_ID}/cache/tiered_cache_smart_topology_enable" "$(jq -cn --arg v "$value" '{value:$v}')"
  else
    cfApi GET "/zones/${CF_ZONE_ID}/cache/tiered_cache_smart_topology_enable"
  fi
  emitResult "$(cfResult)" '"smart_tiered_cache=\(.value)"'
}
