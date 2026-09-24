#!/usr/bin/env bash
# Octoflare module: api
#
# Cloudflare v4 API transport: authentication, retries, pagination, dry-run,
# error reporting, and zone / account resolution helpers.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

OCTOFLARE_TIMEOUT="${OCTOFLARE_TIMEOUT:-60}"
OCTOFLARE_RETRIES="${OCTOFLARE_RETRIES:-3}"
OCTOFLARE_RETRY_DELAY="${OCTOFLARE_RETRY_DELAY:-2}"
OCTOFLARE_PER_PAGE="${OCTOFLARE_PER_PAGE:-50}" # 50 is within every page-numbered endpoint's per_page contract

CF_RESPONSE=""       # Body of the last response
CF_HTTP_CODE=""      # HTTP status code of the last response
CF_REQUEST=""        # JSON describing the last request (method, url, body)
CF_AUTH_MODE="token" # token | origin-ca
CF_AUTH_ARGS=()      # curl options carrying the credentials (-K <config file>, never a header in argv)
CF_REQUEST_SEQ=0     # Counter used to give every request body its own temp file
CF_ZONE_ID=""
CF_ZONE_NAME=""
CF_ACCOUNT_ID=""
CF_ZONES_CACHE=""
DRY_RUN_REQUESTS="[]"

#####################################################################################################################VDM
######################################## Transport

# cfTmpDir - Make sure the private temp directory exists (normally created at startup)
cfTmpDir() {
  [[ -n "${OCTOFLARE_TMPDIR:-}" && -d "$OCTOFLARE_TMPDIR" ]] && return 0
  octoflareTmpDir
}

# cfConfigLine - Print one curl config line: name = "value" (value escaped for curl's quoting rules)
cfConfigLine() {
  local value="$2"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s = "%s"\n' "$1" "$value"
}

