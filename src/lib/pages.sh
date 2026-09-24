#!/usr/bin/env bash
# Octoflare module: pages
#
# Cloudflare Pages projects, deployments, custom domains and build cache.
# Direct uploads of a build directory are delegated to wrangler (installed
# on demand in unattended mode).
#
# @copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
# @license    GNU General Public License version 2; see LICENSE

registerCommand pages list "" "List Pages projects"
registerCommand pages get "--project=<name>" "Show a Pages project"
registerCommand pages create "--project=<name> [--production-branch=main]" "Create a Pages project (direct upload)"
registerCommand pages delete "--project=<name>" "Delete a Pages project"
registerCommand pages deployments "--project=<name> [--env=production|preview]" "List deployments"
registerCommand pages deploy "--project=<name> [--branch=<branch>] [--dir=<build-dir>] [--commit-message=<text>]" "Trigger a build (git projects) or upload --dir with wrangler"
registerCommand pages deployment "--project=<name> --deployment=<id>" "Show a deployment"
registerCommand pages logs "--project=<name> --deployment=<id>" "Show deployment build logs"
registerCommand pages retry "--project=<name> --deployment=<id>" "Retry a deployment"
registerCommand pages rollback "--project=<name> --deployment=<id>" "Roll back production to a deployment"
registerCommand pages delete-deployment "--project=<name> --deployment=<id> [--force]" "Delete a deployment"
registerCommand pages domains "--project=<name>" "List custom domains"
registerCommand pages domain-add "--project=<name> --name=<hostname> [--dns]" "Add a custom domain (--dns also creates the CNAME record)"
registerCommand pages domain-delete "--project=<name> --name=<hostname>" "Remove a custom domain"
registerCommand pages purge-build-cache "--project=<name>" "Purge the build cache"

PAGES_PROJECT_TEMPLATE='.[] | "\(.name)\t\(.subdomain // "-")\tbranch=\(.production_branch // "-")\tlatest=\(.latest_deployment.latest_stage.status // "-")\tdomains=\((.domains // [])|join(","))"'
PAGES_DEPLOY_TEMPLATE='.[] | "\(.id)\t\(.environment)\t\(.latest_stage.name // "-"):\(.latest_stage.status // "-")\t\(.url // "-")\t\(.deployment_trigger.metadata.branch // "-")@\((.deployment_trigger.metadata.commit_hash // "-")[0:7])\t\(.created_on)"'
PAGES_DEPLOY_ONE='"id=\(.id)\nurl=\(.url // "-")\nenvironment=\(.environment)\nstage=\(.latest_stage.name // "-"):\(.latest_stage.status // "-")\nbranch=\(.deployment_trigger.metadata.branch // "-")\ncommit=\(.deployment_trigger.metadata.commit_hash // "-")\ncreated_on=\(.created_on)"'

# pagesProject - The project name from --project/--name
pagesProject() {
  local p
  p="$(optFirst "" project project-name)"
  [[ -z "$p" ]] && die "Missing --project=<name>" "$EX_ARGS"
  printf '%s' "$p"
}

# pagesDeployment - The deployment id from --deployment/--id
pagesDeployment() {
  local d
  d="$(optFirst "" deployment deployment-id id)"
  [[ -z "$d" ]] && die "Missing --deployment=<id>" "$EX_ARGS"
  printf '%s' "$d"
}

cmd_pages_list() {
  resolveAccount
  cfApiList "/accounts/${CF_ACCOUNT_ID}/pages/projects"
  emitResult "$(cfResult)" "$PAGES_PROJECT_TEMPLATE" "No Pages projects."
}

cmd_pages_get() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)"
  emitResult "$(cfResult)" '"name=\(.name)\nsubdomain=\(.subdomain // "-")\nproduction_branch=\(.production_branch // "-")\ndomains=\((.domains // [])|join(","))\nsource=\(.source.type // "direct upload")\nlatest_deployment=\(.latest_deployment.url // "-") (\(.latest_deployment.latest_stage.status // "-"))\ncreated_on=\(.created_on)"'
}

cmd_pages_create() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  local body
  body="$(jq -cn --arg n "$(pagesProject)" --arg b "$(opt production-branch main)" '{name:$n, production_branch:$b}')"
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/pages/projects" "$body"
  emitResult "$(cfResult)" '"name=\(.name)\nsubdomain=\(.subdomain // "-")\nproduction_branch=\(.production_branch // "-")"'
}

cmd_pages_delete() {
  resolveAccount
  local p
  p="$(pagesProject)" || exit $?
  confirm "Delete Pages project ${p} and all its deployments?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/pages/projects/${p}"
  emitMessage "Pages project ${p} deleted." "$(jq -cn --arg n "$p" '{name:$n}')"
}

cmd_pages_deployments() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  cfApiList "/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)/deployments" "$(cfQuery "env=$(opt env)")"
  emitResult "$(cfResult)" "$PAGES_DEPLOY_TEMPLATE" "No deployments."
}

cmd_pages_deployment() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  pagesDeployment >/dev/null || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)/deployments/$(pagesDeployment)"
  emitResult "$(cfResult)" "$PAGES_DEPLOY_ONE"
}

cmd_pages_logs() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  pagesDeployment >/dev/null || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)/deployments/$(pagesDeployment)/history/logs"
  emitResult "$(cfResult)" '.data[]? | "\(.ts)\t\(.line)"' "No logs."
}

