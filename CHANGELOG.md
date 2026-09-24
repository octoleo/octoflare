# Changelog

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
