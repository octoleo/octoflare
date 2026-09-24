# Changelog

## Unreleased

Hardening from an adversarial review of 2.0.0 (core, transport, rules, DNS and settings so
far; Workers/Pages/Tunnel, account-level modules and the action packaging are still to come).

### Fixed
* `bot ai-bots block` sent `disabled`; the value is now validated (block, disabled,
  only_on_ad_pages or a boolean word) and every on/off toggle rejects unknown words instead of
  turning the feature off.
* `pages deployments --env=production` was taken as an env file: `-e`/`--env-file` always name
  the env file, and `--env` is handed to commands that define it.
* `min_tls_version`/`origin_max_http_version` were sent as numbers; numeric JSON is now used only
  for numeric settings. `ssl hsts` without options no longer crashes.
* TXT content is sent and compared in the quoted form the API stores, structured records (SRV,
  CAA, --data) are matched on their data, numeric record options are validated, `zone create`
  no longer looks up the zone it is about to create, `cache purge --urls=@file` splits on
  newlines only.
* Firewall/transform list options no longer word-split or glob their values; filter strings are
  quoted with jq (works on Bash 3.2); redirects handle scheme-less `host/path*` sources,
  wildcard hosts and query strings; page rule upserts keep the existing priority/status;
  zone access rules ignore account-wide rules; 404s on page rules by id are "not found".
* Transport: credentials go to curl through a 0600 config file and bodies through private temp
  files (nothing in `ps`, no argv size limit); POST requests are retried only on 429; pages are
  50 items with `--limit` spanning pages; an explicit `--domain` beats an ambient
  `CLOUDFLARE_ZONE_ID`; only URLs under `CLOUDFLARE_API_BASE` (https) are ever requested.
* Env files: only explicitly requested files are loaded in unattended runs, original environment
  variables win over the file, quoted values followed by comments and CRLF parse correctly,
  `OCTOFLARE_*` switches can come from the file.
* GitHub Actions: annotations and masks go to stderr (stdout stays valid JSON), `exit_code` is
  written even when a command dies, bootstrap failures are annotated, batch lines are tokenised
  without `eval` (core helper; the action packaging still needs the matching change).
* Bootstrap: downloads have timeouts, the third-party static curl fallback is gone, the static jq
  fallback is pinned and checksum-verified, `/tmp` is never used as the data directory,
  `self uninstall` refuses to delete unrelated directories, `self install-deps` treats openssl
  as optional, the installer copes with an unset `HOME`.


## 2.0.0

Octoflare grew from an "Under Attack Mode" toggle into a full Cloudflare automation tool for
workflows.

### Added
* `<resource> <action>` command structure with 240+ commands covering zones, DNS, zone settings,
  cache, Under Attack mode, IP access rules, User-Agent rules, Zone Lockdown, Bot Fight Mode, the
  rules engine (single redirects, custom WAF rules, rate limiting, URL/header transforms, cache,
  configuration and origin rules, generic phases), Page Rules, SSL/TLS, HSTS, Universal SSL,
  Origin CA certificates, DNSSEC, Workers, KV, Pages, Cloudflare Tunnel, Email Routing, Turnstile,
  R2, account lists, Bulk Redirects, Web Analytics, GraphQL analytics, a raw `api` passthrough and
  a `batch` runner.
* Idempotent `upsert`-style commands that report `created`, `updated` or `unchanged`.
* GitHub Action (`action.yml`) with `command`/`commands` inputs and `result`, `id`, `zone-id`,
  `zone-name`, `account-id`, `exit-code`, `failed` outputs; `::error::` annotations and secret
  masking.
* Unattended mode (automatic in CI): no prompts, automatic installation of `curl`, `jq` and of
  missing modules; `install.sh` one-line installer; single-file bundle build (`scripts/bundle.sh`)
  published with releases.
* JSON output (`--json`, `--pretty`), `--field=<jq>` extraction, `--dry-run`, `--limit`,
  automatic pagination, retries with back-off on 429/5xx, zone auto-detection from FQDNs,
  `--zone-id` bypass, wrangler-style `CF_*` variable aliases, global API key authentication.
* Test suite (bats + mock Cloudflare API), ShellCheck configuration, CI and release workflows,
  example workflows and batch file.

### Changed
* Logs are written to stderr; stdout only carries results.
* Environment files no longer override variables already present in the environment
  (`OCTOFLARE_ENV_OVERRIDE=true` restores the old behaviour).
* `attack-mode disable` restores `high` by default (v1 code used `under_attack`).
* `--debug` now enables verbose logging; without a command it still prints the configuration.

### Compatibility
* `--enable-attack-mode`, `--disable-attack-mode`, `--status-attack-mode`, `--domain=`, `-e/--env`,
  `--update`, `--uninstall`, `--quiet` and `-h` keep working.

## 1.0.1
* Update/install pipeline through GitHub.

## 1.0.0
* Initial release: enable, disable and show Cloudflare "Under Attack Mode" for a zone.
