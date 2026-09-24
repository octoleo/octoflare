#!/usr/bin/env bats
# Review fixes for the bootstrap (src/octoflare), core.sh dispatcher/self commands and install.sh

load helpers

setup() {
  setup_env
  # the bootstrap helper functions (everything before the "Bootstrap" section runs main)
  export BOOTDEFS="$BATS_TEST_TMPDIR/bootdefs.sh"
  sed -n '1,/^#* Bootstrap$/p' "$OCTOFLARE" > "$BOOTDEFS"
  export CORE="$OCTOFLARE_ROOT/src/lib/core.sh"
  export T="$BATS_TEST_TMPDIR"
}

# boot - run a snippet with the bootstrap helpers loaded (no main, no module loading)
boot() {
  run --separate-stderr bash -c "source \"\$BOOTDEFS\"; $1"
}

@test "bootLog emits ::error and ::warning annotations on stderr under GitHub Actions" {
  boot 'GITHUB_ACTIONS=true bootLog error boom; GITHUB_ACTIONS=true bootLog warn careful; bootLog error plain'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *$'[error] boom\n::error title=Octoflare::boom'* ]]
  [[ "$stderr" == *$'[warn] careful\n::warning title=Octoflare::careful'* ]]
  [ "$(printf '%s\n' "$stderr" | grep -c '^::')" -eq 2 ]
}

@test "bootstrap failures are annotated in GitHub Actions and exit 70" {
  export GITHUB_ACTIONS=true
  # a copy of the bootstrap without modules next to it, an empty lib dir and an unreachable module source
  mkdir -p "$T/bin" && cp "$OCTOFLARE" "$T/bin/octoflare"
  run --separate-stderr env OCTOFLARE_LIB_DIR="$T/emptylib" OCTOFLARE_RAW_BASE=http://127.0.0.1:1 "$T/bin/octoflare" version
  [ "$status" -eq 70 ]
  [[ "$stderr" == *'Failed to download module "core"'* ]]
  [[ "$stderr" == *'::error title=Octoflare::Failed to download module'* ]]
}

@test "download passes connect and total timeouts to curl and wget" {
  boot 'curl() { printf "%s " "$@"; echo; }; download http://x /dev/null; OCTOFLARE_TIMEOUT=7 download http://x /dev/null
        hasCmd() { [ "$1" = wget ]; }; wget() { printf "%s " "$@"; echo; }; download http://x /dev/null'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"--connect-timeout 15 --max-time 60 -o /dev/null http://x"* ]]
  [[ "${lines[1]}" == *"--connect-timeout 15 --max-time 7 -o /dev/null http://x"* ]]
  [[ "${lines[2]}" == *"--timeout=15 --tries=3 -O /dev/null http://x"* ]]
}

@test "octoflareHome never falls back to /tmp" {
  boot 'unset HOME XDG_DATA_HOME OCTOFLARE_HOME; octoflareHome; echo never'
  [ "$status" -eq 69 ]
  [ -z "$output" ]
  [[ "$stderr" == *"HOME, XDG_DATA_HOME and OCTOFLARE_HOME are all unset"* ]]
  boot 'OCTOFLARE_HOME=/o/ octoflareHome; XDG_DATA_HOME=/x/data HOME=/h octoflareHome; unset XDG_DATA_HOME; HOME=/h octoflareHome'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "/o" ]
  [ "${lines[1]}" = "/x/data/octoflare" ]
  [ "${lines[2]}" = "/h/.local/share/octoflare" ]
  # end to end: a command that needs the data directory dies with the clear message
  run --separate-stderr env -u HOME -u XDG_DATA_HOME -u OCTOFLARE_HOME "$OCTOFLARE" self path
  [ "$status" -eq 69 ]
  [[ "$stderr" == *"set OCTOFLARE_HOME"* ]]
  [[ "$stderr" != *"/tmp"*"octoflare"* ]] || [[ "$stderr" == *"/tmp is not used"* ]]
}

