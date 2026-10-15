#!/bin/bash
# tailscale-mac-setup.sh
#
# Installs the open-source tailscaled (Homebrew formula) on macOS and enrolls
# the device with a Tailscale auth key. Designed to be run over SSH.
#
#   - Compatible with macOS system bash 3.2 (no bash 4+ features used).
#   - Run it as your admin user (it re-runs itself via sudo) or from a
#     `sudo -i` root shell. Use `ssh -t` so password prompts work.
#   - Homebrew refuses to run as root, so brew commands are run as the admin
#     user via `sudo -u`. If Homebrew is missing, the script asks for approval
#     before installing it.
#
# Usage:
#   ./tailscale-mac-setup.sh [-n hostname] [-s] [-i] [-h]
#     -n NAME   Tailscale device name (default: macmini-<LocalHostName>)
#     -s        Also enable the Tailscale SSH server (--ssh)
#     -i        Install + start the daemon only; do not enroll
#     -h        Show this help
#
# Auth key: set TS_AUTHKEY in the environment, or paste it when prompted
# (input hidden). Never pass the key as a command-line argument.
#
# Docs: https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS
#       https://tailscale.com/docs/concepts/macos-variants

set -eu
set -o pipefail

BREW_INSTALLER_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
TS_HOSTNAME=""
ENABLE_SSH=0
DO_ENROLL=1
ADMIN=""
BREW=""
PFX=""
TS=""

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' | head -n 30
  exit "${1:-0}"
}

# ---------- argument parsing (before any re-exec) ----------
while [ $# -gt 0 ]; do
  case "$1" in
    -n) [ $# -ge 2 ] || die "-n needs a value"; TS_HOSTNAME="$2"; shift 2 ;;
    -s) ENABLE_SSH=1; shift ;;
    -i) DO_ENROLL=0; shift ;;
    -h|--help) usage 0 ;;
    *) warn "unknown option: $1"; usage 1 ;;
  esac
done

# ---------- preflight ----------
[ "$(uname -s)" = "Darwin" ] || die "this script is for macOS only"

# Interactive terminal is required for approval + password prompts.
if ! ( : </dev/tty ) 2>/dev/null; then
  die "no terminal available. Run over 'ssh -t user@host' so prompts work."
fi

# Re-run as root if needed (Homebrew itself is run as the admin user below).
if [ "$(id -u)" -ne 0 ]; then
  [ -f "$0" ] || die "run this from a file (not piped via stdin) so it can re-run with sudo"
  log "Not root; re-running with sudo (you may be asked for your password)"
  exec sudo /bin/bash "$0" "$@"
fi

# ---------- helpers ----------
confirm() {
  # $1 = question. Reads from the terminal. Default is NO.
  printf '%s [y/N]: ' "$1" >/dev/tty
  ans=""
  read -r ans </dev/tty || ans="n"
  case "$ans" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

read_secret() {
  # Reads hidden input from the terminal one character at a time, printing a
  # '*' for each so you can see that typing/pasting registered.
  # Backspace deletes the last character; Enter finishes. Result in $SECRET.
  SECRET=""
  trap 'stty echo </dev/tty 2>/dev/null || true' EXIT
  while IFS= read -rsn1 ch </dev/tty; do
    case "$ch" in
      "") break ;;                                   # Enter
      $'\177'|$'\b')                                 # Backspace / Delete
        if [ -n "$SECRET" ]; then
          SECRET="${SECRET%?}"
          printf '\b \b' >/dev/tty
        fi ;;
      *) SECRET="$SECRET$ch"; printf '*' >/dev/tty ;;
    esac
  done
  printf '\n' >/dev/tty
}

