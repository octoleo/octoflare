#!/usr/bin/env bash
# Octoflare module: ssl
#
# SSL/TLS settings (mode, minimum TLS, TLS 1.3, Always Use HTTPS, HTTPS
# rewrites, HSTS), Universal SSL, certificate packs and verification,
# Origin CA certificates and DNSSEC.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand ssl status "--domain=<zone>" "Overview of the SSL/TLS configuration"
registerCommand ssl mode "--domain=<zone> [off|flexible|full|strict]" "Get or set the SSL/TLS encryption mode"
registerCommand ssl min-tls "--domain=<zone> [1.0|1.1|1.2|1.3]" "Get or set the minimum TLS version"
registerCommand ssl tls13 "--domain=<zone> [on|off]" "Get or set TLS 1.3"
registerCommand ssl always-https "--domain=<zone> [on|off]" "Get or set Always Use HTTPS"
registerCommand ssl auto-rewrites "--domain=<zone> [on|off]" "Get or set Automatic HTTPS Rewrites"
registerCommand ssl opportunistic-encryption "--domain=<zone> [on|off]" "Get or set Opportunistic Encryption"
registerCommand ssl hsts "--domain=<zone> [--max-age=31536000] [--include-subdomains] [--preload] [--nosniff] | --disable" "Get or set HTTP Strict Transport Security"
registerCommand ssl universal "--domain=<zone> [on|off]" "Get or set Universal SSL"
registerCommand ssl verification "--domain=<zone>" "Show certificate verification status"
registerCommand ssl certificates "--domain=<zone>" "List certificate packs (edge certificates)"
registerCommand ssl origin-cert-list "--domain=<zone>" "List Origin CA certificates"
registerCommand ssl origin-cert-create "--hostnames=<a,b> [--validity=5475] [--type=origin-rsa|origin-ecc] [--csr=@file] [--key-out=<file>] [--cert-out=<file>]" "Create an Origin CA certificate (generates a key + CSR with openssl when --csr is omitted)"
registerCommand ssl origin-cert-get "--id=<certificate-id>" "Show an Origin CA certificate"
registerCommand ssl origin-cert-revoke "--id=<certificate-id>" "Revoke an Origin CA certificate"
registerCommand dnssec status "--domain=<zone>" "Show DNSSEC status and DS record"
registerCommand dnssec enable "--domain=<zone>" "Enable DNSSEC (returns the DS record for the registrar)"
registerCommand dnssec disable "--domain=<zone>" "Disable DNSSEC"

# sslSettingCmd - Get, or set when a value is given (positional or --value)
sslSettingCmd() {
  local name="$1" value
  value="$(opt value)"
  [[ -z "$value" && -n "${ARGS[2]:-}" ]] && value="${ARGS[2]}"
  if [[ -n "$value" ]]; then
    case "$name" in
      ssl|min_tls_version) ;;
      *) case "$(normalizeBool "$value")" in true) value=on ;; false) [[ "$value" != "zrt" ]] && value=off ;; esac ;;
    esac
    settingSet "$name" "$value"
  else
    settingGet "$name"
  fi
  emitResult "$(cfResult)" '"\(.id)=\(.value|tostring)"'
}

cmd_ssl_status() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/settings"
  local settings universal='null' packs='[]'
  settings="$(cfResult '[.result[] | select(.id | IN("ssl","min_tls_version","tls_1_3","always_use_https","automatic_https_rewrites","opportunistic_encryption","security_header","tls_client_auth"))] | map({(.id):.value}) | add')"
  cfApiTry GET "/zones/${CF_ZONE_ID}/ssl/universal/settings" && universal="$(cfResult '.result.enabled // null')"
  cfApiTry GET "/zones/${CF_ZONE_ID}/ssl/certificate_packs?status=all" && packs="$(cfResult '[.result[]? | {id, type, status, hosts, certificate_authority, validity_days, expires_on:(.certificates[0].expires_on // null)}]')"
  emitResult "$(jq -cn --argjson s "$settings" --argjson u "$universal" --argjson p "$packs" '$s + {universal_ssl:$u, certificate_packs:$p}')" \
    'to_entries[] | if .key == "certificate_packs" then "certificate_packs=" + ([.value[] | "\(.type):\(.status)"] | join(",")) elif .key == "security_header" then "hsts=" + (.value.strict_transport_security|tostring) else "\(.key)=\(.value|tostring)" end'
}

