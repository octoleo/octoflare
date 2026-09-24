#!/usr/bin/env bash
# Octoflare module: core
#
# Logging, option parsing, environment loading, output formatting, GitHub
# Actions integration, prompts and the main command dispatcher.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

OCTOFLARE_LIB_VERSION="2.0.0"

#####################################################################################################################VDM
######################################## Exit codes

readonly EX_OK=0
readonly EX_FAILURE=1      # Cloudflare API returned an error
readonly EX_CONFIG=2       # Missing credentials / configuration
readonly EX_ARGS=3         # Missing or invalid command arguments
readonly EX_ZONE=4         # Zone could not be resolved
readonly EX_NOTFOUND=5     # Requested resource does not exist
readonly EX_USAGE=64       # Unknown command / bad usage
readonly EX_UNAVAILABLE=69 # Dependency missing
readonly EX_SOFTWARE=70    # Internal error / module failure

#####################################################################################################################VDM
######################################## Global state

OCTOFLARE_OUTPUT="${OCTOFLARE_OUTPUT:-text}"
OCTOFLARE_QUIET="${OCTOFLARE_QUIET:-false}"
OCTOFLARE_DEBUG="${OCTOFLARE_DEBUG:-false}"
OCTOFLARE_DRY_RUN="${OCTOFLARE_DRY_RUN:-false}"
OCTOFLARE_YES="${OCTOFLARE_YES:-false}"
OCTOFLARE_PRETTY="${OCTOFLARE_PRETTY:-false}"
OCTOFLARE_FIELD="${OCTOFLARE_FIELD:-}"
OCTOFLARE_GITHUB_OUTPUT="${OCTOFLARE_GITHUB_OUTPUT:-auto}"
OCTOFLARE_ENV_OVERRIDE="${OCTOFLARE_ENV_OVERRIDE:-false}"
OCTOFLARE_COLOR="${OCTOFLARE_COLOR:-auto}"

ARGS=()          # positional arguments
PARSED_OPTS=()   # every --option token seen (re-applied for batch runs)
OPT_NAMES=""     # space separated list of option names that were set
LAST_RESULT=""   # JSON of the last emitted result
ENV_FILE_LOADED=""

#####################################################################################################################VDM
######################################## Logging

# useColor - Whether to colourise log output
useColor() {
  case "$OCTOFLARE_COLOR" in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [[ -z "${NO_COLOR:-}" && -t 2 ]]
}

# _log - Internal logger (always stderr so stdout stays machine-readable)
#
# Arguments:
#   $1: level (info|success|warn|error|debug)
#   $2..: message
_log() {
  local level="$1"; shift
  local msg="$*" color="" reset=""
  case "$level" in
    info|success|debug) [[ "$OCTOFLARE_QUIET" == "true" ]] && return 0 ;;
  esac
  [[ "$level" == "debug" && "$OCTOFLARE_DEBUG" != "true" ]] && return 0
  if useColor; then
    reset=$'\033[0m'
    case "$level" in
      info) color=$'\033[36m' ;;
      success) color=$'\033[32m' ;;
      warn) color=$'\033[33m' ;;
      error) color=$'\033[31m' ;;
      debug) color=$'\033[90m' ;;
    esac
  fi
  printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$msg" >&2
  # GitHub workflow commands go to stderr too: the runner processes both streams and
  # stdout must stay clean for --json / --field consumers and $(...) captures.
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    case "$level" in
      error) printf '::error title=%s::%s\n' "$PROGRAM_NAME" "$msg" >&2 ;;
      warn) printf '::warning title=%s::%s\n' "$PROGRAM_NAME" "$msg" >&2 ;;
      debug) printf '::debug::%s\n' "$msg" >&2 ;;
    esac
  fi
}

logInfo() { _log info "$@"; }
logSuccess() { _log success "$@"; }
logWarn() { _log warn "$@"; }
logError() { _log error "$@"; }
logDebug() { _log debug "$@"; }

# die - Log an error and exit
#
# Arguments:
#   $1: message
#   $2: exit code (default 1)
die() {
  logError "$1"
  exit "${2:-$EX_FAILURE}"
}

# Legacy helpers kept for backwards compatibility with v1 scripts
_echo() { logInfo "$1"; }
showError() { die "$1" "${2:-1}"; }

#####################################################################################################################VDM
######################################## Option parsing

# optVarName - Convert an option name to its variable name (--zone-id -> OPT_zone_id)
optVarName() {
  local name="$1"
  name="${name#--}"
  name="${name//-/_}"
  name="${name//./_}"
  echo "OPT_${name}"
}

# setOpt - Store an option value
setOpt() {
  local var
  var="$(optVarName "$1")"
  [[ "$var" =~ ^OPT_[A-Za-z0-9_]+$ ]] || die "Invalid option name: --${1}" "$EX_ARGS"
  printf -v "$var" '%s' "$2"
  case " $OPT_NAMES " in
    *" $1 "*) ;;
    *) OPT_NAMES="${OPT_NAMES} $1" ;;
  esac
}

