#!/usr/bin/env bash
# Octoflare module: turnstile
#
# Turnstile widgets (CAPTCHA alternative): list, create, update, delete and
# secret rotation.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand turnstile list "" "List Turnstile widgets"
registerCommand turnstile get "--sitekey=<key>" "Show a widget (includes the secret)"
registerCommand turnstile create "--name=<text> --domains=<a,b> [--mode=managed|non-interactive|invisible] [--bot-fight-mode] [--region=world]" "Create a widget"
registerCommand turnstile update "--sitekey=<key> [--name=] [--domains=] [--mode=] [--bot-fight-mode=]" "Update a widget"
registerCommand turnstile delete "--sitekey=<key>" "Delete a widget"
registerCommand turnstile rotate-secret "--sitekey=<key> [--invalidate-immediately]" "Rotate the widget secret"

TURNSTILE_TEMPLATE='.[] | "\(.sitekey)\t\(.name)\t\(.mode)\tdomains=\((.domains // [])|join(","))"'
TURNSTILE_ONE='"sitekey=\(.sitekey)\nsecret=\(.secret // "-")\nname=\(.name)\nmode=\(.mode)\ndomains=\((.domains // [])|join(","))\nbot_fight_mode=\(.bot_fight_mode // false)\nregion=\(.region // "-")"'

turnstileKey() {
  local k
  k="$(optFirst "" sitekey site-key key id)"
  [[ -z "$k" ]] && die "Missing --sitekey=<key>" "$EX_ARGS"
  printf '%s' "$k"
}

cmd_turnstile_list() {
  resolveAccount
  cfApiList "/accounts/${CF_ACCOUNT_ID}/challenges/widgets"
  emitResult "$(cfResult)" "$TURNSTILE_TEMPLATE" "No Turnstile widgets."
}

cmd_turnstile_get() {
  resolveAccount
  turnstileKey >/dev/null || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/challenges/widgets/$(turnstileKey)"
  ghMask "$(cfResultRaw '.result.secret // ""')"
  emitResult "$(cfResult)" "$TURNSTILE_ONE"
}

cmd_turnstile_create() {
  resolveAccount
  requireOpt name domains
  local body
  body="$(jq -cn --arg n "$(opt name)" --argjson d "$(toJsonArray "$(opt domains)")" --arg m "$(opt mode managed)" --argjson b "$(optBool bot-fight-mode false)" --arg r "$(opt region world)" \
    '{name:$n, domains:$d, mode:$m, bot_fight_mode:$b, region:$r}')"
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/challenges/widgets" "$body"
  ghMask "$(cfResultRaw '.result.secret // ""')"
  emitResult "$(cfResult)" "$TURNSTILE_ONE"
}

cmd_turnstile_update() {
  resolveAccount
  local key body
  key="$(turnstileKey)" || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/challenges/widgets/${key}"
  body="$(cfResult '.result | {name, domains, mode, bot_fight_mode, region, clearance_level, offlabel} | with_entries(select(.value != null))')"
  hasOpt name && body="$(jq -cn --argjson b "$body" --arg v "$(opt name)" '$b + {name:$v}')"
  hasOpt domains && body="$(jq -cn --argjson b "$body" --argjson v "$(toJsonArray "$(opt domains)")" '$b + {domains:$v}')"
  hasOpt mode && body="$(jq -cn --argjson b "$body" --arg v "$(opt mode)" '$b + {mode:$v}')"
  hasOpt bot-fight-mode && body="$(jq -cn --argjson b "$body" --argjson v "$(optBool bot-fight-mode)" '$b + {bot_fight_mode:$v}')"
  hasOpt clearance-level && body="$(jq -cn --argjson b "$body" --arg v "$(opt clearance-level)" '$b + {clearance_level:$v}')"
  cfApi PUT "/accounts/${CF_ACCOUNT_ID}/challenges/widgets/${key}" "$body"
  emitResult "$(cfResult)" "$TURNSTILE_ONE"
}

cmd_turnstile_delete() {
  resolveAccount
  local key
  key="$(turnstileKey)" || exit $?
  confirm "Delete Turnstile widget ${key}?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/challenges/widgets/${key}"
  emitMessage "Turnstile widget ${key} deleted." "$(jq -cn --arg k "$key" '{sitekey:$k}')"
}

cmd_turnstile_rotate_secret() {
  resolveAccount
  turnstileKey >/dev/null || exit $?
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/challenges/widgets/$(turnstileKey)/rotate_secret" "$(jq -cn --argjson i "$(optBool invalidate-immediately false)" '{invalidate_immediately:$i}')"
  ghMask "$(cfResultRaw '.result.secret // ""')"
  emitResult "$(cfResult)" "$TURNSTILE_ONE"
}