get_auth_key() {
  # Sets $KEY. Uses $TS_AUTHKEY if present, else prompts (masked with '*').
  KEY="${TS_AUTHKEY:-}"
  [ -z "$KEY" ] || log "Using auth key from TS_AUTHKEY environment variable"
  tries=0
  while :; do
    if [ -z "$KEY" ]; then
      printf 'Paste Tailscale auth key (shown as *, Backspace corrects, Enter to finish): ' >/dev/tty
      read_secret
      KEY="$SECRET"; SECRET=""
    fi
    KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"   # strip stray spaces/newlines from paste
    n=${#KEY}
    if [ "$n" -eq 0 ]; then
      warn "nothing was entered"
    else
      case "$KEY" in
        tskey-auth-*)   kind="auth key (good)" ;;
        tskey-api-*)    kind="API access token (NOT an auth key)" ;;
        tskey-client-*) kind="OAuth client secret (NOT an auth key)" ;;
        tskey-*)        kind="tskey-... of unrecognized type" ;;
        *)              kind="unrecognized (does not start with tskey-)" ;;
      esac
      printf '    received %s characters, type: %s\n' "$n" "$kind" >/dev/tty
      case "$KEY" in
        tskey-auth-*|tskey-[!ac]*) return 0 ;;   # accept auth keys (and unknown tskey- types)
        *) warn "that is not an auth key. Generate one at Settings > Keys > Generate auth key." ;;
      esac
    fi
    KEY=""; TS_AUTHKEY=""
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || die "no valid auth key after 3 attempts"
  done
}

run_up() {
  # NOTE: the key is briefly visible in this machine's process list.
  if [ "$ENABLE_SSH" -eq 1 ]; then
    "$TS" up --auth-key="$KEY" --hostname="$TS_HOSTNAME" --timeout=60s --ssh
  else
    "$TS" up --auth-key="$KEY" --hostname="$TS_HOSTNAME" --timeout=60s
  fi
}

detect_admin() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ADMIN="$SUDO_USER"; return 0
  fi
  c="$(stat -f%Su /dev/console 2>/dev/null || true)"
  if [ -n "$c" ] && [ "$c" != "root" ] && [ "$c" != "loginwindow" ]; then
    ADMIN="$c"; return 0
  fi
  printf 'Admin username that owns/will own Homebrew: ' >/dev/tty
  read -r ADMIN </dev/tty
  [ -n "$ADMIN" ] && id "$ADMIN" >/dev/null 2>&1 || die "user '$ADMIN' does not exist"
  [ "$ADMIN" != "root" ] || die "Homebrew cannot be owned by root; use a normal admin user"
}

as_admin() { ( cd /tmp && sudo -u "$ADMIN" -H "$@" ); }

find_brew() {
  BREW=""
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$p" ]; then BREW="$p"; return 0; fi
  done
  return 1
}

backend_state() {
  "$TS" status --json 2>/dev/null \
    | grep -o '"BackendState": *"[A-Za-z]*"' \
    | sed 's/.*: *"\(.*\)"/\1/' | head -n 1 || true
}

# ---------- step 0: prerequisites ----------
detect_admin
log "Admin user for Homebrew: $ADMIN"
dseditgroup -o checkmember -m "$ADMIN" admin >/dev/null 2>&1 \
  || warn "$ADMIN is not in the 'admin' group; Homebrew install may fail"

if [ -d /Applications/Tailscale.app ]; then
  die "Tailscale.app (Standalone/App Store variant) is installed. Tailscale says not to run the variants together: remove the app, empty the Trash, reboot, then re-run."
fi

if find_brew; then
  log "Homebrew found: $BREW"
else
  log "Homebrew is NOT installed."
  cat >/dev/tty <<MSG

Homebrew will be installed for user '$ADMIN' using the official installer:
  $BREW_INSTALLER_URL
It also needs the Xcode Command Line Tools (installed automatically if absent)
and will ask for $ADMIN's sudo password.

MSG
  confirm "Install Homebrew now?" || die "Homebrew is required. Aborting at your request."
  tmpd="$(mktemp -d /tmp/brewinst.XXXXXX)"
  chmod 755 "$tmpd"
  curl -fsSL "$BREW_INSTALLER_URL" -o "$tmpd/install.sh" || { rm -rf "$tmpd"; die "could not download the Homebrew installer"; }
  chmod 644 "$tmpd/install.sh"
  sudo -u "$ADMIN" -H /bin/bash "$tmpd/install.sh" || { rm -rf "$tmpd"; die "Homebrew installer failed"; }
  rm -rf "$tmpd"
  find_brew || die "Homebrew installer finished but brew was not found"
  log "Homebrew installed: $BREW"
