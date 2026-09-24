#!/usr/bin/env bash
# Octoflare module: batch
#
# Raw API passthrough and the batch runner that executes many Octoflare
# commands from a file, stdin or a --commands string (one per line).
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand api request "<METHOD> <path> [--data=<json|@file>] [--query=a=b&c=d] [--paginate]" "Call any Cloudflare API endpoint (e.g. api GET /zones)"
registerCommand batch run "(--file=<commands.txt> | --stdin | --commands=<multi-line>) [--continue-on-error]" "Run many commands (one per line, # comments allowed; lines are tokenised, never evaluated)"
registerCommand exec line "--line=<command line>" "Run one command line given as a single string (tokenised safely, never evaluated); used by the GitHub Action"

cmd_api_request() {
  requireAuth
  local method path data query
  method="$(optFirst "${ARGS[2]:-GET}" method)"
  path="$(optFirst "${ARGS[3]:-}" path url endpoint)"
  # allow "api /zones" (method defaults to GET)
  if [[ "$method" == /* ]]; then
    path="$method"
    method="GET"
  fi
  method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
  [[ -z "$path" ]] && die "Usage: octoflare api <METHOD> <path> [--data=<json>]" "$EX_ARGS"
  # resolve placeholders in the main shell so a failed lookup stops the command
  if [[ "$path" == *"{zone_id}"* ]]; then
    resolveZone
    path="${path//\{zone_id\}/$CF_ZONE_ID}"
  fi
  if [[ "$path" == *"{account_id}"* ]]; then
    resolveAccount
    path="${path//\{account_id\}/$CF_ACCOUNT_ID}"
  fi
  query="$(opt query)"
  [[ -n "$query" ]] && path="$(cfPath "$path" "$query")"
  data="$(readFileOrValue "$(optFirst "" data body)")"
  if [[ "$(optBool paginate)" == "true" && "$method" == "GET" ]]; then
    cfApiList "$path"
  else
    cfApi "$method" "$path" "$data"
  fi
  if printf '%s' "$CF_RESPONSE" | jq -e . >/dev/null 2>&1; then
    emitResult "$(cfResult '.result // .')"
  else
    printf '%s\n' "$CF_RESPONSE"
  fi
}

# cmd_api_default - Allows "octoflare api GET /zones" without the "request" action
cmd_api_default() { cmd_api_request; }

cmd_batch_run() {
  local source_desc lines line results='[]' failed=0 total=0 code output global_opts=() item args
  # options of the batch command itself are re-applied to every line (except batch-specific ones)
  for item in ${PARSED_OPTS[@]+"${PARSED_OPTS[@]}"}; do
    case "$item" in
      --file=*|--stdin|--commands=*|--continue-on-error*|--output=*|--json|--field=*|--line=*) ;;
      *) global_opts+=("$item") ;;
    esac
  done
  if hasOpt commands; then
    lines="$(opt commands)"
    source_desc="--commands"
  elif [[ "$(optBool stdin)" == "true" || "$(opt file)" == "-" ]]; then
    lines="$(cat)"
    source_desc="stdin"
  elif hasOpt file; then
    [[ -f "$(opt file)" ]] || die "Batch file not found: $(opt file)" "$EX_ARGS"
    lines="$(cat "$(opt file)")"
    source_desc="$(opt file)"
  else
    die "Provide the commands with --file=<path>, --stdin or --commands=<multi-line string>" "$EX_ARGS"
  fi
  logInfo "Running batch from ${source_desc}..."
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#octoflare }"
    total=$((total + 1))
    # tokenise like a shell but never evaluate: $(...), backticks and redirections stay literal
    if ! splitArgs "$line"; then
      logError "[batch ${total}] could not parse line (unterminated quote): ${line}"
      failed=$((failed + 1))
      results="$(jq -cn --argjson r "$results" --arg c "$line" '$r + [{command:$c, exit_code:3, success:false, result:null}]')"
      [[ "$(optBool continue-on-error)" != "true" ]] && break
      continue
    fi
    args=(${SPLIT_ARGS[@]+"${SPLIT_ARGS[@]}"})
    logInfo "[batch ${total}] octoflare ${line}"
    output="$(runCommand ${global_opts[@]+"${global_opts[@]}"} ${args[@]+"${args[@]}"} --output=json --github-output=false)"
    code=$?
    if [[ "$output" == *"::"* ]]; then
      # GitHub workflow commands (::error::, ::add-mask::) must reach the real stdout, not the result
      printf '%s\n' "$output" | grep -E '^::' || true
      output="$(printf '%s\n' "$output" | grep -vE '^::' || true)"
    fi
    printf '%s' "$output" | jq -e . >/dev/null 2>&1 || output="$(jq -cn --arg o "$output" '$o')"
    results="$(jq -cn --argjson r "$results" --arg c "$line" --argjson code "$code" --argjson o "${output:-null}" '$r + [{command:$c, exit_code:$code, success:($code == 0), result:$o}]')"
    if [[ $code -ne 0 ]]; then
      failed=$((failed + 1))
      logError "[batch ${total}] failed with exit code ${code}: ${line}"
      [[ "$(optBool continue-on-error)" != "true" ]] && break
    fi
  done <<<"$lines"
  local summary
  summary="$(jq -cn --argjson r "$results" --argjson t "$total" --argjson f "$failed" '{total:$t, failed:$f, succeeded:($t - $f), results:$r}')"
  emitResult "$summary" '"total=\(.total) succeeded=\(.succeeded) failed=\(.failed)\n" + ([.results[] | "\(if .success then "ok  " else "FAIL" end)\t\(.command)"] | join("\n"))'
  ghOutput failed "$failed"
  [[ $failed -eq 0 ]] || return "$EX_FAILURE"
  return 0
}

#####################################################################################################################VDM
######################################## exec: one command line as a single string

# cmd_exec_default - Allows "octoflare exec --line=..." without the "line" action
cmd_exec_default() { cmd_exec_line; }

# cmd_exec_line - Run a command line given as one string. The GitHub Action uses this so the
# "command" input is tokenised by splitArgs (quotes honoured, nothing evaluated) instead of
# being passed through eval. Runs in-process: outputs, GitHub step outputs and the exit code
# are exactly those of the command itself. A multi-line string is handed to batch run.
cmd_exec_line() {
  local line item global_opts=()
  line="$(optFirst "${OCTOFLARE_COMMAND_LINE:-}" line command)"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && die "Missing --line=<command line> (e.g. --line=\"dns upsert --name=www --type=A --content=203.0.113.10\")" "$EX_ARGS"
  for item in ${PARSED_OPTS[@]+"${PARSED_OPTS[@]}"}; do
    case "$item" in
      --line=*|--command=*) ;;
      *) global_opts+=("$item") ;;
    esac
  done
  if [[ "$line" == *$'\n'* ]]; then
    setOpt commands "$line"
    cmd_batch_run
    return $?
  fi
  line="${line#octoflare }"
  splitArgs "$line" || die "Could not parse the command line (unterminated quote): ${line}" "$EX_ARGS"
  runCommand ${global_opts[@]+"${global_opts[@]}"} ${SPLIT_ARGS[@]+"${SPLIT_ARGS[@]}"}
}