# opt - Read an option value with an optional default
#
# Arguments:
#   $1: option name (without --)
#   $2: default value
opt() {
  local var
  var="$(optVarName "$1")"
  if [[ -n "${!var+x}" ]]; then
    printf '%s' "${!var}"
  else
    printf '%s' "${2:-}"
  fi
}

# hasOpt - True when the option was provided
hasOpt() {
  local var
  var="$(optVarName "$1")"
  [[ -n "${!var+x}" ]]
}

# optBool - Read a boolean option (true/false) with default
optBool() {
  local v
  v="$(opt "$1" "${2:-false}")"
  normalizeBool "$v"
}

# normalizeBool - Map yes/on/1/true to "true", everything else to "false"
normalizeBool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on|enable|enabled) echo true ;;
    *) echo false ;;
  esac
}

# parseBool - Strict boolean: prints true or false, exits with EX_ARGS for anything else
#
# Use for on/off style values that change state, so that a typo never silently
# turns a feature off: v="$(parseBool "$value")" || exit $?
parseBool() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on|enable|enabled) echo true ;;
    0|false|no|n|off|disable|disabled) echo false ;;
    *) die "Invalid value \"${1:-}\" (expected on|off, true|false or yes|no)" "$EX_ARGS" ;;
  esac
}

# splitArgs - Tokenise a command line the way a shell would, WITHOUT evaluating anything
#
# Handles whitespace separation, 'single quotes', "double quotes" (with \" \\ \$ \` escapes)
# and backslash escapes outside quotes. $(...), backticks, variables and redirections stay
# literal text. The tokens are returned in the SPLIT_ARGS array (may be empty).
#
# Returns:
#   0 on success, 1 on an unterminated quote
splitArgs() {
  local line="$1" i ch nxt state=none token="" have=false len
  SPLIT_ARGS=()
  len=${#line}
  for ((i = 0; i < len; i++)); do
    ch="${line:i:1}"
    case "$state" in
      none)
        case "$ch" in
          ' '|$'\t'|$'\r'|$'\n')
            if [[ "$have" == "true" ]]; then SPLIT_ARGS+=("$token"); token=""; have=false; fi
            ;;
          "'") state=single; have=true ;;
          '"') state=double; have=true ;;
          "\\") i=$((i + 1)); token+="${line:i:1}"; have=true ;;
          *) token+="$ch"; have=true ;;
        esac
        ;;
      single)
        if [[ "$ch" == "'" ]]; then state=none; else token+="$ch"; fi
        ;;
      double)
        case "$ch" in
          '"') state=none ;;
          "\\")
            nxt="${line:i+1:1}"
            case "$nxt" in
              '"'|"\\"|'$'|'`') i=$((i + 1)); token+="$nxt" ;;
              *) token+="$ch" ;;
            esac
            ;;
          *) token+="$ch" ;;
        esac
        ;;
    esac
  done
  [[ "$state" != "none" ]] && return 1
  [[ "$have" == "true" ]] && SPLIT_ARGS+=("$token")
  return 0
}

# optFirst - Return the first option that is set from a list, or the default
#
# Arguments:
#   $1: default
#   $2..: option names
optFirst() {
  local default="$1"; shift
  local name
  for name in "$@"; do
    if hasOpt "$name"; then
      opt "$name"
      return 0
    fi
  done
  printf '%s' "$default"
}

# optOrEnv - Option value, falling back to an environment variable, then default
#
# Arguments:
#   $1: option name
#   $2: env var name
#   $3: default
optOrEnv() {
  if hasOpt "$1"; then
    opt "$1"
  else
    printf '%s' "${!2:-${3:-}}"
  fi
}

# requireOpt - Ensure options are present, exit with usage error otherwise
requireOpt() {
  local name value
  for name in "$@"; do
    value="$(opt "$name")"
    if [[ -z "$value" ]]; then
      die "Missing required option --${name}=<value>" "$EX_ARGS"
    fi
  done
}

# requireOneOf - Ensure at least one of the options is present
requireOneOf() {
  local name
  for name in "$@"; do
    [[ -n "$(opt "$name")" ]] && return 0
  done
  die "One of the following options is required: $(printf -- '--%s ' "$@")" "$EX_ARGS"
}

# resetOpts - Clear every parsed option and positional argument
resetOpts() {
  local name var
  for name in $OPT_NAMES; do
    var="$(optVarName "$name")"
    unset "$var"
  done
  OPT_NAMES=""
  ARGS=()
  PARSED_OPTS=()
}