cmd_ssl_mode() { sslSettingCmd ssl; }
cmd_ssl_min_tls() { sslSettingCmd min_tls_version; }
cmd_ssl_tls13() { sslSettingCmd tls_1_3; }
cmd_ssl_always_https() { sslSettingCmd always_use_https; }
cmd_ssl_auto_rewrites() { sslSettingCmd automatic_https_rewrites; }
cmd_ssl_opportunistic_encryption() { sslSettingCmd opportunistic_encryption; }

cmd_ssl_hsts() {
  resolveZone
  local body
  if [[ "$(optBool disable)" == "true" ]]; then
    body='{"strict_transport_security":{"enabled":false}}'
  elif hasOpt max-age || hasOpt include-subdomains || hasOpt preload || hasOpt nosniff || [[ "$(optBool enable)" == "true" ]]; then
    body="$(jq -cn --argjson age "$(opt max-age 31536000)" --argjson sub "$(optBool include-subdomains false)" --argjson pre "$(optBool preload false)" --argjson ns "$(optBool nosniff true)" \
      '{strict_transport_security:{enabled:true, max_age:$age, include_subdomains:$sub, preload:$pre, nosniff:$ns}}')"
  fi
  if [[ -n "$body" ]]; then
    cfApi PATCH "/zones/${CF_ZONE_ID}/settings/security_header" "$(jq -cn --argjson v "$body" '{value:$v}')"
  else
    settingGet security_header
  fi
  emitResult "$(cfResult '.result.value.strict_transport_security')" 'to_entries[] | "\(.key)=\(.value)"'
}

cmd_ssl_universal() {
  resolveZone
  local value
  value="$(opt value)"
  [[ -z "$value" && -n "${ARGS[2]:-}" ]] && value="${ARGS[2]}"
  if [[ -n "$value" ]]; then
    cfApi PATCH "/zones/${CF_ZONE_ID}/ssl/universal/settings" "$(jq -cn --argjson v "$(normalizeBool "$value")" '{enabled:$v}')"
  else
    cfApi GET "/zones/${CF_ZONE_ID}/ssl/universal/settings"
  fi
  emitResult "$(cfResult)" '"universal_ssl=\(.enabled)"'
}

cmd_ssl_verification() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/ssl/verification"
  emitResult "$(cfResult)" '.[] | "\(.certificate_status)\t\(.hostname // "-")\t\(.validation_method // "-")\t\(.verification_type // "-")\tpack=\(.cert_pack_uuid // "-")"' "No certificate verification data."
}

cmd_ssl_certificates() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/ssl/certificate_packs?status=all"
  emitResult "$(cfResult)" '.[] | "\(.id)\t\(.type)\t\(.status)\t\(.certificate_authority // "-")\thosts=\((.hosts // [])|join(","))\texpires=\(.certificates[0].expires_on // "-")"' "No certificate packs."
}

#####################################################################################################################VDM
######################################## Origin CA

# originCaAuth - Use the Origin CA key when it is configured
originCaAuth() {
  [[ -n "${CLOUDFLARE_ORIGIN_CA_KEY:-}" ]] && CF_AUTH_MODE="origin-ca"
  return 0
}

cmd_ssl_origin_cert_list() {
  resolveZone
  originCaAuth
  cfApi GET "/certificates?zone_id=${CF_ZONE_ID}"
  emitResult "$(cfResult)" '.[] | "\(.id)\t\(.request_type)\thosts=\((.hostnames // [])|join(","))\texpires=\(.expires_on)"' "No Origin CA certificates."
}

cmd_ssl_origin_cert_get() {
  requireOpt id
  originCaAuth
  cfApi GET "/certificates/$(opt id)"
  emitResult "$(cfResult)" '"id=\(.id)\ntype=\(.request_type)\nhostnames=\((.hostnames // [])|join(","))\nexpires_on=\(.expires_on)\n\(.certificate // "")"'
}