cmd_pages_retry() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  pagesDeployment >/dev/null || exit $?
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)/deployments/$(pagesDeployment)/retry" "" none
  emitResult "$(cfResult)" "$PAGES_DEPLOY_ONE"
}

cmd_pages_rollback() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  pagesDeployment >/dev/null || exit $?
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)/deployments/$(pagesDeployment)/rollback" "" none
  emitResult "$(cfResult)" "$PAGES_DEPLOY_ONE"
}

cmd_pages_delete_deployment() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  pagesDeployment >/dev/null || exit $?
  local path
  path="/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)/deployments/$(pagesDeployment)"
  [[ "$(optBool force)" == "true" ]] && path="${path}?force=true"
  confirm "Delete deployment $(pagesDeployment)?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "$path"
  emitMessage "Deployment $(pagesDeployment) deleted." "$(jq -cn --arg id "$(pagesDeployment)" '{id:$id}')"
}

# wranglerCmd - Print the wrangler command to use, installing it in unattended mode when missing
wranglerCmd() {
  if hasCmd wrangler; then
    echo "wrangler"
    return 0
  fi
  if hasCmd npx; then
    echo "npx --yes wrangler@latest"
    return 0
  fi
  if hasCmd npm; then
    logInfo "Installing wrangler with npm..."
    npm install -g wrangler >/dev/null 2>&1 && hasCmd wrangler && { echo "wrangler"; return 0; }
  fi
  die "wrangler is required to upload a directory to Pages. Install Node.js (npm/npx) or wrangler and try again." "$EX_UNAVAILABLE"
}

cmd_pages_deploy() {
  resolveAccount
  local project branch dir cmd msg
  project="$(pagesProject)" || exit $?
  branch="$(opt branch)"
  dir="$(optFirst "" dir directory)"
  if [[ -n "$dir" ]]; then
    [[ -d "$dir" ]] || die "Build directory not found: ${dir}" "$EX_ARGS"
    cmd="$(wranglerCmd)" || exit $?
    msg="$(opt commit-message)"
    logInfo "Uploading ${dir} to Pages project ${project} with wrangler..."
    if [[ "$OCTOFLARE_DRY_RUN" == "true" ]]; then
      emitMessage "[dry-run] ${cmd} pages deploy ${dir} --project-name=${project}${branch:+ --branch=${branch}}"
      return 0
    fi
    # shellcheck disable=SC2086
    CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID" $cmd pages deploy "$dir" --project-name="$project" ${branch:+--branch="$branch"} ${msg:+--commit-message="$msg"} || die "wrangler pages deploy failed" "$EX_FAILURE"
    cfApiList "/accounts/${CF_ACCOUNT_ID}/pages/projects/${project}/deployments"
    emitResult "$(cfResult '.result[0] // {}')" "$PAGES_DEPLOY_ONE"
    return 0
  fi
  logInfo "Triggering a new build for Pages project ${project}${branch:+ (branch ${branch})}..."
  if [[ -n "$branch" ]]; then
    cfApi POST "/accounts/${CF_ACCOUNT_ID}/pages/projects/${project}/deployments" "" multipart -F "branch=${branch}"
  else
    cfApi POST "/accounts/${CF_ACCOUNT_ID}/pages/projects/${project}/deployments" "" multipart -F "commit_dirty=false"
  fi
  emitResult "$(cfResult)" "$PAGES_DEPLOY_ONE"
}

cmd_pages_domains() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  cfApi GET "/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)/domains"
  emitResult "$(cfResult)" '.[] | "\(.name)\tstatus=\(.status)\tcert=\(.certificate_authority // "-")\tvalidation=\(.validation_data.status // "-")"' "No custom domains."
}

cmd_pages_domain_add() {
  resolveAccount
  requireOpt name
  local project host subdomain
  project="$(pagesProject)" || exit $?
  host="$(opt name)"
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/pages/projects/${project}/domains" "$(jq -cn --arg n "$host" '{name:$n}')"
  if [[ "$(optBool dns)" == "true" ]]; then
    cfApi GET "/accounts/${CF_ACCOUNT_ID}/pages/projects/${project}"
    subdomain="$(cfResultRaw '.result.subdomain // empty')"
    [[ -z "$subdomain" ]] && subdomain="${project}.pages.dev"
    CF_ZONE_ID=""
    setOpt type CNAME
    setOpt content "$subdomain"
    setOpt proxied true
    logInfo "Creating CNAME ${host} -> ${subdomain}..."
    cmd_dns_upsert
    return 0
  fi
  emitResult "$(cfResult)" '"name=\(.name)\nstatus=\(.status)"'
}

cmd_pages_domain_delete() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  requireOpt name
  confirm "Remove custom domain $(opt name) from $(pagesProject)?" || die "Cancelled." "$EX_OK"
  cfApi DELETE "/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)/domains/$(opt name)"
  emitMessage "Custom domain $(opt name) removed." "$(jq -cn --arg n "$(opt name)" '{name:$n}')"
}

cmd_pages_purge_build_cache() {
  resolveAccount
  pagesProject >/dev/null || exit $?
  cfApi POST "/accounts/${CF_ACCOUNT_ID}/pages/projects/$(pagesProject)/purge_build_cache" "" none
  emitMessage "Build cache purged for $(pagesProject)."
}