@test "the per-user bin directory joins PATH only when it is private" {
  mkdir -p "$T/home/bin"
  printf '#!/bin/sh\necho frob-ok\n' > "$T/home/bin/frob"
  chmod +x "$T/home/bin/frob"
  chmod 700 "$T/home/bin"
  boot 'dirIsPrivate "$T/home/bin" && echo private; dirIsPrivate /tmp || echo tmp-rejected
        installPackage() { return 1; }; OCTOFLARE_HOME="$T/home"; ensureDependency frob && frob'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "private" ]
  [ "${lines[1]}" = "tmp-rejected" ]
  [ "${lines[2]}" = "frob-ok" ]
  chmod 775 "$T/home/bin"
  boot 'dirIsPrivate "$T/home/bin" || echo group-writable-rejected
        installPackage() { return 1; }; OCTOFLARE_HOME="$T/home"; ensureDependency frob; echo never'
  [ "$status" -eq 69 ]
  [ "${lines[0]}" = "group-writable-rejected" ]
  [[ "$stderr" == *"Ignoring ${T}/home/bin"* ]]
  [[ "$stderr" == *'[error] Unable to install "frob"'* ]]
}

@test "ensureDependency optional mode warns and returns 1 instead of exiting" {
  boot 'installPackage() { return 1; }; ensureDependency frob frob optional; echo "rc=$?"
        OCTOFLARE_UNATTENDED=false ensureDependency frob frob optional </dev/null; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "rc=1" ]
  [ "${lines[1]}" = "rc=1" ]
  [[ "$stderr" == *'[warn] Unable to install "frob"'* ]]
  [[ "$stderr" == *'[warn] Missing dependency "frob"'* ]]
  [[ "$stderr" != *"[error]"* ]]
  boot 'hasCmd() { [ "$1" != curl ] && command -v "$1" >/dev/null 2>&1; }; installPackage() { return 1; }; ensureDependency curl; echo never'
  [ "$status" -eq 69 ]
  [ -z "$output" ]
  [[ "$stderr" == *"install it with your package manager"* ]]
}

@test "static jq is pinned to 1.7.1 and verified against the embedded checksum; no static curl" {
  boot 'echo "$OCTOFLARE_JQ_BASE"; jqStaticAsset linux-x86_64; jqStaticAsset linux-aarch64; jqStaticAsset darwin-arm64; jqStaticAsset freebsd-amd64 || echo unknown'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "https://github.com/jqlang/jq/releases/download/jq-1.7.1" ]
  [ "${lines[1]}" = "jq-linux-amd64 5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5" ]
  [ "${lines[2]}" = "jq-linux-arm64 4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5" ]
  [ "${lines[3]}" = "jq-macos-arm64 0bbe619e663e0de2c550be2fe0d240d076799d6f8a652b70fa04aea8a8362e8a" ]
  [ "${lines[4]}" = "unknown" ]
  ! grep -q 'static-curl\|releases/latest/download' "$OCTOFLARE"
  # a download whose checksum does not match is discarded
  boot 'OCTOFLARE_HOME="$T/home"; uname() { case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac; }
        download() { printf "not jq" > "$2"; }; installStaticBinary jq; echo "rc=$?"; ls "$T/home/bin"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "rc=1" ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$stderr" == *"Checksum mismatch for https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"* ]]
  [[ "$stderr" == *"Refusing to install"* ]]
  # a matching checksum installs the binary, makes it executable and puts its private dir on PATH
  boot 'OCTOFLARE_HOME="$T/home"; uname() { case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac; }
        FAKE_SHA="$(printf "fake jq" | sha256sum | cut -d" " -f1)"
        download() { printf "fake jq" > "$2"; }; jqStaticAsset() { echo "jq-linux-amd64 $FAKE_SHA"; }
        installStaticBinary jq && echo installed; command -v jq; ls -ld "$T/home/bin" | cut -c1-10'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "installed" ]
  [ "${lines[1]}" = "$T/home/bin/jq" ]
  [ "${lines[2]}" = "drwxr-xr-x" ]
  [ -x "$T/home/bin/jq" ]
  [ ! -e "$T/home/bin/jq.download."* ]
  boot 'installStaticBinary curl; echo "rc=$?"'
  [ "${lines[0]}" = "rc=1" ]
  [[ "$stderr" == *"curl is only installed from the package manager"* ]]
}

@test "self install-deps treats openssl as optional" {
  run --separate-stderr bash -c 'source "$BOOTDEFS"; source "$CORE"
    hasCmd() { [ "$1" != openssl ] && command -v "$1" >/dev/null 2>&1; }
    installPackage() { return 1; }
    OCTOFLARE_OUTPUT=json cmd_self_install_deps; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "rc=0" ]
  printf '%s' "${lines[0]}" | jq -e '.success == true and .openssl == false' >/dev/null
  [[ "$stderr" == *"[warn] openssl is not installed"* ]]
  [[ "$stderr" != *"[error]"* ]]
}

