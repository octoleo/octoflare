<h2><img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png" >
Octoflare - Toggle Cloudflare "Under Attack Mode" from the CLI.
</h2>

Written by Llewellyn van der Merwe (@llewellynvdm)

A simple CLI utility to enable, disable, or check the status of Cloudflare's "Under Attack Mode" (IUAM) for a specific domain.
Uses the Cloudflare v4 API and supports custom `.env` locations.

Linted by [#ShellCheck](https://github.com/koalaman/shellcheck)

## Install

```shell
$ sudo curl -L "https://raw.githubusercontent.com/octoleo/octoflare/refs/heads/master/src/octoflare" -o /usr/local/bin/octoflare
$ sudo chmod +x /usr/local/bin/octoflare
````

* Global **environment** file can be set at: `/home/$USER/.config/octoflare/.env`
* OR/And use the `--env=/path/to/.env` flag to load a project-specific env file.

**Environment File (.env):**

```txt
CLOUDFLARE_API_TOKEN="your-cloudflare-api-token"
CLOUDFLARE_RESTORE_LEVEL="high"
```

* `CLOUDFLARE_API_TOKEN`: Required. Needs [Zone.Zone Settings:Read] and [Zone.Zone Settings:Edit] permissions.
* `CLOUDFLARE_RESTORE_LEVEL`: Optional. Security level to restore after disabling IUAM (default: `under_attack`).

## Usage

> To see the help menu

```shell
$ octoflare -h
```

---

> To update

```shell
$ octoflare --update
```

### Help Menu (Octoflare)

```txt
Usage: octoflare [OPTION...] --domain=example.com

        Options
        ======================================================
        --enable-attack-mode       Enable "Under Attack Mode"
        --disable-attack-mode      Disable "Under Attack Mode"
        --status-attack-mode       Show current security level
        --domain=<domain>          Specify the domain to manage
        -e | --env=<file>          Path to custom .env file
        --update                   Update this script to latest version
        --uninstall                Uninstall this script
        --quiet                    Suppress all output
        --debug                    Show loaded environment variables
        -h | --help                Show this help message
        ======================================================
        Environment Variables
        ======================================================
        CLOUDFLARE_API_TOKEN       Cloudflare API Token (Zone:Read + Zone:Edit)
        CLOUDFLARE_RESTORE_LEVEL   Level to restore when disabling IUAM (default: high)
        ======================================================
                        Octoflare v1.0.0
        ======================================================
```

### Example

Enable **Under Attack Mode** for a domain:

```shell
$ octoflare --enable-attack-mode --domain=example.com
```

Disable and restore to "medium" security level:

```shell
$ CLOUDFLARE_RESTORE_LEVEL=medium octoflare --disable-attack-mode --domain=example.com
```

Check the current security level:

```shell
$ octoflare --status-attack-mode --domain=example.com
```

### Uninstall

```shell
$ octoflare --uninstall
```

### Free Software License

```txt
@copyright  Copyright (C) 2025 Llewellyn van der Merwe. All rights reserved.
@license    GNU General Public License version 2; see LICENSE.txt
```

