#!/usr/bin/env bash
# Octoflare module: help
#
# Help output and command discovery (text and JSON) built from the command
# registry that every module populates with registerCommand.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

# showBanner - Program banner
showBanner() {
  cat <<EOT
${PROGRAM_NAME} v${PROGRAM_VERSION} - Cloudflare automation for the CLI and CI workflows
${PROGRAM_URL}
EOT
}

# showGlobalOptions - Options accepted by every command
showGlobalOptions() {
  cat <<EOT
Global options
  --domain=<zone>            Zone (domain) to act on (or CLOUDFLARE_DOMAIN)
  --zone-id=<id>             Zone ID, skips the zone lookup (or CLOUDFLARE_ZONE_ID)
  --account-id=<id>          Account ID for account-level features (or CLOUDFLARE_ACCOUNT_ID)
  --api-token=<token>        API token (or CLOUDFLARE_API_TOKEN) - prefer the environment/secrets
  --api-email=<email> --api-key=<key>   Legacy global API key authentication
  -e <file>, --env-file=<file>  Load a .env file (interactive default: ./.octoflare, ~/.config/octoflare/.env;
                             unattended/CI runs only load a file given explicitly; --env=<file> still works
                             unless the command defines --env itself)
  --output=text|json         Output format (--json is a shortcut for --output=json)
  --field=<jq>               Print only this jq expression of the result (e.g. --field=.id)
  --pretty                   Pretty-print JSON output
  --dry-run                  Show the API requests without sending them
  --unattended, -y, --yes    Never prompt; install missing dependencies automatically
  --github-output=false      Do not write GitHub Actions step outputs
  -q, --quiet                Suppress informational logging
  --debug                    Verbose logging (requests, bodies)
  --update                   Update Octoflare and its modules
  --uninstall                Remove Octoflare
  -h, --help                 Show help (octoflare help <resource> for a resource)
  -V, --version              Show version

Environment variables
  CLOUDFLARE_API_TOKEN       API token (recommended). Aliases: CF_API_TOKEN
  CLOUDFLARE_EMAIL + CLOUDFLARE_API_KEY   Legacy global API key authentication
  CLOUDFLARE_ACCOUNT_ID      Account ID (auto-detected when the token sees one account)
  CLOUDFLARE_ZONE_ID         Zone ID (skips the zone lookup)
  CLOUDFLARE_DOMAIN          Default zone name
  CLOUDFLARE_ORIGIN_CA_KEY   Origin CA key for 'ssl origin-cert' commands
  CLOUDFLARE_RESTORE_LEVEL   Security level restored by 'attack-mode disable' (default: high)
  OCTOFLARE_UNATTENDED       true in CI/GitHub Actions (auto-detected): no prompts, auto-install
  OCTOFLARE_OUTPUT           text|json    OCTOFLARE_DRY_RUN  true|false
  OCTOFLARE_ENV_FILE         Path to an env file   OCTOFLARE_ENV_OVERRIDE  let the env file override the environment
  OCTOFLARE_TIMEOUT / OCTOFLARE_RETRIES / OCTOFLARE_RETRY_DELAY   HTTP tuning
EOT
}

# registryResources - Unique resources in registration order
registryResources() {
  printf '%s' "$COMMAND_REGISTRY" | awk -F'\t' 'NF && !seen[$1]++ {print $1}'
}

# registryDescription - Short description for a resource group
resourceDescription() {
  case "$1" in
    version|config|self) echo "Octoflare itself" ;;
    zone) echo "Zones" ;;
    dns) echo "DNS records" ;;
    setting) echo "Zone settings (generic get/set of any setting)" ;;
    cache) echo "Cache" ;;
    attack-mode|dev-mode|bot|access-rule|ua-rule|lockdown) echo "Security" ;;
    redirect|firewall|ratelimit|transform|cache-rule|config-rule|origin-rule|rule) echo "Rules (rulesets engine)" ;;
    pagerule) echo "Page Rules" ;;
    ssl|dnssec) echo "SSL/TLS & DNSSEC" ;;
    workers|kv) echo "Workers & KV" ;;
    pages) echo "Pages" ;;
    tunnel) echo "Cloudflare Tunnel (cloudflared)" ;;
    email) echo "Email Routing" ;;
    turnstile) echo "Turnstile" ;;
    r2) echo "R2 storage" ;;
    account|user|token|ip|list|bulk-redirect|web-analytics) echo "Account, user & lists" ;;
    analytics) echo "Analytics" ;;
    api|batch) echo "Raw API & batch runner" ;;
    *) echo "" ;;
  esac
}