# cfAuthArgs - Fill CF_AUTH_ARGS with the curl options for the active credentials
#
# The credential headers are written to a 0600 curl config file under OCTOFLARE_TMPDIR and
# passed with -K, so tokens never appear in the curl command line (ps, /proc/PID/cmdline).
cfAuthArgs() {
  CF_AUTH_ARGS=()
  local file
  cfTmpDir
  file="${OCTOFLARE_TMPDIR}/curl.auth.$$"
  (
    umask 077
    {
      if [[ "$CF_AUTH_MODE" == "origin-ca" && -n "${CLOUDFLARE_ORIGIN_CA_KEY:-}" ]]; then
        cfConfigLine header "X-Auth-User-Service-Key: ${CLOUDFLARE_ORIGIN_CA_KEY}"
      elif [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        cfConfigLine header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
      elif [[ -n "${CLOUDFLARE_API_KEY:-}" && -n "${CLOUDFLARE_EMAIL:-}" ]]; then
        cfConfigLine header "X-Auth-Email: ${CLOUDFLARE_EMAIL}"
        cfConfigLine header "X-Auth-Key: ${CLOUDFLARE_API_KEY}"
      fi
    } >"$file"
  ) || die "Could not write the curl configuration in ${OCTOFLARE_TMPDIR}" "$EX_SOFTWARE"
  chmod 600 "$file"
  CF_AUTH_ARGS=(-K "$file")
}

# cfUrl - Build the full URL for an API path
#
# Accepts a path (relative to CLOUDFLARE_API_BASE) or an absolute URL that starts with
# CLOUDFLARE_API_BASE; any other URL dies with EX_ARGS so credentials are never sent elsewhere.
cfUrl() {
  local base="${CLOUDFLARE_API_BASE%/}"
  case "$1" in
    http://*|https://*)
      if [[ "$1" == "$base" || "$1" == "${base}/"* || "$1" == "${base}?"* ]]; then
        printf '%s' "$1"
      else
        die "Refusing to send a Cloudflare API request to ${1}: only paths under ${base} are allowed." "$EX_ARGS"
      fi
      ;;
    /*) printf '%s%s' "$base" "$1" ;;
    *) printf '%s/%s' "$base" "$1" ;;
  esac
}

# urlEncode - Percent-encode a string for use in a query string
urlEncode() {
  jq -rn --arg v "$1" '$v|@uri'
}

# cfRequest - Perform one HTTP request against the Cloudflare API (low level)
#
# Arguments:
#   $1: HTTP method
#   $2: API path (relative to CLOUDFLARE_API_BASE) or absolute URL
#   $3: request body (optional)
#   $4: content type (default application/json; "multipart" for -F uploads; "none" for no body)
#   $5..: extra curl arguments (e.g. -F file=@worker.js)
#
# Globals set:
#   CF_RESPONSE, CF_HTTP_CODE, CF_REQUEST
#
# Returns:
#   0 for a 2xx response, 1 otherwise (network failures included)
cfRequest() {
  local method="$1" path="$2" body="${3:-}" ctype="${4:-application/json}"
  shift 2
  [[ $# -gt 0 ]] && shift
  [[ $# -gt 0 ]] && shift
  local url attempt=0 delay rc out hdr_file body_file retry_after retry
  url="$(cfUrl "$path")" || exit $?
  if [[ "${CF_NO_AUTH:-false}" == "true" ]]; then
    CF_AUTH_ARGS=()
  else
    requireAuth
    cfAuthArgs
  fi
  # The body goes through a private temp file (never argv: bodies can exceed the per-argument
  # exec limit and may hold secrets that would otherwise show up in the process list).
  cfTmpDir
  CF_REQUEST_SEQ=$((CF_REQUEST_SEQ + 1))
  body_file="${OCTOFLARE_TMPDIR}/body.$$.${CF_REQUEST_SEQ}.${RANDOM}"
  printf '%s' "$body" >"$body_file" || die "Could not write the request body in ${OCTOFLARE_TMPDIR}" "$EX_SOFTWARE"
  local -a curl_args
  curl_args=(-sS --max-time "$OCTOFLARE_TIMEOUT" -X "$method" "$url" -w $'\n%{http_code}' -H "User-Agent: ${PROGRAM_NAME}/${PROGRAM_VERSION}")
  curl_args+=(${CF_AUTH_ARGS[@]+"${CF_AUTH_ARGS[@]}"})
  case "$ctype" in
    none|multipart) ;;
    *)
      curl_args+=(-H "Content-Type: ${ctype}")
      [[ -n "$body" ]] && curl_args+=(--data-binary "@${body_file}")
      ;;
  esac
  curl_args+=("$@")

  CF_REQUEST="$(jq -cn --arg m "$method" --arg u "$url" --rawfile b "$body_file" --arg ct "$ctype" \
    '{method:$m, url:$u, content_type:$ct, body:(if $b=="" then null else (try ($b|fromjson) catch $b) end)}')"
  logDebug "API ${method} ${url}"
  [[ -n "$body" && "$OCTOFLARE_DEBUG" == "true" ]] && logDebug "Body: ${body}"

  if [[ "$OCTOFLARE_DRY_RUN" == "true" ]]; then
    logInfo "[dry-run] ${method} ${url}${body:+ ${body}}"
    DRY_RUN_REQUESTS="$(printf '%s\n%s\n' "$DRY_RUN_REQUESTS" "$CF_REQUEST" | jq -cs '.[0] + [.[1]]')"
    CF_HTTP_CODE=200
    if [[ "$method" == "GET" ]]; then
      CF_RESPONSE='{"success":true,"errors":[],"messages":[],"result":null,"result_info":{"page":1,"total_pages":1,"count":0,"total_count":0},"dry_run":true}'
    else
      CF_RESPONSE="$(printf '%s' "$CF_REQUEST" | jq -c '{success:true, errors:[], messages:[], result:.body, dry_run:true, request:.}')"
    fi
    rm -f "$body_file"
    return 0
  fi

  # Retry policy: 5xx replies and network failures are retried only for methods that are safe
  # to replay (GET/HEAD/PUT/DELETE/PATCH). A POST is not idempotent: the server may already have
  # processed it (e.g. a timeout after the record was created), so replaying it would create
  # duplicates. POST is retried only on 429, which guarantees the request was rejected unprocessed.
  case "$method" in
    POST) retry=429 ;;
    *) retry=all ;;
  esac
  delay="$OCTOFLARE_RETRY_DELAY"
  hdr_file="${OCTOFLARE_TMPDIR}/headers.$$.${CF_REQUEST_SEQ}"
  while :; do
    attempt=$((attempt + 1))
    out="$(curl "${curl_args[@]}" -D "$hdr_file" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      CF_HTTP_CODE="${out##*$'\n'}"
      CF_RESPONSE="${out%$'\n'*}"
      [[ "$CF_RESPONSE" == "$out" ]] && CF_RESPONSE=""
      case "$CF_HTTP_CODE" in
        429|500|502|503|504)
          if [[ $attempt -le $OCTOFLARE_RETRIES && ( "$retry" == "all" || "$CF_HTTP_CODE" == "429" ) ]]; then
            retry_after="$(grep -i '^retry-after:' "$hdr_file" 2>/dev/null | tail -n1 | tr -d '\r' | awk '{print $2}')"
            [[ "$retry_after" =~ ^[0-9]+$ ]] && delay="$retry_after"
            logWarn "Cloudflare API returned HTTP ${CF_HTTP_CODE}; retrying in ${delay}s (attempt ${attempt}/${OCTOFLARE_RETRIES})..."
            sleep "$delay"
            delay=$((delay * 2))
            continue
          fi
          ;;
      esac
      rm -f "$hdr_file" "$body_file"
      [[ "$CF_HTTP_CODE" =~ ^2 ]] && return 0
      return 1
    fi
    CF_HTTP_CODE="000"
    CF_RESPONSE="$(jq -cn --arg e "$out" --arg rc "$rc" '{success:false, errors:[{code:0, message:("curl failed (exit " + $rc + "): " + $e)}], messages:[], result:null}')"
    if [[ $attempt -le $OCTOFLARE_RETRIES && "$retry" == "all" ]]; then
      logWarn "Network error talking to Cloudflare (curl exit ${rc}); retrying in ${delay}s (attempt ${attempt}/${OCTOFLARE_RETRIES})..."
      sleep "$delay"
      delay=$((delay * 2))
      continue
    fi
    rm -f "$hdr_file" "$body_file"
    return 1
  done
}

# cfResponseOk - True when the last response is a successful API envelope (or non-envelope 2xx)
cfResponseOk() {
  [[ "$CF_HTTP_CODE" =~ ^2 ]] || return 1
  local success
  success="$(printf '%s' "$CF_RESPONSE" | jq -r 'if type=="object" and has("success") then (.success|tostring) else "true" end' 2>/dev/null)"
  [[ "$success" != "false" ]]
}

# cfErrors - Human readable error lines from the last response
cfErrors() {
  local errs
  errs="$(printf '%s' "$CF_RESPONSE" | jq -r '
    if type=="object" then
      ([.errors[]? | "  - [\(.code // 0)] \(.message // "unknown error")\(if .error_chain then " (" + ([.error_chain[]?.message] | join("; ")) + ")" else "" end)"] +
       [.messages[]? | select(type=="object") | "  - \(.message)"]) | join("\n")
    else empty end' 2>/dev/null)"
  if [[ -z "$errs" ]]; then
    errs="  - HTTP ${CF_HTTP_CODE}: $(printf '%s' "$CF_RESPONSE" | head -c 400)"
  fi
  printf '%s' "$errs"
}

# cfReportError - Log the errors of the last failed request
cfReportError() {
  local method url
  method="$(printf '%s' "$CF_REQUEST" | jq -r '.method')"
  url="$(printf '%s' "$CF_REQUEST" | jq -r '.url')"
  logError "Cloudflare API request failed: ${method} ${url} (HTTP ${CF_HTTP_CODE})"
  printf '%s\n' "$(cfErrors)" >&2
}

# cfApiTry - Perform a request; return non-zero on failure without exiting
#
# Arguments: see cfRequest
cfApiTry() {
  cfRequest "$@"
  cfResponseOk
}

# cfApi - Perform a request; log errors and exit on failure
#
# Arguments: see cfRequest
cfApi() {
  if ! cfApiTry "$@"; then
    cfReportError
    case "$CF_HTTP_CODE" in
      401|403) exit "$EX_CONFIG" ;;
      404) exit "$EX_NOTFOUND" ;;
      *) exit "$EX_FAILURE" ;;
    esac
  fi
}

# cfResult - Extract a value from the last response with jq (default .result)
cfResult() {
  printf '%s' "$CF_RESPONSE" | jq -c "${1:-.result}"
}

# cfResultRaw - Extract a raw string from the last response
cfResultRaw() {
  printf '%s' "$CF_RESPONSE" | jq -r "${1:-.result}"
}

# cfQuery - Join query parameters ("a=1" "b=x y") into an encoded query string
cfQuery() {
  local param out="" key value
  for param in "$@"; do
    [[ -z "$param" ]] && continue
    key="${param%%=*}"
    value="${param#*=}"
    [[ -z "$value" ]] && continue
    out="${out}&${key}=$(urlEncode "$value")"
  done
  printf '%s' "${out#&}"
}

# cfPath - Append a query string to a path
cfPath() {
  local path="$1" query="${2:-}"
  [[ -z "$query" ]] && { printf '%s' "$path"; return; }
  case "$path" in
    *\?*) printf '%s&%s' "$path" "$query" ;;
    *) printf '%s?%s' "$path" "$query" ;;
  esac
}

#####################################################################################################################VDM
######################################## Pagination

# cfApiList - Fetch every page of a page-numbered list endpoint
#
# Arguments:
#   $1: path
#   $2: query string (optional, already encoded)
#   $3: maximum per_page the endpoint accepts (default OCTOFLARE_PER_PAGE, 50)
#
# With --limit=N the pages are requested with per_page=min(N, max) and the fetch stops as
# soon as N items were collected (which may take more than one page).
#
# Globals set:
#   CF_RESPONSE = {"success":true,"result":[...all items...]}
cfApiList() {
  local path="$1" query="${2:-}" page=1 total_pages per_page="${3:-$OCTOFLARE_PER_PAGE}" all='[]' items count limit total
  limit="$(opt limit)"
  if [[ -n "$limit" ]]; then
    [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]] || die "--limit must be a positive number (got '${limit}')." "$EX_ARGS"
    [[ "$limit" -lt "$per_page" ]] && per_page="$limit"
  fi
  while :; do
    cfApi GET "$(cfPath "$path" "${query:+${query}&}page=${page}&per_page=${per_page}")"
    items="$(cfResult '.result // []')"
    [[ "$(printf '%s' "$items" | jq -r 'type')" != "array" ]] && items="[$items]"
    all="$(printf '%s\n%s\n' "$all" "$items" | jq -cs '.[0] + .[1]')"
    total_pages="$(cfResultRaw '.result_info.total_pages // empty')"
    count="$(printf '%s' "$items" | jq 'length')"
    if [[ -n "$limit" ]]; then
      total="$(printf '%s' "$all" | jq 'length')"
      if [[ "$total" -ge "$limit" ]]; then
        all="$(printf '%s' "$all" | jq -c --argjson n "$limit" '.[:$n]')"
        break
      fi
    fi
    if [[ -n "$total_pages" ]]; then
      [[ $page -ge $total_pages ]] && break
    else
      [[ $count -lt $per_page ]] && break
    fi
    page=$((page + 1))
    [[ $page -gt 1000 ]] && break
  done
  CF_RESPONSE="$(printf '%s' "$all" | jq -c '{success:true, errors:[], messages:[], result:.}')"
}

# cfApiCursor - Fetch every page of a cursor-based list endpoint
#
# Arguments:
#   $1: path
#   $2: query string (optional)
cfApiCursor() {
  local path="$1" query="${2:-}" cursor="" all='[]' items q
  while :; do
    q="$query"
    [[ -n "$cursor" ]] && q="${q:+${q}&}cursor=$(urlEncode "$cursor")"
    cfApi GET "$(cfPath "$path" "$q")"
    items="$(cfResult '.result // []')"
    all="$(printf '%s\n%s\n' "$all" "$items" | jq -cs '.[0] + .[1]')"
    cursor="$(cfResultRaw '.result_info.cursors.after // .result_info.cursor // empty')"
    [[ -z "$cursor" || -n "$(opt limit)" ]] && break
  done
  CF_RESPONSE="$(printf '%s' "$all" | jq -c '{success:true, errors:[], messages:[], result:.}')"
}

#####################################################################################################################VDM
######################################## Zone & account resolution

# zoneOption - The zone/domain requested on the command line or environment
zoneOption() {
  optFirst "${CLOUDFLARE_DOMAIN:-}" domain zone
}

# guessDomainFromName - Derive a domain from --name/--hostname/--record when no --domain was given
guessDomainFromName() {
  local name
  name="$(optFirst "" name hostname host record fqdn)"
  [[ -z "$name" ]] && return 1
  name="${name#\*.}"
  [[ "$name" == *.* ]] || return 1
  printf '%s' "$name"
}

# lookupZone - Find a zone by name, walking up the labels (www.example.com -> example.com)
#
# Arguments:
#   $1: domain or hostname
#
# Globals set:
#   CF_ZONE_ID, CF_ZONE_NAME, CF_ACCOUNT_ID (when not set)
lookupZone() {
  local candidate="$1" zone_id="" labels
  candidate="$(lower "${candidate%.}")"
  while [[ -n "$candidate" ]]; do
    cfApi GET "/zones?name=$(urlEncode "$candidate")&per_page=5"
    zone_id="$(cfResultRaw '.result[0].id // empty')"
    if [[ -n "$zone_id" ]]; then
      CF_ZONE_ID="$zone_id"
      CF_ZONE_NAME="$(cfResultRaw '.result[0].name')"
      [[ -z "$CF_ACCOUNT_ID" ]] && CF_ACCOUNT_ID="$(cfResultRaw '.result[0].account.id // empty')"
      return 0
    fi
    if [[ "$OCTOFLARE_DRY_RUN" == "true" ]]; then
      CF_ZONE_ID="dry-run-zone-id"
      CF_ZONE_NAME="$candidate"
      return 0
    fi
    labels="$(printf '%s' "$candidate" | tr -cd '.' | wc -c | tr -d ' ')"
    [[ "$labels" -lt 2 ]] && break
    candidate="${candidate#*.}"
  done
  return 1
}

# resolveZone - Resolve the zone from --zone-id, --domain/--zone, CLOUDFLARE_*, or an FQDN option
#
# Precedence: an explicit --zone-id skips the lookup; an explicit --domain/--zone is always
# looked up by name (an ambient CLOUDFLARE_ZONE_ID is ignored so the command cannot silently run
# against another zone); otherwise CLOUDFLARE_ZONE_ID, then CLOUDFLARE_DOMAIN / an FQDN option.
#
# Globals set:
#   CF_ZONE_ID, CF_ZONE_NAME
resolveZone() {
  [[ -n "$CF_ZONE_ID" ]] && return 0
  local zone_id domain
  domain="$(zoneOption)"
  if hasOpt zone-id; then
    zone_id="$(opt zone-id)"
  elif hasOpt domain || hasOpt zone; then
    zone_id=""
  else
    zone_id="${CLOUDFLARE_ZONE_ID:-}"
  fi
  if [[ -n "$zone_id" ]]; then
    CF_ZONE_ID="$zone_id"
    CF_ZONE_NAME="$(lower "${domain%.}")"
    if [[ -z "$CF_ZONE_NAME" ]]; then
      if cfApiTry GET "/zones/${zone_id}"; then
        CF_ZONE_NAME="$(cfResultRaw '.result.name // empty')"
        [[ -z "$CF_ACCOUNT_ID" ]] && CF_ACCOUNT_ID="$(cfResultRaw '.result.account.id // empty')"
      elif [[ "$OCTOFLARE_DRY_RUN" != "true" ]]; then
        cfReportError
        exit "$EX_ZONE"
      fi
    fi
    logDebug "Using zone ${CF_ZONE_ID} (${CF_ZONE_NAME:-unknown name})"
    return 0
  fi
  [[ -z "$domain" ]] && domain="$(guessDomainFromName || true)"
  [[ -z "$domain" ]] && die "No zone specified. Use --domain=example.com or --zone-id=<id> (or set CLOUDFLARE_DOMAIN / CLOUDFLARE_ZONE_ID)." "$EX_ZONE"
  lookupZone "$domain" || die "Could not find a Cloudflare zone for ${domain} (check the domain and the token's Zone:Read permission)." "$EX_ZONE"
  logDebug "Resolved zone ${CF_ZONE_NAME} -> ${CF_ZONE_ID}"
}

# resolveAccount - Resolve the account id from --account-id, CLOUDFLARE_ACCOUNT_ID, the zone, or the token's accounts
#
# Globals set:
#   CF_ACCOUNT_ID
resolveAccount() {
  [[ -n "$CF_ACCOUNT_ID" ]] && return 0
  local id count
  id="$(optFirst "${CLOUDFLARE_ACCOUNT_ID:-}" account-id account)"
  if [[ -n "$id" ]]; then
    CF_ACCOUNT_ID="$id"
    return 0
  fi
  if [[ -n "$(zoneOption)" || -n "$(optFirst "${CLOUDFLARE_ZONE_ID:-}" zone-id)" ]]; then
    resolveZone
    [[ -n "$CF_ACCOUNT_ID" ]] && return 0
    if [[ "$CF_ZONE_ID" != "dry-run-zone-id" ]]; then
      cfApi GET "/zones/${CF_ZONE_ID}"
      CF_ACCOUNT_ID="$(cfResultRaw '.result.account.id // empty')"
      [[ -n "$CF_ACCOUNT_ID" ]] && return 0
    fi
  fi
  cfApi GET "/accounts?per_page=50"
  count="$(cfResultRaw '.result | length')"
  if [[ "$count" == "1" ]]; then
    CF_ACCOUNT_ID="$(cfResultRaw '.result[0].id')"
    logDebug "Resolved account ${CF_ACCOUNT_ID}"
    return 0
  fi
  if [[ "$OCTOFLARE_DRY_RUN" == "true" ]]; then
    CF_ACCOUNT_ID="dry-run-account-id"
    return 0
  fi
  if [[ "$count" == "0" ]]; then
    die "No Cloudflare account is visible to this token. Set --account-id=<id> (or CLOUDFLARE_ACCOUNT_ID)." "$EX_CONFIG"
  fi
  logError "Multiple Cloudflare accounts are available; choose one with --account-id=<id> (or CLOUDFLARE_ACCOUNT_ID):"
  cfResultRaw '.result[] | "  - \(.id)  \(.name)"' >&2
  exit "$EX_CONFIG"
}

# recordFqdn - Turn a relative record name into a fully qualified one for the current zone
#
# DNS names are case-insensitive (Cloudflare stores them lowercased), so the zone suffix is
# matched case-insensitively and the result is returned in lowercase.
#
# Arguments:
#   $1: name (www, @, www.example.com, *.example.com)
recordFqdn() {
  local name zone
  name="$(lower "${1%.}")"
  zone="$(lower "$CF_ZONE_NAME")"
  [[ -z "$name" || "$name" == "@" ]] && { printf '%s' "$zone"; return; }
  if [[ -z "$zone" || "$name" == "$zone" || "$name" == *".${zone}" ]]; then
    printf '%s' "$name"
  else
    printf '%s.%s' "$name" "$zone"
  fi
}

# zonePath - Prefix a path with /zones/<id> after resolving the zone
zonePath() {
  resolveZone
  printf '/zones/%s%s' "$CF_ZONE_ID" "${1:-}"
}

# accountPath - Prefix a path with /accounts/<id> after resolving the account
accountPath() {
  resolveAccount
  printf '/accounts/%s%s' "$CF_ACCOUNT_ID" "${1:-}"
}