# parseArgs - Parse the command line into ARGS (positional) and OPT_* (options)
#
# Supported forms:
#   --key=value      option with value
#   --key            boolean option (true)
#   --no-key         boolean option (false)
#   -e FILE|--env FILE  env file (legacy form with a separate argument)
#   --               end of options, everything after is positional
parseArgs() {
  local arg key value
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --)
        shift
        while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done
        break
        ;;
      # legacy v1 flags mapped to v2 commands
      --enable-attack-mode) ARGS=("attack-mode" "enable" ${ARGS[@]+"${ARGS[@]}"}) ;;
      --disable-attack-mode) ARGS=("attack-mode" "disable" ${ARGS[@]+"${ARGS[@]}"}) ;;
      --status-attack-mode) ARGS=("attack-mode" "status" ${ARGS[@]+"${ARGS[@]}"}) ;;
      --update) ARGS=("self" "update" ${ARGS[@]+"${ARGS[@]}"}) ;;
      --uninstall) ARGS=("self" "uninstall" ${ARGS[@]+"${ARGS[@]}"}) ;;
      --version|-V) ARGS=("version" ${ARGS[@]+"${ARGS[@]}"}) ;;
      -h|--help) setOpt help true; PARSED_OPTS+=("--help") ;;
      -q|--quiet) setOpt quiet true; PARSED_OPTS+=("--quiet") ;;
      -y|--yes) setOpt yes true; PARSED_OPTS+=("--yes") ;;
      -e|--env)
        if [[ -n "${2:-}" ]]; then
          setOpt env "$2"; PARSED_OPTS+=("--env=$2"); shift
        else
          die '"--env" requires a non-empty option argument.' "$EX_ARGS"
        fi
        ;;
      -e=*) setOpt env "${arg#*=}"; PARSED_OPTS+=("--env=${arg#*=}") ;;
      --json) setOpt output json; PARSED_OPTS+=("--output=json") ;;
      --no-*)
        key="${arg#--no-}"
        setOpt "$key" false; PARSED_OPTS+=("$arg")
        ;;
      --*=*)
        key="${arg#--}"; key="${key%%=*}"
        value="${arg#*=}"
        setOpt "$key" "$value"; PARSED_OPTS+=("$arg")
        ;;
      --*)
        key="${arg#--}"
        setOpt "$key" true; PARSED_OPTS+=("$arg")
        ;;
      *) ARGS+=("$arg") ;;
    esac
    shift
  done
}

# applyGlobalOpts - Copy well-known options into the OCTOFLARE_* globals
applyGlobalOpts() {
  [[ "$(optBool quiet "$OCTOFLARE_QUIET")" == "true" ]] && OCTOFLARE_QUIET=true
  [[ "$(optBool debug "$OCTOFLARE_DEBUG")" == "true" ]] && OCTOFLARE_DEBUG=true
  [[ "$(optBool dry_run "$OCTOFLARE_DRY_RUN")" == "true" ]] && OCTOFLARE_DRY_RUN=true
  [[ "$(optBool yes "$OCTOFLARE_YES")" == "true" ]] && OCTOFLARE_YES=true
  [[ "$(optBool pretty "$OCTOFLARE_PRETTY")" == "true" ]] && OCTOFLARE_PRETTY=true
  [[ "$(optBool unattended "$OCTOFLARE_UNATTENDED")" == "true" ]] && OCTOFLARE_UNATTENDED=true
  OCTOFLARE_OUTPUT="$(opt output "$OCTOFLARE_OUTPUT")"
  OCTOFLARE_FIELD="$(opt field "$OCTOFLARE_FIELD")"
  hasOpt github-output && OCTOFLARE_GITHUB_OUTPUT="$(optBool github-output)"
  hasOpt color && OCTOFLARE_COLOR="$(opt color)"
  case "$OCTOFLARE_OUTPUT" in
    text|json) ;;
    *) die "Invalid --output=${OCTOFLARE_OUTPUT} (expected text or json)" "$EX_ARGS" ;;
  esac
  export OCTOFLARE_QUIET OCTOFLARE_DEBUG OCTOFLARE_DRY_RUN OCTOFLARE_YES OCTOFLARE_UNATTENDED OCTOFLARE_OUTPUT
  return 0
}

#####################################################################################################################VDM
######################################## Environment files