# showHelp - Full help: banner, usage, global options and every command grouped by resource
showHelp() {
  showBanner
  cat <<EOT

Usage: ${PROGRAM_CODE} [global options] <resource> <action> [--option=value ...]
       ${PROGRAM_CODE} help <resource>
       ${PROGRAM_CODE} help --output=json      (machine readable command list)

Examples
  ${PROGRAM_CODE} dns upsert --domain=example.com --name=www --type=A --content=203.0.113.10 --proxied
  ${PROGRAM_CODE} redirect upsert --domain=example.com --from=/old-page --to=https://example.com/new-page --status=301
  ${PROGRAM_CODE} cache purge --domain=example.com --everything
  ${PROGRAM_CODE} attack-mode enable --domain=example.com
  ${PROGRAM_CODE} setting set --domain=example.com --name=ssl --value=strict

EOT
  showGlobalOptions
  printf '\nCommands\n'
  local resource
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    showResourceCommands "$resource"
  done < <(registryResources)
  cat <<EOT

Every list command supports --limit=<n>; every command supports --json / --field=<jq>.
Legacy flags still work: --enable-attack-mode, --disable-attack-mode, --status-attack-mode --domain=<zone>
EOT
}

# showResourceCommands - Print the command table for one resource
showResourceCommands() {
  local resource="$1"
  printf '\n  %s\n' "$resource"
  printf '%s' "$COMMAND_REGISTRY" | awk -F'\t' -v r="$resource" '$1==r {
    action=$2; usage=$3; desc=$4;
    line=sprintf("    %s %s %s", r, action, usage);
    if (length(line) > 62) { printf "%s\n%-64s%s\n", line, "", desc } else { printf "%-64s%s\n", line, desc }
  }'
}

# showResourceHelp - Help for one resource (or the full help when unknown/empty)
showResourceHelp() {
  local resource
  resource="$(resourceAlias "$(lower "${1:-}")")"
  if [[ -z "$resource" ]]; then
    showHelp
    return 0
  fi
  if ! printf '%s' "$COMMAND_REGISTRY" | awk -F'\t' -v r="$resource" '$1==r {found=1} END {exit !found}'; then
    logError "Unknown resource: ${1}"
    printf 'Available resources: %s\n' "$(registryResources | tr '\n' ' ')" >&2
    return "$EX_USAGE"
  fi
  showBanner
  printf '\nUsage: %s %s <action> [--option=value ...]\n' "$PROGRAM_CODE" "$resource"
  local desc
  desc="$(resourceDescription "$resource")"
  [[ -n "$desc" ]] && printf '%s\n' "$desc"
  showResourceCommands "$resource"
  printf '\nRun "%s --help" for the global options.\n' "$PROGRAM_CODE"
}

registerCommand help "[resource]" "" "Show help; --output=json lists every command as JSON"

cmd_help_list() {
  cmd_help_default
}

cmd_help_default() {
  local json
  if [[ "$OCTOFLARE_OUTPUT" == "json" || -n "$OCTOFLARE_FIELD" ]]; then
    json="$(printf '%s' "$COMMAND_REGISTRY" | jq -Rn '[inputs | select(length>0) | split("\t") | {resource:.[0], action:.[1], usage:.[2], description:.[3]}]')"
    emitResult "$json"
  else
    showResourceHelp "${ARGS[1]:-}"
  fi
}
