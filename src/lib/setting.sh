#!/usr/bin/env bash
# Octoflare module: setting
#
# Generic zone settings (get / set / apply many at once) plus the
# development-mode shortcut.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand setting list "--domain=<zone>" "Show every zone setting"
registerCommand setting get "--domain=<zone> --name=<setting>" "Show one zone setting (e.g. ssl, security_level)"
registerCommand setting set "--domain=<zone> --name=<setting> --value=<value>" "Change one zone setting"
registerCommand setting apply "--domain=<zone> --settings='{\"ssl\":\"strict\",...}' | --file=<json>" "Change many settings in one request"
registerCommand setting names "" "List common setting names and their values"
registerCommand dev-mode status "--domain=<zone>" "Show whether Development Mode is on"
registerCommand dev-mode on "--domain=<zone>" "Turn Development Mode on (bypasses cache for 3 hours)"
registerCommand dev-mode off "--domain=<zone>" "Turn Development Mode off"

SETTING_TEMPLATE='"\(.id)=\(.value|tostring)"'

# settingName - The setting id from --name/--setting or the 3rd positional argument
settingName() {
  local name
  name="$(optFirst "" name setting id)"
  [[ -z "$name" ]] && name="${ARGS[2]:-}"
  printf '%s' "$name"
}

# settingValue - The value from --value or the 4th positional argument
settingValue() {
  local v
  v="$(opt value)"
  [[ -z "$v" && -n "${ARGS[3]:-}" ]] && v="${ARGS[3]}"
  printf '%s' "$v"
}

# settingGet - GET one setting into CF_RESPONSE
settingGet() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/settings/$1"
}

# settingSet - PATCH one setting (value is converted to the JSON type the API expects)
#
# Only the settings the API types as numbers are sent as JSON numbers; every other
# scalar is sent as a string (min_tls_version "1.2", origin_max_http_version "2",
# on/off, named levels). Values given as JSON objects, arrays or booleans keep their type.
settingSet() {
  local name="$1" value="$2" json
  resolveZone
  case "$name" in
    browser_cache_ttl|challenge_ttl|max_upload|edge_cache_ttl|proxy_read_timeout)
      [[ "$value" =~ ^-?[0-9]+$ ]] || die "Setting ${name} expects a whole number (got \"${value}\")" "$EX_ARGS"
      json="$value"
      ;;
    *)
      case "$value" in
        \{*|\[*|true|false) json="$(toJsonValue "$value")" ;;
        *) json="$(jq -cn --arg v "$value" '$v')" ;;
      esac
      ;;
  esac
  cfApi PATCH "/zones/${CF_ZONE_ID}/settings/${name}" "$(jq -cn --argjson v "$json" '{value:$v}')"
}

cmd_setting_list() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/settings"
  emitResult "$(cfResult)" ".[] | $SETTING_TEMPLATE"
}

cmd_setting_get() {
  local name
  name="$(settingName)"
  [[ -z "$name" ]] && die "Missing required option --name=<setting> (e.g. --name=ssl)" "$EX_ARGS"
  settingGet "$name"
  emitResult "$(cfResult)" "$SETTING_TEMPLATE"
}

cmd_setting_set() {
  local name value
  name="$(settingName)"
  value="$(settingValue)"
  [[ -z "$name" ]] && die "Missing required option --name=<setting>" "$EX_ARGS"
  [[ -z "$value" ]] && die "Missing required option --value=<value>" "$EX_ARGS"
  logInfo "Setting ${name}=${value} on ${CF_ZONE_NAME:-zone}..."
  settingSet "$name" "$value"
  emitResult "$(cfResult)" "$SETTING_TEMPLATE"
}

cmd_setting_apply() {
  resolveZone
  local input items
  input="$(inputFromOpts settings)" || exit $?
  [[ -z "$input" ]] && die "Provide the settings with --settings='{\"ssl\":\"strict\"}' or --file=<settings.json>" "$EX_ARGS"
  items="$(printf '%s' "$input" | jq -c 'if type=="array" then . else to_entries | map({id:.key, value:.value}) end')" || die "Settings must be a JSON object or array" "$EX_ARGS"
  logInfo "Applying $(printf '%s' "$items" | jq 'length') settings to ${CF_ZONE_NAME:-$CF_ZONE_ID}..."
  cfApi PATCH "/zones/${CF_ZONE_ID}/settings" "$(jq -cn --argjson i "$items" '{items:$i}')"
  emitResult "$(cfResult)" ".[] | $SETTING_TEMPLATE"
}

cmd_setting_names() {
  local json
  json='[
    {"id":"security_level","values":"essentially_off|low|medium|high|under_attack"},
    {"id":"ssl","values":"off|flexible|full|strict"},
    {"id":"always_use_https","values":"on|off"},
    {"id":"automatic_https_rewrites","values":"on|off"},
    {"id":"min_tls_version","values":"1.0|1.1|1.2|1.3"},
    {"id":"tls_1_3","values":"on|off|zrt"},
    {"id":"opportunistic_encryption","values":"on|off"},
    {"id":"tls_client_auth","values":"on|off"},
    {"id":"security_header","values":"{\"strict_transport_security\":{\"enabled\":true,\"max_age\":31536000,\"include_subdomains\":true,\"preload\":false,\"nosniff\":true}}"},
    {"id":"development_mode","values":"on|off"},
    {"id":"cache_level","values":"aggressive|basic|simplified"},
    {"id":"browser_cache_ttl","values":"0 (respect origin) or seconds e.g. 14400"},
    {"id":"always_online","values":"on|off"},
    {"id":"brotli","values":"on|off"},
    {"id":"early_hints","values":"on|off"},
    {"id":"rocket_loader","values":"on|off"},
    {"id":"email_obfuscation","values":"on|off"},
    {"id":"hotlink_protection","values":"on|off"},
    {"id":"server_side_exclude","values":"on|off"},
    {"id":"ipv6","values":"on|off"},
    {"id":"websockets","values":"on|off"},
    {"id":"http2","values":"on|off"},
    {"id":"http3","values":"on|off"},
    {"id":"0rtt","values":"on|off"},
    {"id":"origin_max_http_version","values":"1|2"},
    {"id":"opportunistic_onion","values":"on|off"},
    {"id":"pseudo_ipv4","values":"off|add_header|overwrite_header"},
    {"id":"ip_geolocation","values":"on|off"},
    {"id":"challenge_ttl","values":"seconds e.g. 1800"},
    {"id":"browser_check","values":"on|off"},
    {"id":"privacy_pass","values":"on|off"},
    {"id":"prefetch_preload","values":"on|off"},
    {"id":"max_upload","values":"MB e.g. 100"},
    {"id":"mirage","values":"on|off (paid plans)"},
    {"id":"polish","values":"off|lossless|lossy (paid plans)"},
    {"id":"webp","values":"on|off (paid plans)"},
    {"id":"sort_query_string_for_cache","values":"on|off (paid plans)"}
  ]'
  emitResult "$(printf '%s' "$json" | jq -c .)" '.[] | "\(.id)\t\(.values)"'
}

cmd_dev_mode_status() {
  settingGet development_mode
  emitResult "$(cfResult)" '"development_mode=\(.value)\(if .time_remaining and .time_remaining > 0 then " (\(.time_remaining)s remaining)" else "" end)"'
}

cmd_dev_mode_on() {
  settingSet development_mode on
  emitResult "$(cfResult)" '"development_mode=\(.value)"'
}

cmd_dev_mode_off() {
  settingSet development_mode off
  emitResult "$(cfResult)" '"development_mode=\(.value)"'
}