# loadEnvLine - Apply one KEY=VALUE line from an env file
#
# Existing (exported) environment variables win over the file unless
# OCTOFLARE_ENV_OVERRIDE=true, so CI secrets are never clobbered by a checked-in file.
loadEnvLine() {
  local line="$1" key value
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  [[ -z "$line" || "$line" == \#* ]] && return 0
  line="${line#export }"
  [[ "$line" != *=* ]] && return 0
  key="${line%%=*}"
  value="${line#*=}"
  key="${key%"${key##*[![:space:]]}"}"        # rtrim key
  [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && return 0
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%$'\r'}"
  # quoted values: take the text up to the matching closing quote, ignore what follows (comments)
  if [[ "$value" == \"* ]]; then
    value="${value#\"}"
    value="$(envUnquote "$value" '"')"
    value="${value//\\\"/\"}"
  elif [[ "$value" == \'* ]]; then
    value="${value#\'}"
    value="$(envUnquote "$value" "'")"
  else
    # drop trailing inline comment for unquoted values
    value="${value%%[[:space:]]#*}"
    value="${value%"${value##*[![:space:]]}"}"
  fi
  # only variables that were really present in the process environment win over the file
  if [[ "$OCTOFLARE_ENV_OVERRIDE" == "true" ]] || ! envWasSet "$key"; then
    export "$key=$value"
  fi
}

# envUnquote - Text of a quoted value up to its closing quote (backslash escapes kept)
envUnquote() {
  local rest="$1" q="$2" out="" ch i len
  len=${#rest}
  for ((i = 0; i < len; i++)); do
    ch="${rest:i:1}"
    if [[ "$ch" == "\\" && "$q" == '"' ]]; then
      out+="$ch${rest:i+1:1}"
      i=$((i + 1))
      continue
    fi
    [[ "$ch" == "$q" ]] && break
    out+="$ch"
  done
  printf '%s' "$out"
}

# envWasSet - True when the variable was present in the environment when Octoflare started
envWasSet() {
  if [[ -n "${OCTOFLARE_ORIG_ENV:-}" ]]; then
    case "$OCTOFLARE_ORIG_ENV" in
      *" $1 "*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  [[ -n "${!1+x}" ]]
}

# loadEnvFile - Load variables from --env / OCTOFLARE_ENV_FILE, or (interactively) ./.octoflare,
# ./.env.octoflare and ~/.config/octoflare/.env
#
# In unattended runs (CI, GitHub Actions) only an explicitly requested file is loaded: a
# checked-in ./.octoflare from an untrusted contributor must never be able to redirect
# requests or change zones silently.
loadEnvFile() {
  local explicit path
  explicit="$(optFirst "${OCTOFLARE_ENV_FILE:-}" env env-file)"
  if [[ -n "$explicit" ]]; then
    [[ -f "$explicit" ]] || die "Environment file not found: ${explicit}" "$EX_CONFIG"
    path="$explicit"
  elif [[ "$OCTOFLARE_UNATTENDED" == "true" ]]; then
    return 0
  else
    for path in "./.${PROGRAM_CODE}" "./.env.${PROGRAM_CODE}" "${HOME:-/nonexistent}/.config/${PROGRAM_CODE}/.env"; do
      [[ -f "$path" ]] && break
      path=""
    done
  fi
  [[ -z "$path" ]] && return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    loadEnvLine "$line"
  done <"$path"
  ENV_FILE_LOADED="$path"
  logDebug "Loaded environment file: ${path}"
  # the file may have changed OCTOFLARE_* switches: re-apply (command line options still win)
  applyGlobalOpts
}

# applyCredentialOpts - Copy credential options/aliases into the canonical CLOUDFLARE_* variables
applyCredentialOpts() {
  hasOpt api-token && CLOUDFLARE_API_TOKEN="$(opt api-token)"
  hasOpt token && CLOUDFLARE_API_TOKEN="$(opt token)"
  hasOpt api-key && CLOUDFLARE_API_KEY="$(opt api-key)"
  hasOpt api-email && CLOUDFLARE_EMAIL="$(opt api-email)"
  hasOpt account-id && CLOUDFLARE_ACCOUNT_ID="$(opt account-id)"
  hasOpt zone-id && CLOUDFLARE_ZONE_ID="$(opt zone-id)"
  hasOpt origin-ca-key && CLOUDFLARE_ORIGIN_CA_KEY="$(opt origin-ca-key)"
  hasOpt api-base && CLOUDFLARE_API_BASE="$(opt api-base)"
  hasOpt domain && CLOUDFLARE_DOMAIN="$(opt domain)"
  hasOpt zone && CLOUDFLARE_DOMAIN="$(opt zone)"
  # wrangler / legacy variable aliases
  : "${CLOUDFLARE_API_TOKEN:=${CF_API_TOKEN:-}}"
  : "${CLOUDFLARE_API_KEY:=${CF_API_KEY:-}}"
  : "${CLOUDFLARE_EMAIL:=${CF_API_EMAIL:-${CF_EMAIL:-}}}"
  : "${CLOUDFLARE_ACCOUNT_ID:=${CF_ACCOUNT_ID:-}}"
  : "${CLOUDFLARE_ZONE_ID:=${CF_ZONE_ID:-}}"
  : "${CLOUDFLARE_DOMAIN:=${CF_DOMAIN:-${CLOUDFLARE_ZONE:-}}}"
  : "${CLOUDFLARE_ORIGIN_CA_KEY:=${CF_ORIGIN_CA_KEY:-}}"
  : "${CLOUDFLARE_API_BASE:=https://api.cloudflare.com/client/v4}"
  CLOUDFLARE_API_BASE="${CLOUDFLARE_API_BASE%/}"
  case "$CLOUDFLARE_API_BASE" in
    https://*|http://127.0.0.1:*|http://127.0.0.1/*|http://localhost:*|http://localhost/*) ;;
    *) die "CLOUDFLARE_API_BASE must use https:// (got ${CLOUDFLARE_API_BASE})" "$EX_CONFIG" ;;
  esac
  # export only what is set, so env files loaded later (e.g. per batch line) can still fill the gaps
  local var
  for var in CLOUDFLARE_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ZONE_ID CLOUDFLARE_DOMAIN CLOUDFLARE_ORIGIN_CA_KEY; do
    if [[ -n "${!var}" ]]; then export "${var?}"; else unset "${var?}"; fi
  done
  export CLOUDFLARE_API_BASE
  ghMask "${CLOUDFLARE_API_TOKEN:-}"
  ghMask "${CLOUDFLARE_API_KEY:-}"
  ghMask "${CLOUDFLARE_ORIGIN_CA_KEY:-}"
  return 0
}

# requireAuth - Ensure we have credentials for the Cloudflare API
requireAuth() {
  [[ "${CF_AUTH_MODE:-token}" == "origin-ca" && -n "${CLOUDFLARE_ORIGIN_CA_KEY:-}" ]] && return 0
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && [[ -z "${CLOUDFLARE_API_KEY:-}" || -z "${CLOUDFLARE_EMAIL:-}" ]]; then
    die "CLOUDFLARE_API_TOKEN must be set (via --api-token, the environment, or an env file). Alternatively set CLOUDFLARE_EMAIL and CLOUDFLARE_API_KEY." "$EX_CONFIG"
  fi
}

#####################################################################################################################VDM
######################################## GitHub Actions integration

# ghEnabled - Whether GitHub output files should be written
ghEnabled() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 1
  case "$OCTOFLARE_GITHUB_OUTPUT" in
    false) return 1 ;;
    *) return 0 ;;
  esac
}

# ghOutput - Write a step output (supports multi-line values)
#
# Arguments:
#   $1: name
#   $2: value
ghOutput() {
  ghEnabled || return 0
  local name="$1" value="$2" delim
  if [[ "$value" == *$'\n'* ]]; then
    delim="OCTOFLARE_EOF_$$_${RANDOM}"
    printf '%s<<%s\n%s\n%s\n' "$name" "$delim" "$value" "$delim" >>"$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
  fi
}

GH_MASKED=""

# ghMask - Mask a secret in GitHub Actions logs (once per value)
ghMask() {
  [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${1:-}" ]] || return 0
  case "$GH_MASKED" in
    *"|${1}|"*) return 0 ;;
  esac
  GH_MASKED="${GH_MASKED}|${1}|"
  printf '::add-mask::%s\n' "$1" >&2
}

# ghSummary - Append markdown to the GitHub step summary when available
ghSummary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
}

#####################################################################################################################VDM
######################################## Output

# jsonCompact - Print JSON on a single line
jsonCompact() {
  jq -c '.' 2>/dev/null || cat
}

# emitResult - Print a command result honouring --output, --field and --pretty
#
# Arguments:
#   $1: JSON result
#   $2: jq template for text output (optional; raw strings, one per line)
#   $3: text shown when the result is empty (optional)
emitResult() {
  local json="$1" template="${2:-}" empty_text="${3:-}" out
  [[ -z "$json" ]] && json="null"
  LAST_RESULT="$json"
  if [[ -n "$OCTOFLARE_FIELD" ]]; then
    out="$(printf '%s' "$json" | jq -r "$OCTOFLARE_FIELD")" || die "Invalid --field expression: ${OCTOFLARE_FIELD}" "$EX_ARGS"
    printf '%s\n' "$out"
    emitGitHubOutputs "$json" "$out"
    return 0
  elif [[ "$OCTOFLARE_OUTPUT" == "json" ]]; then
    if [[ "$OCTOFLARE_PRETTY" == "true" ]]; then
      printf '%s' "$json" | jq '.'
    else
      printf '%s' "$json" | jq -c '.'
    fi
  else
    if [[ -n "$template" ]]; then
      out="$(printf '%s' "$json" | jq -r "$template" 2>/dev/null)" || out="$(printf '%s' "$json" | jq '.')"
      if [[ -z "$out" && -n "$empty_text" ]]; then
        logInfo "$empty_text"
      else
        printf '%s\n' "$out"
      fi
    else
      printf '%s' "$json" | jq '.'
    fi
  fi
  emitGitHubOutputs "$json"
}

# emitGitHubOutputs - Write the standard outputs (result, id, zone_id, ...) for workflows
#
# Arguments:
#   $1: JSON result
#   $2: value to publish as "result" instead of the JSON (the --field value)
emitGitHubOutputs() {
  ghEnabled || return 0
  local json="$1" id
  if [[ $# -ge 2 ]]; then
    ghOutput result "$2"
  else
    ghOutput result "$(printf '%s' "$json" | jq -c '.')"
  fi
  id="$(printf '%s' "$json" | jq -r 'if type=="object" then (.id // .result.id // empty) else empty end' 2>/dev/null)"
  [[ -n "$id" ]] && ghOutput id "$id"
  [[ -n "${CF_ZONE_ID:-}" ]] && ghOutput zone_id "$CF_ZONE_ID"
  [[ -n "${CF_ZONE_NAME:-}" ]] && ghOutput zone_name "$CF_ZONE_NAME"
  [[ -n "${CF_ACCOUNT_ID:-}" ]] && ghOutput account_id "$CF_ACCOUNT_ID"
  return 0
}

# emitMessage - Emit a simple {"success":true,"message":...} result
emitMessage() {
  local msg="$1" extra="${2:-{\}}"
  local json
  json="$(jq -cn --arg m "$msg" --argjson extra "$extra" '{success:true, message:$m} + $extra')"
  if [[ "$OCTOFLARE_OUTPUT" == "json" || -n "$OCTOFLARE_FIELD" ]]; then
    emitResult "$json"
  else
    logSuccess "$msg"
    LAST_RESULT="$json"
    emitGitHubOutputs "$json"
  fi
}

#####################################################################################################################VDM
######################################## Prompts & helpers

# confirm - Ask a yes/no question; unattended and --yes runs answer yes
confirm() {
  local answer
  [[ "$OCTOFLARE_YES" == "true" || "$OCTOFLARE_UNATTENDED" == "true" ]] && return 0
  if [[ ! -t 0 ]]; then
    die "Confirmation required for: $1 (re-run with --yes or --unattended)" "$EX_ARGS"
  fi
  printf '[prompt] %s [y/N] ' "$1" >&2
  read -r answer
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# toJsonArray - Convert a comma (or newline) separated string to a JSON array of strings
toJsonArray() {
  local input="$1"
  [[ -z "$input" ]] && { echo '[]'; return 0; }
  printf '%s' "$input" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R . | jq -cs .
}

# toJsonValue - Convert a CLI string to a typed JSON value (number, bool, null, object/array or string)
toJsonValue() {
  local v="$1"
  if printf '%s' "$v" | jq . >/dev/null 2>&1; then
    case "$v" in
      \{*|\[*|true|false|null) printf '%s' "$v"; return 0 ;;
      *) if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$v"; return 0; fi ;;
    esac
  fi
  jq -cn --arg v "$v" '$v'
}

# readFileOrValue - Return the contents of @file, - (stdin) or the value itself
readFileOrValue() {
  local v="$1"
  case "$v" in
    @*) cat "${v#@}" ;;
    -) cat ;;
    *) printf '%s' "$v" ;;
  esac
}

# inputFromOpts - Content from --file=<path> (always read as a file) or from the first
# given value option (which accepts a literal, @file or - for stdin)
#
# Arguments:
#   $@: value option names
inputFromOpts() {
  local f name
  if hasOpt file; then
    f="$(opt file)"
    if [[ "$f" == "-" ]]; then
      cat
    else
      [[ -f "$f" ]] || die "File not found: ${f}" "$EX_ARGS"
      cat "$f"
    fi
    return 0
  fi
  for name in "$@"; do
    if hasOpt "$name"; then
      readFileOrValue "$(opt "$name")"
      return 0
    fi
  done
  return 0
}

# isFqdn - Basic sanity check for a hostname
isFqdn() {
  [[ "$1" =~ ^([A-Za-z0-9_](-*[A-Za-z0-9_])*\.)+[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.?$ || "$1" =~ ^\*\. ]]
}

# lower - Lowercase a string (bash 3 compatible)
lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# nowIso - Current time in ISO 8601 (UTC)
nowIso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

#####################################################################################################################VDM
######################################## Command registry

COMMAND_REGISTRY=""

# registerCommand - Register a command for help output and discovery
#
# Arguments:
#   $1: resource (e.g. dns)
#   $2: action (e.g. upsert)
#   $3: usage (options)
#   $4: description
registerCommand() {
  COMMAND_REGISTRY="${COMMAND_REGISTRY}${1}"$'\t'"${2}"$'\t'"${3}"$'\t'"${4}"$'\n'
}

# resourceAlias - Map aliases (plural forms, legacy names) to canonical resources
resourceAlias() {
  case "$1" in
    zones) echo zone ;;
    record|records|dns-record|dns-records) echo dns ;;
    settings|zone-setting|zone-settings) echo setting ;;
    caches) echo cache ;;
    attack|iuam|under-attack|under-attack-mode) echo attack-mode ;;
    development-mode|devmode) echo dev-mode ;;
    access-rules|ip-access|ip-access-rule|ip-rule) echo access-rule ;;
    ua-rules|user-agent|user-agent-rule) echo ua-rule ;;
    lockdowns|zone-lockdown) echo lockdown ;;
    bot-management|bots|bot-fight) echo bot ;;
    redirects|single-redirect) echo redirect ;;
    firewall-rule|firewall-rules|waf|custom-rule|custom-rules) echo firewall ;;
    rate-limit|ratelimits|rate-limits) echo ratelimit ;;
    transforms|transform-rule|rewrite) echo transform ;;
    cache-rules) echo cache-rule ;;
    config-rules|configuration-rule|configuration-rules) echo config-rule ;;
    origin-rules) echo origin-rule ;;
    ruleset|rulesets|rules) echo rule ;;
    pagerules|page-rule|page-rules) echo pagerule ;;
    tls|certificate|certificates) echo ssl ;;
    worker|scripts|script) echo workers ;;
    kv-namespace|namespaces) echo kv ;;
    page|pages-project) echo pages ;;
    tunnels|cloudflared) echo tunnel ;;
    email-routing|mail) echo email ;;
    widget|widgets) echo turnstile ;;
    bucket|buckets) echo r2 ;;
    accounts) echo account ;;
    lists|ip-list) echo list ;;
    bulk-redirects) echo bulk-redirect ;;
    rum|web-analytic) echo web-analytics ;;
    stats) echo analytics ;;
    ips) echo ip ;;
    tokens) echo token ;;
    commands) echo help ;;
    *) echo "$1" ;;
  esac
}

