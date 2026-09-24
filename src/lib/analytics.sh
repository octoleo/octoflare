#!/usr/bin/env bash
# Octoflare module: analytics
#
# Zone analytics through the GraphQL Analytics API (requests, bandwidth,
# threats, page views, unique visitors) plus a raw GraphQL passthrough.
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand analytics zone "--domain=<zone> [--days=7]" "Daily traffic summary for the last N days (requests, bytes, threats, page views, uniques)"
registerCommand analytics firewall "--domain=<zone> [--days=1]" "Firewall events summary grouped by action and source"
registerCommand analytics query "--query=<graphql|@file> [--variables=<json>]" "Run a raw GraphQL Analytics query"

# graphql - POST a GraphQL query with variables
graphql() {
  local query="$1" variables="${2:-}"
  [[ -z "$variables" ]] && variables='{}'
  cfApi POST "/graphql" "$(jq -cn --arg q "$query" --argjson v "$variables" '{query:$q, variables:$v}')"
  if printf '%s' "$CF_RESPONSE" | jq -e '.errors and (.errors|length) > 0' >/dev/null 2>&1; then
    logError "GraphQL query failed:"
    printf '%s' "$CF_RESPONSE" | jq -r '.errors[] | "  - \(.message)"' >&2
    exit "$EX_FAILURE"
  fi
}

# dateDaysAgo - YYYY-MM-DD for N days ago (GNU date, BSD date, then jq for BusyBox and friends)
dateDaysAgo() {
  local n="$1" d
  d="$(date -u -d "-${n} days" +%Y-%m-%d 2>/dev/null)" \
    || d="$(date -u -v "-${n}d" +%Y-%m-%d 2>/dev/null)" \
    || d="$(jq -rn --argjson n "$n" '(now - $n * 86400) | strftime("%Y-%m-%d")')"
  printf '%s' "$d"
}

# dateTimeDaysAgo - ISO 8601 UTC timestamp for N days ago (same fallbacks)
dateTimeDaysAgo() {
  local n="$1" d
  d="$(date -u -d "-${n} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    || d="$(date -u -v "-${n}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    || d="$(jq -rn --argjson n "$n" '(now - $n * 86400) | strftime("%Y-%m-%dT%H:%M:%SZ")')"
  printf '%s' "$d"
}

cmd_analytics_zone() {
  resolveZone
  local days since until query result
  days="$(opt days 7)"
  since="$(dateDaysAgo "$days")"
  until="$(date -u +%Y-%m-%d)"
  # shellcheck disable=SC2016
  query='query ($zoneTag: String!, $since: Date!, $until: Date!) {
    viewer { zones(filter: {zoneTag: $zoneTag}) {
      httpRequests1dGroups(limit: 366, filter: {date_geq: $since, date_leq: $until}, orderBy: [date_ASC]) {
        dimensions { date }
        sum { requests bytes cachedRequests cachedBytes threats pageViews encryptedRequests }
        uniq { uniques }
      }
    } }
  }'
  graphql "$query" "$(jq -cn --arg z "$CF_ZONE_ID" --arg s "$since" --arg u "$until" '{zoneTag:$z, since:$s, until:$u}')"
  result="$(printf '%s' "$CF_RESPONSE" | jq -c --arg s "$since" --arg u "$until" '
    (.data.viewer.zones[0].httpRequests1dGroups // []) as $days |
    {since:$s, until:$u,
     totals:{requests:([$days[].sum.requests]|add // 0), bytes:([$days[].sum.bytes]|add // 0), cached_requests:([$days[].sum.cachedRequests]|add // 0), cached_bytes:([$days[].sum.cachedBytes]|add // 0), threats:([$days[].sum.threats]|add // 0), page_views:([$days[].sum.pageViews]|add // 0), encrypted_requests:([$days[].sum.encryptedRequests]|add // 0), uniques_max_day:([$days[].uniq.uniques]|max // 0)},
     days:[$days[] | {date:.dimensions.date, requests:.sum.requests, bytes:.sum.bytes, cached_requests:.sum.cachedRequests, threats:.sum.threats, page_views:.sum.pageViews, uniques:.uniq.uniques}]}')"
  emitResult "$result" '"period=\(.since)..\(.until)\nrequests=\(.totals.requests)\nbytes=\(.totals.bytes)\ncached_requests=\(.totals.cached_requests)\nthreats=\(.totals.threats)\npage_views=\(.totals.page_views)\nencrypted_requests=\(.totals.encrypted_requests)\n" + ([.days[] | "\(.date)\treq=\(.requests)\tbytes=\(.bytes)\tcached=\(.cached_requests)\tthreats=\(.threats)\tviews=\(.page_views)\tuniques=\(.uniques)"] | join("\n"))'
}

cmd_analytics_firewall() {
  resolveZone
  local days since query result
  days="$(opt days 1)"
  since="$(dateTimeDaysAgo "$days")"
  # shellcheck disable=SC2016
  query='query ($zoneTag: String!, $since: Time!) {
    viewer { zones(filter: {zoneTag: $zoneTag}) {
      firewallEventsAdaptiveGroups(limit: 100, filter: {datetime_geq: $since}, orderBy: [count_DESC]) {
        count
        dimensions { action source }
      }
    } }
  }'
  graphql "$query" "$(jq -cn --arg z "$CF_ZONE_ID" --arg s "$since" '{zoneTag:$z, since:$s}')"
  result="$(printf '%s' "$CF_RESPONSE" | jq -c --arg s "$since" '{since:$s, events:[(.data.viewer.zones[0].firewallEventsAdaptiveGroups // [])[] | {action:.dimensions.action, source:.dimensions.source, count}], total:([(.data.viewer.zones[0].firewallEventsAdaptiveGroups // [])[].count]|add // 0)}')"
  emitResult "$result" '"since=\(.since)\ntotal=\(.total)\n" + ([.events[] | "\(.count)\t\(.action)\t\(.source)"] | join("\n"))'
}

cmd_analytics_query() {
  local query variables
  query="$(inputFromOpts query)" || exit $?
  [[ -z "$query" ]] && die "Missing --query=<graphql> (or --query=@file.graphql)" "$EX_ARGS"
  variables="$(readFileOrValue "$(opt variables '{}')")"
  graphql "$query" "$variables"
  emitResult "$(printf '%s' "$CF_RESPONSE" | jq -c '.data')"
}
