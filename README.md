<h2><img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png" >
Octoflare - Cloudflare automation for the CLI and CI workflows
</h2>

Written by Llewellyn van der Merwe (@llewellynvdm)

Octoflare is a dependency-light Bash tool that drives the Cloudflare v4 API. It is built for
**unattended use in workflows** (GitHub Actions, cron jobs, deploy scripts) and just as
comfortable on a laptop. Anything a workflow needs to do in Cloudflare - point a subdomain at a
new host, add a redirect, purge the cache, switch on *Under Attack* mode, tune TLS, publish a
Worker, wire up a tunnel - is one command.

Linted by [#ShellCheck](https://github.com/koalaman/shellcheck), tested with
[bats-core](https://github.com/bats-core/bats-core) against a mock Cloudflare API.

## Highlights

* **Every free Cloudflare feature**: zones, DNS (with BIND import/export and batch), zone settings,
  cache purge, Under Attack mode, IP access rules, User-Agent rules, Bot Fight Mode, the rules
  engine (single redirects, custom WAF rules, rate limiting, URL/header transforms, cache,
  configuration and origin rules), Page Rules, SSL/TLS, HSTS, Universal SSL, Origin CA
  certificates, DNSSEC, Workers, KV, Pages, Cloudflare Tunnel, Email Routing, Turnstile, R2,
  account lists, Bulk Redirects, Web Analytics and GraphQL analytics - plus a raw `api`
  passthrough for everything else.
* **Idempotent verbs** (`upsert`, `block`, `set`) so a workflow can declare the desired state and
  re-run safely; results report `created`, `updated` or `unchanged`.
* **Workflow ready**: a composite GitHub Action (`uses: octoleo/octoflare@master`), JSON output,
  `--field=<jq>` extraction, step outputs (`result`, `id`, `zone-id`, ...), `::error::`
  annotations, secret masking and a batch runner for multi-step changes.
* **Unattended by design**: in CI (or with `--unattended`) it never prompts and installs whatever
  it is missing - `curl`, `jq`, and its own modules - instead of failing.
* **Zone auto-detection**: `dns upsert --name=app.example.com ...` finds the zone from the record
  name; `--zone-id` skips lookups entirely.
* **Safe transport**: retries with back-off on 429 and, for idempotent requests, on 5xx and
  network errors (honouring `Retry-After`; a POST is never replayed after a 5xx), automatic
  pagination, credentials and bodies passed to curl through private files rather than the
  command line, clear error messages with Cloudflare error codes, `--dry-run` to preview requests.
* **v1 compatible**: `--enable-attack-mode`, `--disable-attack-mode`, `--status-attack-mode`,
  `--domain=`, `--env`, `--update`, `--uninstall` and `--quiet` still work.

## Install

One-liner (installs the script, its modules and `curl`/`jq` when missing):

```shell
curl -fsSL https://raw.githubusercontent.com/octoleo/octoflare/master/install.sh | bash
```

* installs to `/usr/local/bin/octoflare` + `/usr/local/lib/octoflare/` when writable (or via sudo),
  otherwise to `~/.local/bin` + `~/.local/lib/octoflare/`
* `OCTOFLARE_PREFIX=/opt/octoflare` and `OCTOFLARE_REF=v2.0.0` override the location and version

Manual install of just the entry script also works - it fetches its modules on first run:

```shell
sudo curl -fsSL https://raw.githubusercontent.com/octoleo/octoflare/master/src/octoflare -o /usr/local/bin/octoflare
sudo chmod +x /usr/local/bin/octoflare
octoflare --version   # downloads the lib modules into /usr/local/lib/octoflare or ~/.local/share/octoflare/lib
```

A **single-file bundle** (all modules inlined) is attached to every
[release](https://github.com/octoleo/octoflare/releases) and can be built locally with
`scripts/bundle.sh`.

Requirements: Bash 3.2+, `curl`, `jq` (both auto-installed in unattended mode; `openssl` only for
`ssl origin-cert-create`; `wrangler`/Node only for `pages deploy --dir`).

Update and remove:

```shell
octoflare --update        # or: octoflare self update
octoflare --uninstall     # or: octoflare self uninstall
```

## Quick start

```shell
export CLOUDFLARE_API_TOKEN="..."          # or put it in ~/.config/octoflare/.env

octoflare zone list
octoflare dns upsert --domain=example.com --name=www --type=A --content=203.0.113.10 --proxied
octoflare dns upsert --name=app.example.com --type=CNAME --content=my-app.pages.dev --proxied
octoflare redirect upsert --domain=example.com --from=/old-page --to=https://example.com/new-page --status=301
octoflare cache purge --domain=example.com --everything
octoflare attack-mode enable --domain=example.com
octoflare ssl mode strict --domain=example.com
octoflare setting set --domain=example.com --name=always_use_https --value=on
octoflare firewall upsert --domain=example.com --action=managed_challenge --countries=CN,RU --paths=/wp-login.php
octoflare tunnel create --name=home            # prints the cloudflared token
octoflare help                                 # everything, grouped by resource
octoflare help dns                             # one resource
octoflare help --output=json                   # machine readable command list
```

Every command accepts `--json` (compact JSON), `--pretty`, `--field=<jq expression>` and
`--dry-run`. Logs go to **stderr**, results to **stdout**, so output is safe to pipe.

## Configuration

### Credentials

| Variable | Purpose |
|---|---|
| `CLOUDFLARE_API_TOKEN` | API token (recommended). Alias: `CF_API_TOKEN`, or `--api-token=` |
| `CLOUDFLARE_EMAIL` + `CLOUDFLARE_API_KEY` | Legacy global API key authentication (`CF_API_EMAIL`/`CF_API_KEY`, or `--api-email=` / `--api-key=`) |
| `CLOUDFLARE_ACCOUNT_ID` | Account for account-level features; auto-detected when the token sees one account or from the zone (`--account-id=`) |
| `CLOUDFLARE_ZONE_ID` | Zone ID; skips the name lookup (`--zone-id=`) |
| `CLOUDFLARE_DOMAIN` | Default zone (`--domain=` / `--zone=`) |
| `CLOUDFLARE_ORIGIN_CA_KEY` | Origin CA key for `ssl origin-cert-*` (an API token with *SSL and Certificates:Edit* also works) |
| `CLOUDFLARE_RESTORE_LEVEL` | Security level restored by `attack-mode disable` (default `high`) |
| `CLOUDFLARE_API_BASE` | API base URL (default `https://api.cloudflare.com/client/v4`; must be `https://`, plain `http://` only for localhost; used by the tests) |

### Environment files

Octoflare loads the file named by `-e <file>` / `--env-file=<file>` / `OCTOFLARE_ENV_FILE`
(`--env=<file>` still works unless the command itself defines `--env`, as `pages deployments`
does). Interactively, when no file is given, it also looks for `./.octoflare`,
`./.env.octoflare` and `~/.config/octoflare/.env`; **unattended runs (CI, GitHub Actions) only
load a file that was requested explicitly**, so a checked-in file from an untrusted contributor
can never change where requests go:

```txt
CLOUDFLARE_API_TOKEN="your-cloudflare-api-token"
CLOUDFLARE_ACCOUNT_ID="..."
CLOUDFLARE_DOMAIN="example.com"
```

Precedence is **command line > environment > env file**. Variables that were present in the
environment when Octoflare started (for example repository secrets in CI) are never overridden
by a file unless `OCTOFLARE_ENV_OVERRIDE=true` is set; `OCTOFLARE_*` switches can be set from
the file. Quoted values may be followed by `# comments`, and CRLF files are accepted. This
differs from v1, which sourced the file over the environment.

### Behaviour switches

| Variable / option | Effect |
|---|---|
| `OCTOFLARE_UNATTENDED=true` / `--unattended` / `-y` | No prompts (deletes are confirmed automatically), install missing dependencies and modules. Automatically on when `CI=true` or `GITHUB_ACTIONS=true` |
| `OCTOFLARE_OUTPUT=json\|text` / `--output=` / `--json` | Output format |
| `--field=<jq>` / `OCTOFLARE_FIELD` | Print only that part of the result (e.g. `--field=.id`) |
| `--pretty` | Indent JSON output |
| `--dry-run` / `OCTOFLARE_DRY_RUN=true` | Print the requests instead of sending them |
| `--quiet` / `-q`, `--debug` | Less / more logging (`--debug` without a command prints the configuration) |
| `--limit=<n>` | Return at most n items from list commands (pages are at most 50 items, so several pages may be fetched) |
| `--github-output=false` | Do not write GitHub step outputs |
| `OCTOFLARE_TIMEOUT`, `OCTOFLARE_RETRIES`, `OCTOFLARE_RETRY_DELAY`, `OCTOFLARE_PER_PAGE` | HTTP timeout (60s), retries (3), initial back-off (2s), page size (50) |
| `OCTOFLARE_REF`, `OCTOFLARE_LIB_DIR`, `OCTOFLARE_HOME` | Git ref for updates/module downloads, module directory, per-user data directory |
| `NO_COLOR` / `--color=never` | Disable coloured logs |

### API token permissions

Create a token at *My Profile > API Tokens* with only what the workflow needs:

| Feature | Permission |
|---|---|
| zone list/get, any zone command | Zone: **Zone:Read** |
| `dns *`, `tunnel route`, `pages domain-add --dns` | Zone: **DNS:Edit** |
| `setting *`, `attack-mode`, `dev-mode`, `ssl mode/min-tls/tls13/always-https/hsts`, `cache level/tiered` | Zone: **Zone Settings:Edit** |
| `cache purge` | Zone: **Cache Purge:Purge** |
| `access-rule`, `ua-rule`, `lockdown` | Zone (or Account): **Firewall Services:Edit** |
| `bot *` | Zone: **Bot Management:Edit** |
| `firewall`, `ratelimit`, `rule` | Zone: **Zone WAF:Edit** |
| `redirect` | Zone: **Dynamic URL Redirects:Edit** (Single Redirect) |
| `transform` | Zone: **Transform Rules:Edit** |
| `cache-rule`, `config-rule`, `origin-rule` | Zone: **Cache Rules:Edit**, **Config Rules:Edit**, **Origin Rules:Edit** |
| `pagerule` | Zone: **Page Rules:Edit** |
| `ssl universal/verification/certificates/origin-cert-*`, `dnssec` | Zone: **SSL and Certificates:Edit** (DNSSEC: **DNS:Edit**) |
| `workers *` | Account: **Workers Scripts:Edit**; Zone: **Workers Routes:Edit** |
| `kv *` | Account: **Workers KV Storage:Edit** |
| `pages *` | Account: **Cloudflare Pages:Edit** |
| `tunnel *` | Account: **Cloudflare Tunnel:Edit** |
| `email *` | Zone: **Email Routing Rules:Edit**; Account: **Email Routing Addresses:Edit** |
| `turnstile *` | Account: **Turnstile:Edit** |
| `r2 *` | Account: **Workers R2 Storage:Edit** |
| `list *`, `bulk-redirect *` | Account: **Account Filter Lists:Edit**, **Account WAF:Edit** |
| `web-analytics *` | Account: **Account Analytics:Read** + Web Analytics |
| `analytics *` | Zone: **Analytics:Read** |
| `account *`, `token verify` | Account: **Account Settings:Read** (token verify needs nothing extra) |

## Usage

```
octoflare [global options] <resource> <action> [--option=value ...]
```

Options are `--name=value` (or `--flag` / `--no-flag` for booleans) and can appear anywhere on the
line. Values can be read from files with `@path` or from stdin with `-` where a JSON body is
expected. Many commands also take a positional value, e.g. `octoflare ssl mode strict`.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Cloudflare API returned an error (details, with the Cloudflare error code, on stderr) |
| 2 | Missing credentials or configuration (also HTTP 401/403) |
| 3 | Missing or invalid command options |
| 4 | Zone could not be resolved |
| 5 | Requested object not found (HTTP 404, or no record/rule matched) |
| 64 | Unknown command |
| 69 | A dependency is missing and could not be installed |
| 70 | A module could not be loaded/downloaded |

### Zone selection

* `--domain=example.com` (or `CLOUDFLARE_DOMAIN`): the zone is looked up by name; a hostname such
  as `www.example.com` is accepted and walked up to the zone. An explicit `--domain` always wins
  over an ambient `CLOUDFLARE_ZONE_ID`.
* `--zone-id=<id>` on the command line, or `CLOUDFLARE_ZONE_ID` when no `--domain` was given: no
  lookup at all.
* No `--domain` but a fully qualified `--name`/`--hostname`: the zone is derived from it.
* Record names are matched to the zone case-insensitively and stored lowercase; TXT content is
  sent in the quoted form Cloudflare stores, so `dns upsert` stays idempotent for TXT records.
* Values that switch a feature on or off (`ssl always-https on`, `bot fight-mode on`,
  `cache tiered on`, ...) must be `on|off`, `true|false` or `yes|no`; anything else exits 3
  instead of silently turning the feature off.

## Command reference

Run `octoflare help <resource>` for the same information in the terminal, or
`octoflare help --output=json` for a machine readable list (useful when generating workflows).

#### `version`

| Command | Description |
|---|---|
| `version` | Show the Octoflare version |

#### `config`

| Command | Description |
|---|---|
| `config show` | Show the effective configuration (credentials are masked) |

#### `self`

| Command | Description |
|---|---|
| `self update` | Update Octoflare (script and modules) to the latest version |
| `self uninstall` | Remove Octoflare from this machine |
| `self install-deps` | Install missing dependencies (curl, jq, openssl) |
| `self path` | Show where Octoflare and its modules are installed |

#### `help`

| Command | Description |
|---|---|
| `help [resource]` | Show help; --output=json lists every command as JSON |

#### `zone`

| Command | Description |
|---|---|
| `zone list [--name=<filter>] [--status=<status>] [--account-id=<id>]` | List zones visible to the token |
| `zone get --domain=<zone>` | Show zone details |
| `zone id --domain=<zone>` | Print the zone ID |
| `zone create --name=<domain> [--account-id=<id>] [--type=full\|partial] [--jump-start]` | Add a new zone |
| `zone delete --domain=<zone> [--yes]` | Delete a zone |
| `zone check --domain=<zone>` | Re-run the zone activation check |
| `zone pause --domain=<zone>` | Pause Cloudflare on the zone (DNS only) |
| `zone resume --domain=<zone>` | Resume Cloudflare on the zone |
| `zone nameservers --domain=<zone>` | Show the assigned Cloudflare name servers |
| `zone hold-status --domain=<zone>` | Show the zone hold |
| `zone hold --domain=<zone> [--include-subdomains]` | Create a zone hold (prevents the zone being added to another account) |
| `zone unhold --domain=<zone> [--after=<iso8601>]` | Remove the zone hold |

#### `dns`

| Command | Description |
|---|---|
| `dns list --domain=<zone> [--type=A] [--name=<name>] [--content=<v>] [--proxied=true\|false] [--search=<text>] [--tag=<tag>]` | List DNS records |
| `dns get --name=<name> [--type=<type>] \| --id=<record-id>` | Show one DNS record |
| `dns create --name=<name> --type=<type> --content=<value> [--ttl=auto\|<seconds>] [--proxied] [--priority=<n>] [--comment=<text>] [--tags=a,b]` | Create a DNS record (TXT content is quoted for you) |
| `dns update (--id=<record-id> \| --name=<name> [--type=<type>]) [--content=] [--ttl=] [--proxied=] [--priority=] [--comment=] [--tags=] [--new-name=]` | Update an existing record |
| `dns upsert --name=<name> --type=<type> --content=<value> [--ttl=auto\|<seconds>] [--proxied] [--replace]` | Create the record or update it in place (idempotent; matches TXT content in its quoted form and SRV/CAA records on their data) |
| `dns set --name=<name> --type=<type> --content=<value> [--ttl=auto] [--proxied]` | Alias of upsert: set a record to the given value |
| `dns delete (--id=<record-id> \| --name=<name> [--type=<type>] [--content=<v>]) [--all] [--yes]` | Delete record(s) |
| `dns export --domain=<zone> [--file=<path>]` | Export the zone file (BIND format) |
| `dns import --domain=<zone> --file=<zonefile> [--proxied]` | Import a BIND zone file |
| `dns batch --domain=<zone> --file=<batch.json>` | Run a batch of posts/patches/puts/deletes in one request |
| `dns types` | List supported record types |

#### `setting`

| Command | Description |
|---|---|
| `setting list --domain=<zone>` | Show every zone setting |
| `setting get --domain=<zone> --name=<setting>` | Show one zone setting (e.g. ssl, security_level) |
| `setting set --domain=<zone> --name=<setting> --value=<value>` | Change one zone setting |
| `setting apply --domain=<zone> --settings='{"ssl":"strict",...}' \| --file=<json>` | Change many settings in one request |
| `setting names` | List common setting names and their values |

#### `dev-mode`

| Command | Description |
|---|---|
| `dev-mode status --domain=<zone>` | Show whether Development Mode is on |
| `dev-mode on --domain=<zone>` | Turn Development Mode on (bypasses cache for 3 hours) |
| `dev-mode off --domain=<zone>` | Turn Development Mode off |

#### `cache`

| Command | Description |
|---|---|
| `cache purge --domain=<zone> (--everything \| --urls=a,b \| --urls=@file \| --hosts=a,b \| --tags=a,b \| --prefixes=a,b)` | Purge cached content (inline --urls are comma separated; @file or - reads one URL per line) |
| `cache status --domain=<zone>` | Show cache related settings |
| `cache level --domain=<zone> [--value=aggressive\|basic\|simplified]` | Get or set the cache level |
| `cache browser-ttl --domain=<zone> [--value=<seconds>]` | Get or set the browser cache TTL |
| `cache tiered --domain=<zone> [on\|off]` | Get or set Smart Tiered Cache |

#### `attack-mode`

| Command | Description |
|---|---|
| `attack-mode status --domain=<zone>` | Show the current security level |
| `attack-mode enable --domain=<zone>` | Enable "I'm Under Attack" mode |
| `attack-mode disable --domain=<zone> [--restore-level=high]` | Disable attack mode and restore a security level |
| `attack-mode level --domain=<zone> --level=essentially_off\|low\|medium\|high\|under_attack` | Set the security level |

#### `access-rule`

| Command | Description |
|---|---|
| `access-rule list [--domain=<zone> \| --scope=account] [--mode=<mode>] [--value=<ip>]` | List IP Access rules |
| `access-rule create --mode=block\|challenge\|whitelist\|js_challenge\|managed_challenge --value=<ip\|cidr\|ASnnn\|CC> [--notes=<text>] [--scope=account]` | Create an IP Access rule |
| `access-rule upsert --mode=<mode> --value=<ip\|cidr\|ASnnn\|CC> [--notes=<text>]` | Create or update the rule for a value (idempotent) |
| `access-rule block --value=<ip\|cidr\|ASnnn\|CC> [--notes=<text>]` | Block an IP, range, ASN or country |
| `access-rule allow --value=<ip\|cidr\|ASnnn\|CC> [--notes=<text>]` | Allow (whitelist) an IP, range, ASN or country |
| `access-rule challenge --value=<ip\|cidr\|ASnnn\|CC> [--notes=<text>]` | Managed-challenge an IP, range, ASN or country |
| `access-rule delete (--id=<rule-id> \| --value=<ip\|cidr\|ASnnn\|CC>) [--scope=account]` | Delete an IP Access rule |

#### `ua-rule`

| Command | Description |
|---|---|
| `ua-rule list --domain=<zone>` | List User-Agent Blocking rules |
| `ua-rule create --domain=<zone> --mode=block\|challenge\|js_challenge\|managed_challenge --user-agent=<ua> [--description=<text>] [--paused]` | Create a User-Agent Blocking rule |
| `ua-rule update --domain=<zone> --id=<rule-id> [--mode=] [--user-agent=] [--description=] [--paused=]` | Update a User-Agent Blocking rule |
| `ua-rule delete --domain=<zone> --id=<rule-id>` | Delete a User-Agent Blocking rule |

#### `lockdown`

| Command | Description |
|---|---|
| `lockdown list --domain=<zone>` | List Zone Lockdown rules (Pro plan and above) |
| `lockdown create --domain=<zone> --urls=<a,b> --ips=<ip\|cidr,...> [--description=<text>] [--paused]` | Create a Zone Lockdown rule |
| `lockdown delete --domain=<zone> --id=<rule-id>` | Delete a Zone Lockdown rule |

#### `bot`

| Command | Description |
|---|---|
| `bot status --domain=<zone>` | Show Bot Fight Mode / bot management configuration |
| `bot fight-mode --domain=<zone> on\|off` | Turn Bot Fight Mode on or off |
| `bot ai-bots --domain=<zone> block\|disabled\|only_on_ad_pages (or on\|off)` | Block AI crawlers (AI bots protection); on = block, off = disabled |
| `bot set --domain=<zone> --settings='{"fight_mode":true,...}'` | Update any bot management field |

#### `rule`

| Command | Description |
|---|---|
| `rule phases` | List the ruleset phases and their aliases |
| `rule rulesets --domain=<zone> [--scope=account]` | List every ruleset of the zone (or account) |
| `rule list --domain=<zone> --phase=<phase>` | List the rules of a phase |
| `rule get --domain=<zone> --phase=<phase> (--id=<rule-id> \| --description=<text>)` | Show one rule |
| `rule create --domain=<zone> --phase=<phase> --expression=<filter> --action=<action> [--action-parameters=<json>] [--description=<text>] [--enabled=false]` | Add a rule to a phase |
| `rule upsert --domain=<zone> --phase=<phase> --expression=<filter> --action=<action> [...]` | Add the rule or update the one with the same description/expression |
| `rule update --domain=<zone> --phase=<phase> --id=<rule-id> [--expression=] [--action=] [--action-parameters=] [--description=] [--enabled=]` | Update a rule |
| `rule delete --domain=<zone> --phase=<phase> (--id=<rule-id> \| --description=<text>)` | Delete a rule |
| `rule enable --domain=<zone> --phase=<phase> (--id=<rule-id> \| --description=<text>)` | Enable a rule |
| `rule disable --domain=<zone> --phase=<phase> (--id=<rule-id> \| --description=<text>)` | Disable a rule |
| `rule apply --domain=<zone> --phase=<phase> --file=<rules.json>` | Replace all rules of a phase with the given list (declarative) |
| `rule export --domain=<zone> --phase=<phase>` | Export the rules of a phase as JSON (input for 'rule apply') |

#### `redirect`

| Command | Description |
|---|---|
| `redirect list --domain=<zone>` | List single redirects |
| `redirect create --domain=<zone> --from=<path\|url\|host> --to=<url> [--status=301] [--preserve-query] [--preserve-path] [--match=exact\|prefix\|wildcard\|regex] [--description=<text>]` | Create a single redirect (a '*' in the host or path of --from matches as a wildcard; a query string in --from is ignored) |
| `redirect upsert --domain=<zone> --from=<path\|url\|host> --to=<url> [--status=301] [...]` | Create or update the redirect for --from (idempotent) |
| `redirect update --domain=<zone> --id=<rule-id> [--to=] [--status=] [--enabled=] [--description=]` | Update a redirect |
| `redirect delete --domain=<zone> (--id=<rule-id> \| --from=<path\|url\|host> \| --description=<text>)` | Delete a redirect |
| `redirect enable --domain=<zone> (--id=<rule-id> \| --from=<path> \| --description=<text>)` | Enable a redirect |
| `redirect disable --domain=<zone> (--id=<rule-id> \| --from=<path> \| --description=<text>)` | Disable a redirect |

#### `firewall`

| Command | Description |
|---|---|
| `firewall list --domain=<zone>` | List custom firewall (WAF) rules |
| `firewall create --domain=<zone> --action=block\|challenge\|js_challenge\|managed_challenge\|log\|skip (--expression=<filter> \| --countries=CN,RU --ips=<a,b> --asns=<n,n> --paths=<a,b> --hosts=<a,b> --methods=<a,b> --user-agents=<a,b>) [--not] [--description=<text>]` | Create a custom firewall rule |
| `firewall upsert --domain=<zone> --action=<action> --expression=<filter> [--description=<text>]` | Create or update the rule with the same description/expression |
| `firewall update --domain=<zone> --id=<rule-id> [--action=] [--expression=] [--description=] [--enabled=]` | Update a custom firewall rule |
| `firewall delete --domain=<zone> (--id=<rule-id> \| --description=<text>)` | Delete a custom firewall rule |
| `firewall enable --domain=<zone> (--id=<rule-id> \| --description=<text>)` | Enable a custom firewall rule |
| `firewall disable --domain=<zone> (--id=<rule-id> \| --description=<text>)` | Disable a custom firewall rule |

#### `ratelimit`

| Command | Description |
|---|---|
| `ratelimit list --domain=<zone>` | List rate limiting rules |
| `ratelimit create --domain=<zone> --expression=<filter> --requests=<n> [--period=10] [--timeout=10] [--action=block\|managed_challenge\|log] [--characteristics=ip.src,cf.colo.id] [--description=<text>]` | Create a rate limiting rule |
| `ratelimit upsert --domain=<zone> --expression=<filter> --requests=<n> [...]` | Create or update the rate limiting rule |
| `ratelimit delete --domain=<zone> (--id=<rule-id> \| --description=<text>)` | Delete a rate limiting rule |
| `ratelimit enable --domain=<zone> (--id=<rule-id> \| --description=<text>)` | Enable a rate limiting rule |
| `ratelimit disable --domain=<zone> (--id=<rule-id> \| --description=<text>)` | Disable a rate limiting rule |

#### `transform`

| Command | Description |
|---|---|
| `transform list --domain=<zone> [--kind=url\|request-headers\|response-headers]` | List transform rules |
| `transform url --domain=<zone> --expression=<filter> (--path=<static> \| --path-expression=<expr>) [--query=<static> \| --query-expression=<expr>] [--description=<text>]` | Create/update a URL rewrite rule |
| `transform request-header --domain=<zone> --expression=<filter> [--set=Name=Value] [--headers=<json>] [--remove=Name,Name] [--description=<text>]` | Create/update a request header modification rule |
| `transform response-header --domain=<zone> --expression=<filter> [--set=Name=Value] [--headers=<json>] [--remove=Name,Name] [--description=<text>]` | Create/update a response header modification rule |
| `transform delete --domain=<zone> --kind=url\|request-headers\|response-headers (--id=<rule-id> \| --description=<text>)` | Delete a transform rule |

#### `cache-rule`

| Command | Description |
|---|---|
| `cache-rule list --domain=<zone>` | List cache rules |
| `cache-rule create --domain=<zone> --expression=<filter> [--cache=true\|false] [--edge-ttl=<sec>\|respect\|bypass] [--browser-ttl=<sec>\|respect\|bypass] [--action-parameters=<json>] [--description=<text>]` | Create a cache rule |
| `cache-rule upsert --domain=<zone> --expression=<filter> [...]` | Create or update a cache rule |
| `cache-rule delete --domain=<zone> (--id=<rule-id> \| --description=<text>)` | Delete a cache rule |

#### `config-rule`

| Command | Description |
|---|---|
| `config-rule list --domain=<zone>` | List configuration rules |
| `config-rule create --domain=<zone> --expression=<filter> [--ssl=strict] [--security-level=high] [--rocket-loader=false] [--settings=<json>] [--description=<text>]` | Create a configuration rule |
| `config-rule upsert --domain=<zone> --expression=<filter> [...]` | Create or update a configuration rule |
| `config-rule delete --domain=<zone> (--id=<rule-id> \| --description=<text>)` | Delete a configuration rule |

#### `origin-rule`

| Command | Description |
|---|---|
| `origin-rule list --domain=<zone>` | List origin rules |
| `origin-rule create --domain=<zone> --expression=<filter> [--host-header=<host>] [--origin-host=<host>] [--origin-port=<port>] [--sni=<host>] [--description=<text>]` | Create an origin rule |
| `origin-rule upsert --domain=<zone> --expression=<filter> [...]` | Create or update an origin rule |
| `origin-rule delete --domain=<zone> (--id=<rule-id> \| --description=<text>)` | Delete an origin rule |

#### `pagerule`

| Command | Description |
|---|---|
| `pagerule list --domain=<zone> [--status=active\|disabled]` | List Page Rules |
| `pagerule get --domain=<zone> (--id=<rule-id> \| --url=<pattern>)` | Show one Page Rule |
| `pagerule create --domain=<zone> --url=<pattern> (--forward-to=<url> [--status-code=301] \| --cache-level=<v> \| --always-use-https \| --ssl=<v> \| --edge-cache-ttl=<s> \| --browser-cache-ttl=<s> \| --actions=<json> ...) [--priority=<n>] [--status=active\|disabled]` | Create a Page Rule |
| `pagerule upsert --domain=<zone> --url=<pattern> [actions...] [--priority=<n>] [--status=active\|disabled]` | Create or replace the Page Rule for the URL pattern (keeps the existing priority/status unless given) |
| `pagerule update --domain=<zone> --id=<rule-id> [--url=<pattern>] [actions...] [--priority=<n>] [--status=<v>]` | Update a Page Rule |
| `pagerule delete --domain=<zone> (--id=<rule-id> \| --url=<pattern>)` | Delete a Page Rule |
| `pagerule enable --domain=<zone> (--id=<rule-id> \| --url=<pattern>)` | Enable a Page Rule |
| `pagerule disable --domain=<zone> (--id=<rule-id> \| --url=<pattern>)` | Disable a Page Rule |
| `pagerule redirect --domain=<zone> --url=<pattern> --to=<url> [--status-code=301]` | Shortcut: forwarding-URL Page Rule (create or update) |

#### `ssl`

| Command | Description |
|---|---|
| `ssl status --domain=<zone>` | Overview of the SSL/TLS configuration |
| `ssl mode --domain=<zone> [off\|flexible\|full\|strict]` | Get or set the SSL/TLS encryption mode |
| `ssl min-tls --domain=<zone> [1.0\|1.1\|1.2\|1.3]` | Get or set the minimum TLS version |
| `ssl tls13 --domain=<zone> [on\|off\|zrt]` | Get or set TLS 1.3 |
| `ssl always-https --domain=<zone> [on\|off]` | Get or set Always Use HTTPS |
| `ssl auto-rewrites --domain=<zone> [on\|off]` | Get or set Automatic HTTPS Rewrites |
| `ssl opportunistic-encryption --domain=<zone> [on\|off]` | Get or set Opportunistic Encryption |
| `ssl hsts --domain=<zone> [--max-age=31536000] [--include-subdomains] [--preload] [--nosniff] \| --disable` | Get or set HTTP Strict Transport Security |
| `ssl universal --domain=<zone> [on\|off]` | Get or set Universal SSL |
| `ssl verification --domain=<zone>` | Show certificate verification status |
| `ssl certificates --domain=<zone>` | List certificate packs (edge certificates) |
| `ssl origin-cert-list --domain=<zone>` | List Origin CA certificates |
| `ssl origin-cert-create --hostnames=<a,b> [--validity=5475] [--type=origin-rsa\|origin-ecc] [--csr=@file] [--key-out=<file>] [--cert-out=<file>]` | Create an Origin CA certificate (generates a key + CSR with openssl when --csr is omitted) |
| `ssl origin-cert-get --id=<certificate-id>` | Show an Origin CA certificate |
| `ssl origin-cert-revoke --id=<certificate-id>` | Revoke an Origin CA certificate |

#### `dnssec`

| Command | Description |
|---|---|
| `dnssec status --domain=<zone>` | Show DNSSEC status and DS record |
| `dnssec enable --domain=<zone>` | Enable DNSSEC (returns the DS record for the registrar) |
| `dnssec disable --domain=<zone>` | Disable DNSSEC |

#### `workers`

| Command | Description |
|---|---|
| `workers list [--account-id=<id>]` | List Worker scripts |
| `workers upload --name=<script> --file=<worker.js> [--module=true\|false] [--compatibility-date=<date>] [--compatibility-flags=a,b] [--kv=BINDING=<namespace-id>] [--vars=<json>] [--bindings=<json>]` | Upload (create or update) a Worker script |
| `workers download --name=<script> [--file=<path>]` | Download a Worker script |
| `workers delete --name=<script> [--force]` | Delete a Worker script |
| `workers secret-list --name=<script>` | List the secrets of a Worker |
| `workers secret-set --name=<script> --secret-name=<NAME> (--secret-value=<v> \| --from-env=<VAR>)` | Set a secret on a Worker |
| `workers secret-delete --name=<script> --secret-name=<NAME>` | Delete a Worker secret |
| `workers schedules --name=<script> [--crons='*/5 * * * *,0 0 * * *']` | Get or set the cron triggers of a Worker |
| `workers subdomain --name=<script> [on\|off]` | Get or toggle the workers.dev URL of a Worker |
| `workers account-subdomain [--subdomain=<name>]` | Get or set the account workers.dev subdomain |
| `workers routes --domain=<zone>` | List Worker routes of a zone |
| `workers route-create --domain=<zone> --pattern=<pattern> --script=<name>` | Create a Worker route |
| `workers route-upsert --domain=<zone> --pattern=<pattern> --script=<name>` | Create or update the route for a pattern |
| `workers route-delete --domain=<zone> (--id=<route-id> \| --pattern=<pattern>)` | Delete a Worker route |

#### `kv`

| Command | Description |
|---|---|
| `kv list` | List KV namespaces |
| `kv create --title=<name>` | Create a KV namespace |
| `kv delete --namespace=<id\|title>` | Delete a KV namespace |
| `kv keys --namespace=<id\|title> [--prefix=<p>]` | List the keys of a namespace |
| `kv get --namespace=<id\|title> --key=<key>` | Read a value |
| `kv put --namespace=<id\|title> --key=<key> (--value=<v> \| --file=<path>) [--ttl=<seconds>] [--metadata=<json>]` | Write a value |
| `kv delete-key --namespace=<id\|title> --key=<key>` | Delete a key |
| `kv bulk-put --namespace=<id\|title> --file=<items.json>` | Write many key/value pairs ([{key,value,...}]) |
| `kv bulk-delete --namespace=<id\|title> --keys=<a,b> \| --file=<keys.json>` | Delete many keys |

#### `pages`

| Command | Description |
|---|---|
| `pages list` | List Pages projects |
| `pages get --project=<name>` | Show a Pages project |
| `pages create --project=<name> [--production-branch=main]` | Create a Pages project (direct upload) |
| `pages delete --project=<name>` | Delete a Pages project |
| `pages deployments --project=<name> [--env=production\|preview]` | List deployments |
| `pages deploy --project=<name> [--branch=<branch>] [--dir=<build-dir>] [--commit-message=<text>]` | Trigger a build (git projects) or upload --dir with wrangler |
| `pages deployment --project=<name> --deployment=<id>` | Show a deployment |
| `pages logs --project=<name> --deployment=<id>` | Show deployment build logs |
| `pages retry --project=<name> --deployment=<id>` | Retry a deployment |
| `pages rollback --project=<name> --deployment=<id>` | Roll back production to a deployment |
| `pages delete-deployment --project=<name> --deployment=<id> [--force]` | Delete a deployment |
| `pages domains --project=<name>` | List custom domains |
| `pages domain-add --project=<name> --name=<hostname> [--dns]` | Add a custom domain (--dns also creates the CNAME record) |
| `pages domain-delete --project=<name> --name=<hostname>` | Remove a custom domain |
| `pages purge-build-cache --project=<name>` | Purge the build cache |

#### `tunnel`

| Command | Description |
|---|---|
| `tunnel list [--name=<filter>] [--include-deleted]` | List tunnels |
| `tunnel get (--name=<tunnel> \| --id=<tunnel-id>)` | Show a tunnel |
| `tunnel create --name=<tunnel> [--secret=<base64>]` | Create a remotely-managed tunnel (prints the connector token) |
| `tunnel delete (--name=<tunnel> \| --id=<tunnel-id>) [--force]` | Delete a tunnel (--force cleans up active connections first) |
| `tunnel token (--name=<tunnel> \| --id=<tunnel-id>)` | Print the connector token (cloudflared tunnel run --token ...) |
| `tunnel config (--name=<tunnel> \| --id=<tunnel-id>)` | Show the remote ingress configuration |
| `tunnel config-set (--name=<tunnel> \| --id=<tunnel-id>) (--ingress=host=service,... \| --file=<config.json>)` | Replace the remote ingress configuration |
| `tunnel route (--name=<tunnel> \| --id=<tunnel-id>) --hostname=<host> [--service=<url>]` | Publish a hostname: DNS CNAME to the tunnel (+ ingress entry when --service is given) |
| `tunnel connections (--name=<tunnel> \| --id=<tunnel-id>)` | List active connections |
| `tunnel cleanup (--name=<tunnel> \| --id=<tunnel-id>)` | Clean up stale connections |

#### `email`

| Command | Description |
|---|---|
| `email status --domain=<zone>` | Show Email Routing status |
| `email enable --domain=<zone>` | Enable Email Routing (adds the required DNS records) |
| `email disable --domain=<zone>` | Disable Email Routing |
| `email dns --domain=<zone>` | Show the DNS records Email Routing needs |
| `email rules --domain=<zone>` | List routing rules |
| `email rule-create --domain=<zone> --to=<address> (--forward=<dest,dest> \| --drop \| --worker=<name>) [--name=<text>] [--priority=<n>]` | Create a routing rule |
| `email rule-upsert --domain=<zone> --to=<address> (--forward=<dest> \| --drop \| --worker=<name>)` | Create or update the rule for an address |
| `email rule-delete --domain=<zone> (--id=<rule-id> \| --to=<address>)` | Delete a routing rule |
| `email catch-all --domain=<zone> [--forward=<dest> \| --drop \| --worker=<name>] [--disable]` | Get or set the catch-all rule |
| `email addresses` | List destination addresses (account) |
| `email address-add --email=<address>` | Add a destination address (sends a verification email) |
| `email address-delete (--email=<address> \| --id=<address-id>)` | Delete a destination address |

#### `turnstile`

| Command | Description |
|---|---|
| `turnstile list` | List Turnstile widgets |
| `turnstile get --sitekey=<key>` | Show a widget (includes the secret) |
| `turnstile create --name=<text> --domains=<a,b> [--mode=managed\|non-interactive\|invisible] [--bot-fight-mode] [--region=world]` | Create a widget |
| `turnstile update --sitekey=<key> [--name=] [--domains=] [--mode=] [--bot-fight-mode=]` | Update a widget |
| `turnstile delete --sitekey=<key>` | Delete a widget |
| `turnstile rotate-secret --sitekey=<key> [--invalidate-immediately]` | Rotate the widget secret |

#### `r2`

| Command | Description |
|---|---|
| `r2 list [--name-contains=<text>]` | List R2 buckets |
| `r2 get --bucket=<name>` | Show a bucket |
| `r2 create --bucket=<name> [--location=wnam\|enam\|weur\|eeur\|apac\|oc] [--storage-class=Standard\|InfrequentAccess]` | Create a bucket |
| `r2 delete --bucket=<name>` | Delete a bucket (must be empty) |
| `r2 cors --bucket=<name> [--file=<rules.json> \| --delete]` | Get, set or delete the CORS policy |
| `r2 domains --bucket=<name>` | List custom domains of a bucket |
| `r2 domain-add --bucket=<name> --name=<hostname> [--domain=<zone>] [--min-tls=1.2]` | Attach a custom domain (zone must be on Cloudflare) |
| `r2 domain-delete --bucket=<name> --name=<hostname>` | Detach a custom domain |
| `r2 public --bucket=<name> [on\|off]` | Get or toggle the public r2.dev domain |

#### `account`

| Command | Description |
|---|---|
| `account list` | List accounts visible to the token |
| `account get [--account-id=<id>]` | Show account details |
| `account id [--domain=<zone>]` | Print the resolved account ID |

#### `user`

| Command | Description |
|---|---|
| `user get` | Show the user of the token (global API key auth only) |

#### `token`

| Command | Description |
|---|---|
| `token verify` | Verify the API token and show its status |

#### `ip`

| Command | Description |
|---|---|
| `ip list [--ipv4] [--ipv6]` | List Cloudflare's IP ranges (for origin firewalls) |

#### `list`

| Command | Description |
|---|---|
| `list list` | List account lists |
| `list get (--name=<list> \| --id=<list-id>)` | Show a list |
| `list create --name=<list> --kind=ip\|asn\|hostname\|redirect [--description=<text>]` | Create a list |
| `list delete (--name=<list> \| --id=<list-id>)` | Delete a list |
| `list items (--name=<list> \| --id=<list-id>)` | Show the items of a list |
| `list add (--name=<list> \| --id=<list-id>) (--items=<a,b> \| --file=<items.json>)` | Add items (IPs, ASNs, hostnames or redirect objects) |
| `list remove (--name=<list> \| --id=<list-id>) --items=<a,b>` | Remove items by value |
| `list replace (--name=<list> \| --id=<list-id>) --file=<items.json>` | Replace all items |

#### `bulk-redirect`

| Command | Description |
|---|---|
| `bulk-redirect list --list=<name>` | Show the redirects in a redirect list |
| `bulk-redirect add --list=<name> --from=<url> --to=<url> [--status=301] [--include-subdomains] [--subpath-matching] [--preserve-query] [--preserve-path-suffix]` | Add a redirect to a list (creates the list when missing) |
| `bulk-redirect remove --list=<name> --from=<url>` | Remove a redirect from a list |
| `bulk-redirect enable --list=<name>` | Create/enable the account Bulk Redirect rule for a list |
| `bulk-redirect disable --list=<name>` | Disable the Bulk Redirect rule for a list |

#### `web-analytics`

| Command | Description |
|---|---|
| `web-analytics list` | List Web Analytics sites |
| `web-analytics create --host=<hostname> [--domain=<zone>] [--auto-install]` | Create a Web Analytics site (returns the JS snippet token) |
| `web-analytics delete --site=<site-tag>` | Delete a Web Analytics site |

#### `analytics`

| Command | Description |
|---|---|
| `analytics zone --domain=<zone> [--days=7]` | Daily traffic summary for the last N days (requests, bytes, threats, page views, uniques) |
| `analytics firewall --domain=<zone> [--days=1]` | Firewall events summary grouped by action and source |
| `analytics query --query=<graphql\|@file> [--variables=<json>]` | Run a raw GraphQL Analytics query |

#### `api`

| Command | Description |
|---|---|
| `api request <METHOD> <path> [--data=<json\|@file>] [--query=a=b&c=d] [--paginate]` | Call any Cloudflare API endpoint (e.g. api GET /zones) |

#### `batch`

| Command | Description |
|---|---|
| `batch run (--file=<commands.txt> \| --stdin \| --commands=<multi-line>) [--continue-on-error]` | Run many commands (one per line, # comments allowed) |

## GitHub Action

Octoflare ships an `action.yml`, so any workflow can run it with `uses:`. Modules are part of the
checkout, nothing is downloaded, and `curl`/`jq` are present on all GitHub-hosted runners (they
would be installed automatically otherwise).

```yaml
jobs:
  cloudflare:
    runs-on: ubuntu-latest
    steps:
      - name: Point www at the new host
        id: dns
        uses: octoleo/octoflare@master
        with:
          api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          domain: ${{ vars.CLOUDFLARE_DOMAIN }}
          command: dns upsert --name=www --type=A --content=203.0.113.10 --proxied

      - run: echo "record ${{ steps.dns.outputs.id }} in zone ${{ steps.dns.outputs.zone-id }}"
```

Several changes in one step (batch mode; stops at the first failure unless
`continue-on-error: true`):

```yaml
      - uses: octoleo/octoflare@master
        with:
          api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          domain: ${{ vars.CLOUDFLARE_DOMAIN }}
          commands: |
            dns upsert --name=app --type=CNAME --content=app.pages.dev --proxied
            redirect upsert --from=/old --to=https://example.com/new --status=301
            ssl mode strict
            cache purge --everything
```

Credentials can also come from the environment (`env: CLOUDFLARE_API_TOKEN: ...`) or from a
`.env` file in the repository (`env-file: .octoflare`, values never override secrets).

### Inputs

| Input | Description | Default |
|---|---|---|
| `command` | One Octoflare command line | |
| `commands` | Several commands, one per line (batch mode) | |
| `api-token` | Cloudflare API token (or env `CLOUDFLARE_API_TOKEN`) | |
| `account-id`, `zone-id`, `domain` | Account / zone defaults | |
| `email`, `api-key` | Legacy global API key authentication | |
| `origin-ca-key` | Origin CA key for `ssl origin-cert-*` | |
| `env-file` | `.env` file in the repository to load | |
| `output` | `json` or `text` | `json` |
| `field` | jq expression applied to the result (`.id`) | |
| `dry-run` | Preview the requests | `false` |
| `continue-on-error` | Batch: keep going after a failure | `false` |
| `quiet`, `debug` | Logging | `false` |
| `timeout`, `retries` | HTTP tuning | `60`, `3` |
| `working-directory` | Directory to run in | `.` |

### Outputs

| Output | Description |
|---|---|
| `result` | JSON result of the command (or the `field` value); batch: `{total, succeeded, failed, results}` |
| `id` | ID of the created/updated object when the result has one |
| `zone-id`, `zone-name`, `account-id` | Resolved identifiers |
| `exit-code` | Octoflare exit code |
| `failed` | Batch mode: number of failed commands |

Errors are surfaced as `::error::` annotations and tokens are masked in the logs.
More complete workflows (subdomains, redirects, Under Attack mode, cache purge after deploy,
Pages custom domains, batch provisioning) live in [`examples/workflows`](examples/workflows).

### Without the action

Any CI system can use the installer:

```yaml
- run: curl -fsSL https://raw.githubusercontent.com/octoleo/octoflare/master/install.sh | bash
- run: octoflare dns upsert --name=www.example.com --type=A --content=203.0.113.10 --json
  env:
    CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

`CI=true` switches on unattended mode automatically.

## Batch files

A batch file holds one command per line (`#` comments allowed). Options given to `batch run`
apply to every line, and the run stops at the first failure unless `--continue-on-error` is set:

```shell
octoflare batch run --domain=example.com --file=examples/batch/site.txt
octoflare batch run --domain=example.com --stdin <<'EOT'
dns upsert --name=@ --type=A --content=203.0.113.10 --proxied
ssl always-https on
EOT
```

The result lists every command with its exit code and output; the exit code is non-zero when any
command failed.

## Unattended mode and self-installation

When running under `CI`/`GITHUB_ACTIONS`, with `OCTOFLARE_UNATTENDED=true` or `--unattended`:

* no questions are asked (deletes proceed as if `--yes` was given);
* a missing `curl` or `jq` is installed with the system package manager (apt, dnf, yum, apk,
  pacman, zypper, brew; `sudo -n` when not root); when that is impossible, `jq` falls back to the
  pinned jq 1.7.1 static release whose SHA-256 is verified before use, installed into
  `$OCTOFLARE_HOME/bin` (only used when that directory is private to the current user; `curl`
  has no download fallback). When `HOME`, `XDG_DATA_HOME` and `OCTOFLARE_HOME` are all unset
  Octoflare exits 69 instead of using `/tmp`;
* only an explicitly requested env file is loaded (see above);
* missing modules are downloaded from `https://raw.githubusercontent.com/octoleo/octoflare/<OCTOFLARE_REF>/src/lib/`
  into the first writable of `<script dir>/lib`, `<prefix>/lib/octoflare`, `~/.local/share/octoflare/lib`;
* `octoflare --update` refreshes the script and every module.

Interactively, Octoflare asks before installing anything and refuses destructive commands without
`--yes` when no terminal is attached.

## Development

```shell
shellcheck src/octoflare src/lib/*.sh install.sh scripts/*.sh tests/*.sh   # lint
tests/run.sh                    # bats suite against the mock API (tests/mock_api.py)
tests/run.sh tests/dns.bats     # one file
scripts/bundle.sh               # single-file build in dist/octoflare
```

Layout: `src/octoflare` is a small bootstrap (dependencies, module download, dispatch);
`src/lib/core.sh` holds logging/options/output, `src/lib/api.sh` the transport and zone/account
resolution, and every other module registers its commands with `registerCommand` and implements
them as `cmd_<resource>_<action>` functions. Adding a feature means adding a module file and
listing it in `OCTOFLARE_MODULES`.

## Changes from v1

* Commands are now `<resource> <action>`; the v1 attack-mode flags remain as aliases.
* Informational output moved to stderr; stdout carries results (`--json` for machine use).
* Environment files no longer override variables already set in the environment
  (`OCTOFLARE_ENV_OVERRIDE=true` restores that).
* `--debug` enables verbose logging; on its own it still prints the configuration.
* The default restore level of `attack-mode disable` is `high` (as documented in v1).

### Free Software License

```txt
@copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
@license    GNU General Public License version 2; see LICENSE
```