# commandFunction - Build the function name for a resource/action pair (dns upsert -> cmd_dns_upsert)
commandFunction() {
  local r="${1//-/_}" a="${2//-/_}"
  echo "cmd_${r}_${a}"
}

#####################################################################################################################VDM
######################################## Dispatcher

# runCommand - Parse arguments and execute a single command (used by main and batch)
#
# Arguments:
#   $@: full command line (options and positionals)
#
# Returns:
#   The command's exit code
runCommand() {
  local resource action fn
  resetOpts
  parseArgs "$@"
  applyGlobalOpts
  loadEnvFile
  applyCredentialOpts

  resource="$(resourceAlias "$(lower "${ARGS[0]:-}")")"
  action="$(lower "${ARGS[1]:-}")"

  if [[ "$(optBool help)" == "true" || -z "$resource" ]]; then
    if [[ -n "$resource" && "$resource" != "help" ]]; then
      showResourceHelp "$resource"
      return $?
    elif [[ "$(optBool debug)" == "true" && -z "$resource" ]]; then
      cmd_config_show
    else
      showHelp
    fi
    return 0
  fi

  case "$resource" in
    help) cmd_help_default; return $? ;;
    version) cmd_version; return 0 ;;
  esac

  [[ -z "$action" ]] && action="$(defaultAction "$resource")"
  fn="$(commandFunction "$resource" "$action")"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    if declare -F "cmd_${resource//-/_}_default" >/dev/null 2>&1 && [[ -n "$action" ]]; then
      # allow "resource <arg>" style where the resource has a default handler
      ARGS=("$resource" "default" "${ARGS[@]:1}")
      fn="cmd_${resource//-/_}_default"
    elif printf '%s' "$COMMAND_REGISTRY" | awk -F'\t' -v r="$resource" '$1==r {found=1} END {exit !found}'; then
      logError "Unknown action \"${action}\" for ${resource}"
      showResourceHelp "$resource" >&2
      return "$EX_USAGE"
    else
      showResourceHelp "$resource" >&2
      return "$EX_USAGE"
    fi
  fi
  logDebug "Running ${fn} (dry-run=${OCTOFLARE_DRY_RUN}, output=${OCTOFLARE_OUTPUT})"
  "$fn"
}