cmd_ssl_origin_cert_revoke() {
  requireOpt id
  originCaAuth
  confirm "Revoke Origin CA certificate $(opt id)?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/certificates/$(opt id)"
  emitMessage "Origin CA certificate $(opt id) revoked." "$(cfResult)"
}

cmd_ssl_origin_cert_create() {
  local hostnames csr key_out cert_out type validity body tmpdir key_file csr_file first
  hostnames="$(optFirst "" hostnames hostname hosts)"
  [[ -z "$hostnames" ]] && die "Missing --hostnames=<a,b> (e.g. --hostnames=example.com,*.example.com)" "$EX_ARGS"
  type="$(opt type origin-rsa)"
  validity="$(opt validity 5475)"
  key_out="$(opt key-out)"
  cert_out="$(opt cert-out)"
  if hasOpt csr; then
    csr="$(readFileOrValue "$(opt csr)")"
  else
    ensureDependency openssl openssl
    tmpdir="$(mktemp -d)"
    key_file="${key_out:-${tmpdir}/origin.key}"
    csr_file="${tmpdir}/origin.csr"
    first="$(printf '%s' "$hostnames" | cut -d, -f1)"
    logInfo "Generating private key and CSR for ${hostnames}..."
    if [[ "$type" == "origin-ecc" ]]; then
      openssl ecparam -name prime256v1 -genkey -noout -out "$key_file" 2>/dev/null || die "openssl failed to generate an ECC key" "$EX_FAILURE"
    else
      openssl genrsa -out "$key_file" 2048 2>/dev/null || die "openssl failed to generate an RSA key" "$EX_FAILURE"
    fi
    openssl req -new -key "$key_file" -subj "/CN=${first}" -out "$csr_file" 2>/dev/null || die "openssl failed to generate a CSR" "$EX_FAILURE"
    csr="$(cat "$csr_file")"
    rm -f "$csr_file"
    [[ -z "$key_out" ]] && logWarn "Private key written to ${key_file} (use --key-out=<file> to choose the location)."
  fi
  originCaAuth
  body="$(jq -cn --arg csr "$csr" --argjson h "$(toJsonArray "$hostnames")" --arg t "$type" --argjson v "$validity" '{csr:$csr, hostnames:$h, request_type:$t, requested_validity:$v}')"
  cfApi POST "/certificates" "$body"
  if [[ -n "$cert_out" ]]; then
    cfResultRaw '.result.certificate // ""' >"$cert_out"
    logInfo "Certificate written to ${cert_out}."
  fi
  emitResult "$(cfResult '.result | {id, hostnames, request_type, expires_on, certificate, key_file:'"$(jq -cn --arg k "${key_file:-}" '$k')"'}')" '"id=\(.id)\nhostnames=\((.hostnames // [])|join(","))\nexpires_on=\(.expires_on)\nkey_file=\(.key_file)\n\(.certificate // "")"'
}

#####################################################################################################################VDM
######################################## DNSSEC

DNSSEC_TEMPLATE='"status=\(.status)\nds=\(.ds // "-")\ndigest=\(.digest // "-")\ndigest_type=\(.digest_type // "-")\nalgorithm=\(.algorithm // "-")\nkey_tag=\(.key_tag // "-")\npublic_key=\(.public_key // "-")"'

cmd_dnssec_status() {
  resolveZone
  cfApi GET "/zones/${CF_ZONE_ID}/dnssec"
  emitResult "$(cfResult)" "$DNSSEC_TEMPLATE"
}

cmd_dnssec_enable() {
  resolveZone
  logInfo "Enabling DNSSEC for ${CF_ZONE_NAME:-$CF_ZONE_ID} (add the DS record at your registrar to finish)..."
  cfApi PATCH "/zones/${CF_ZONE_ID}/dnssec" '{"status":"active"}'
  emitResult "$(cfResult)" "$DNSSEC_TEMPLATE"
}

cmd_dnssec_disable() {
  resolveZone
  cfApi PATCH "/zones/${CF_ZONE_ID}/dnssec" '{"status":"disabled"}'
  emitResult "$(cfResult)" "$DNSSEC_TEMPLATE"
}