@test "self uninstall refuses to remove /, HOME, a parent of HOME or a directory not named octoflare" {
  run bash -c 'source "$BOOTDEFS"; source "$CORE"; HOME=/home/u
    for h in / /home/u /home/u/ /home "" /home/u/octoflare/ /home/u/.local/share/octoflare /var/lib/octoflare /opt/octoflare-data; do
      if uninstallHomeIsSafe "$h"; then echo "SAFE $h"; else echo "REFUSE $h"; fi
    done'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "REFUSE /" ]
  [ "${lines[1]}" = "REFUSE /home/u" ]
  [ "${lines[2]}" = "REFUSE /home/u/" ]
  [ "${lines[3]}" = "REFUSE /home" ]
  [ "${lines[4]}" = "REFUSE " ]
  [ "${lines[5]}" = "REFUSE /home/u/octoflare/" ]
  [ "${lines[6]}" = "SAFE /home/u/.local/share/octoflare" ]
  [ "${lines[7]}" = "SAFE /var/lib/octoflare" ]
  [ "${lines[8]}" = "REFUSE /opt/octoflare-data" ]
  # the command keeps an unsafe OCTOFLARE_HOME even in unattended mode (rm is stubbed as a safety net)
  mkdir -p "$T/keep" "$T/data/octoflare"
  run --separate-stderr bash -c 'source "$BOOTDEFS"; source "$CORE"
    rm() { echo "rm $*"; }; sudoCmd() { :; }; installedScriptPath() { echo /nonexistent/octoflare; }
    OCTOFLARE_LIB_DIR=""; OCTOFLARE_HOME="$T/keep" cmd_self_uninstall; OCTOFLARE_HOME="$T/data/octoflare" cmd_self_uninstall'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Not removing ${T}/keep"* ]]
  [[ "$output" != *"rm -rf ${T}/keep"* ]]
  [[ "$output" == *"rm -rf ${T}/data/octoflare"* ]]
  [ -d "$T/keep" ]
}

@test "--env belongs to a command that declares it; -e and --env-file always name the env file" {
  printf 'CLOUDFLARE_ACCOUNT_ID=acc-file\n' > vars.env
  octo pages deployments --project=site --env=production --account-id=acc --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[dry-run] GET "*"/accounts/acc/pages/projects/site/deployments?env=production"* ]]
  [[ "$stderr" != *"Environment file"* ]]
  octo pages deployments --project=site --env=production -e vars.env --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"/accounts/acc-file/pages/projects/site/deployments?env=production"* ]]
  octo pages deployments --project=site --env=preview --env-file=vars.env --dry-run --json
  [[ "$stderr" == *"/accounts/acc-file/pages/projects/site/deployments?env=preview"* ]]
  # other commands keep --env=<file> as the env file
  octo config show --env=vars.env --field=.account_id
  [ "$output" = "acc-file" ]
  octo config show -e=vars.env --field=.account_id
  [ "$output" = "acc-file" ]
  octo config show --env-file=vars.env --field=.account_id
  [ "$output" = "acc-file" ]
  octo config show --env-file=missing.env
  [ "$status" -eq 2 ]
  octo config show -e
  [ "$status" -eq 3 ]
  [[ "$stderr" == *'"-e" requires a non-empty option argument'* ]]
}

@test "install.sh downloads are bounded in time and HOME is never expanded unguarded" {
  run bash -c "$(sed -n '/^hasCmd()/p;/^download()/,/^}/p' "$OCTOFLARE_ROOT/install.sh"); curl() { printf '%s ' \"\$@\"; echo; }; download http://x /dev/null; OCTOFLARE_TIMEOUT=9 download http://x /dev/null"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"--connect-timeout 15 --max-time 60 -o /dev/null http://x"* ]]
  [[ "${lines[1]}" == *"--max-time 9 "* ]]
  grep -q -- '--timeout=15 --tries=3' "$OCTOFLARE_ROOT/install.sh"
  ! grep -q '\${HOME}' "$OCTOFLARE_ROOT/install.sh"
  grep -q 'HOME is unset' "$OCTOFLARE_ROOT/install.sh"
  bash -n "$OCTOFLARE_ROOT/install.sh"
}