# defaultAction - The action used when a resource is called without one
defaultAction() {
  case "$1" in
    attack-mode|dev-mode|bot|ssl|dnssec|email|tunnel-status|self) echo status ;;
    token) echo verify ;;
    config) echo show ;;
    api) echo request ;;
    batch) echo run ;;
    ip) echo list ;;
    analytics) echo zone ;;
    *) echo list ;;
  esac
}

OCTOFLARE_TMPDIR=""
EXIT_CODE_WRITTEN=false

# octoflareTmpDir - Create the private per-run temporary directory (OCTOFLARE_TMPDIR) once.
# Call it directly (never inside $(...)) and use "$OCTOFLARE_TMPDIR" afterwards; it is removed
# by the EXIT trap.
octoflareTmpDir() {
  [[ -n "$OCTOFLARE_TMPDIR" && -d "$OCTOFLARE_TMPDIR" ]] && return 0
  OCTOFLARE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/octoflare.XXXXXX")" || die "Could not create a temporary directory" "$EX_SOFTWARE"
  chmod 700 "$OCTOFLARE_TMPDIR"
  export OCTOFLARE_TMPDIR
}

# octoflareExit - EXIT trap: publish the exit code to GitHub Actions and clean up
octoflareExit() {
  local code=$?
  if [[ "$EXIT_CODE_WRITTEN" != "true" ]] && ghEnabled; then
    ghOutput exit_code "$code"
    EXIT_CODE_WRITTEN=true
  fi
  [[ -n "$OCTOFLARE_TMPDIR" && -d "$OCTOFLARE_TMPDIR" ]] && rm -rf "$OCTOFLARE_TMPDIR"
  return 0
}