fi

PFX="$(as_admin "$BREW" --prefix)"
TS="$PFX/bin/tailscale"

# ---------- step 1: install tailscale + start at boot ----------
if as_admin "$BREW" list --formula tailscale >/dev/null 2>&1; then
  log "tailscale formula already installed"
else
  log "Installing tailscale (brew formula) as $ADMIN"
  as_admin "$BREW" install --formula tailscale || die "brew install tailscale failed"
fi
[ -x "$TS" ] || die "tailscale binary not found at $TS"

log "Starting tailscaled at boot (brew services, as root)"
"$BREW" services start tailscale \
  || die "brew services failed as root. Exit the root shell and run: sudo $BREW services start tailscale"

i=0
while [ "$i" -lt 15 ]; do
  [ -n "$(backend_state)" ] && break
  sleep 2; i=$((i + 1))
done
STATE="$(backend_state)"
[ -n "$STATE" ] || die "tailscaled did not respond after 30s"
log "Daemon is up. BackendState=$STATE"

# ---------- step 2: enroll ----------
if [ "$DO_ENROLL" -eq 1 ]; then
  if [ "$STATE" = "Running" ]; then
    log "Already enrolled (BackendState=Running); skipping enrollment"
  else
    if [ -z "$TS_HOSTNAME" ]; then
      lh="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
      TS_HOSTNAME="macmini-$(printf '%s' "$lh" | tr '[:upper:]' '[:lower:]' | tr ' _' '--' | tr -cd 'a-z0-9-')"
    fi
    while :; do
      get_auth_key
      log "Enrolling as '$TS_HOSTNAME'"
      if run_up; then break; fi
      KEY=""; TS_AUTHKEY=""
      warn "tailscale up failed (key rejected, expired, revoked, or already used?)"
      confirm "Enter a different key and try again?" || die "enrollment failed"
    done
    KEY=""; unset KEY TS_AUTHKEY
  fi
else
  log "Install-only mode (-i): skipping enrollment"
fi

# ---------- step 3: verification ----------
FAILS=0
check() { # $1=label  $2=0|1 (1 = pass)
  if [ "$2" -eq 1 ]; then printf 'PASS  %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); fi
}
echo
log "Verification"
# Newer Homebrew names the label sh.brew.tailscale; older used homebrew.mxcl.tailscale.
PLIST=""
for f in /Library/LaunchDaemons/sh.brew.tailscale.plist /Library/LaunchDaemons/homebrew.mxcl.tailscale.plist; do
  [ -f "$f" ] && PLIST="$f" && break
done
[ -n "$PLIST" ] && p=1 || p=0
check "boot (system) LaunchDaemon present (${PLIST:-none in /Library/LaunchDaemons})" "$p"
fv="$(fdesetup status 2>/dev/null || true)"
case "$fv" in
  *"FileVault is On"*) warn "FileVault is ON: after a reboot the Mac waits at the disk-unlock screen, so Tailscale will NOT start until it is unlocked." ;;
esac
# (count instead of grep -q: early exit + pipefail would give a false FAIL)
nutun="$(ifconfig 2>/dev/null | grep -c '^utun' || true)"
[ "${nutun:-0}" -gt 0 ] && p=1 || p=0
check "utun interface present" "$p"
if [ "$DO_ENROLL" -eq 1 ]; then
  [ "$(backend_state)" = "Running" ] && p=1 || p=0
  check "BackendState=Running" "$p"
  IP4="$("$TS" ip -4 2>/dev/null | head -n 1 || true)"
  case "$IP4" in 100.*) p=1 ;; *) p=0 ;; esac
  check "Tailscale IPv4 assigned (${IP4:-none})" "$p"
else
  [ "$(backend_state)" = "NeedsLogin" ] && p=1 || p=0
  check "daemon responding, awaiting login (NeedsLogin)" "$p"
fi

echo
"$TS" status 2>/dev/null | head -n 5 || true
echo
if [ "$FAILS" -eq 0 ]; then
  log "All checks passed."
  log "Next: from another tailnet device run 'tailscale ping <hostname>', then reboot-test."
  exit 0
fi
die "$FAILS check(s) failed"