# octoflareMain - Entry point called by the bootstrap
octoflareMain() {
  local code
  trap octoflareExit EXIT
  octoflareTmpDir
  runCommand "$@"
  code=$?
  exit "$code"
}

#####################################################################################################################VDM
######################################## Built-in commands: version, config, self

registerCommand version "" "" "Show the Octoflare version"
registerCommand config show "" "Show the effective configuration (credentials are masked)"
registerCommand self update "" "Update Octoflare (script and modules) to the latest version"
registerCommand self uninstall "" "Remove Octoflare from this machine"
registerCommand self install-deps "" "Install missing dependencies (curl, jq, openssl)"
registerCommand self path "" "Show where Octoflare and its modules are installed"

cmd_version() {
  local json
  json="$(jq -cn --arg v "$PROGRAM_VERSION" --arg lib "$OCTOFLARE_LIB_VERSION" --arg ref "$OCTOFLARE_REF" '{name:"Octoflare", version:$v, lib_version:$lib, ref:$ref}')"
  emitResult "$json" '"\(.name) v\(.version)"'
}

# maskSecret - Show only the last 4 characters of a secret
maskSecret() {
  local v="$1"
  [[ -z "$v" ]] && { echo "(unset)"; return; }
  if [[ ${#v} -le 8 ]]; then echo "****"; else echo "****${v:${#v}-4}"; fi
}

cmd_config_show() {
  local json
  json="$(jq -cn \
    --arg token "$(maskSecret "${CLOUDFLARE_API_TOKEN:-}")" \
    --arg key "$(maskSecret "${CLOUDFLARE_API_KEY:-}")" \
    --arg email "${CLOUDFLARE_EMAIL:-}" \
    --arg account "${CLOUDFLARE_ACCOUNT_ID:-}" \
    --arg zone_id "${CLOUDFLARE_ZONE_ID:-}" \
    --arg domain "${CLOUDFLARE_DOMAIN:-}" \
    --arg restore "${CLOUDFLARE_RESTORE_LEVEL:-high}" \
    --arg base "${CLOUDFLARE_API_BASE:-}" \
    --arg env "${ENV_FILE_LOADED:-}" \
    --arg lib "${OCTOFLARE_LIB_DIR:-bundled}" \
    --arg output "$OCTOFLARE_OUTPUT" \
    --arg unattended "$OCTOFLARE_UNATTENDED" \
    --arg dry "$OCTOFLARE_DRY_RUN" \
    --arg ref "$OCTOFLARE_REF" \
    --arg version "$PROGRAM_VERSION" \
    '{version:$version, api_token:$token, api_key:$key, email:$email, account_id:$account, zone_id:$zone_id, domain:$domain, restore_level:$restore, api_base:$base, env_file:$env, lib_dir:$lib, output:$output, unattended:($unattended=="true"), dry_run:($dry=="true"), ref:$ref}')"
  emitResult "$json" 'to_entries[] | "\(.key)=\(.value)"'
}

cmd_self_path() {
  local json
  json="$(jq -cn --arg script "${BASH_SOURCE[1]:-$0}" --arg lib "${OCTOFLARE_LIB_DIR:-bundled}" --arg home "$(octoflareHome)" '{script:$script, lib_dir:$lib, home:$home}')"
  emitResult "$json" 'to_entries[] | "\(.key)=\(.value)"'
}

cmd_self_install_deps() {
  ensureDependency curl curl
  ensureDependency jq jq
  if ! hasCmd openssl; then
    OCTOFLARE_YES=true ensureDependency openssl openssl || true
  fi
  emitMessage "All dependencies are installed."
}

# installedScriptPath - Location of the running script (for update / uninstall)
installedScriptPath() {
  local src="$0"
  if [[ "$src" != /* ]]; then
    src="$(command -v "$src" 2>/dev/null || echo "$src")"
  fi
  echo "$src"
}

cmd_self_update() {
  local script dir tmp url name lib_dir
  script="$(installedScriptPath)"
  dir="$(dirname "$script")"
  url="${OCTOFLARE_RAW_BASE}/${OCTOFLARE_REF}/src/${PROGRAM_CODE}"
  tmp="$(mktemp)"
  logInfo "Downloading ${PROGRAM_NAME} (${OCTOFLARE_REF}) from ${url}..."
  download "$url" "$tmp" || die "Update failed: could not download ${url}" "$EX_FAILURE"
  if [[ -w "$script" || ( ! -e "$script" && -w "$dir" ) ]]; then
    cp "$tmp" "$script" && chmod +x "$script"
  else
    sudoCmd cp "$tmp" "$script" && sudoCmd chmod +x "$script"
  fi || die "Update failed: could not write ${script}" "$EX_FAILURE"
  rm -f "$tmp"
  lib_dir="${OCTOFLARE_LIB_DIR:-$(octoflareHome)/lib}"
  if [[ "${OCTOFLARE_BUNDLED:-false}" != "true" ]]; then
    logInfo "Updating modules in ${lib_dir}..."
    for name in $OCTOFLARE_MODULES; do
      fetchModule "$name" "$lib_dir" || die "Update failed: could not download module ${name}" "$EX_FAILURE"
    done
  fi
  emitMessage "${PROGRAM_NAME} updated to the latest ${OCTOFLARE_REF} version at ${script}."
}

cmd_self_uninstall() {
  local script lib_dir home
  script="$(installedScriptPath)"
  lib_dir="${OCTOFLARE_LIB_DIR:-}"
  home="$(octoflareHome)"
  confirm "Remove ${script}, ${lib_dir:-no modules} and ${home}?" || die "Uninstall cancelled." "$EX_OK"
  if [[ -f "$script" ]]; then
    rm -f "$script" 2>/dev/null || sudoCmd rm -f "$script"
  fi
  if [[ -n "$lib_dir" && -d "$lib_dir" && "$lib_dir" != "/" ]]; then
    rm -rf "$lib_dir" 2>/dev/null || sudoCmd rm -rf "$lib_dir"
  fi
  [[ -d "$home" ]] && rm -rf "$home"
  emitMessage "${PROGRAM_NAME} v${PROGRAM_VERSION} uninstalled."
}
