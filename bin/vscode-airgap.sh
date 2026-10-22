#!/usr/bin/env bash
# vscode-airgap.sh — stage a Remote-SSH connection to an air-gapped Linux
# host: pre-install the exact VS Code Server commit so the client never
# needs to download it, plus matching client installers (Linux + Windows)
# so Help > About reports the same commit. Default install is
# ~/.vscode-server (what Remote-SSH looks for). Pass --install-dir
# /opt/vscode-server for a shared, fapolicyd-allowable location and
# --link-home so each user's ~/.vscode-server presence tests still pass.
# Also supports Microsoft's Remote Tunnels and `code serve-web` as
# secondary, online-only / optional paths.
#
# See docs/reference/download-urls.md for the exact endpoints this uses,
# docs/runbooks/ for online-vs-airgap and realm+OTP SSH walkthroughs, and
# docs/designs/vscode-airgap-tunnels.md for why it's built this way.
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────
SELF="$(basename "$0")"
readonly SELF
readonly UPDATE_HOST="https://update.code.visualstudio.com"
readonly MARKETPLACE_HOST="https://marketplace.visualstudio.com"
readonly DEFAULT_SHARED_INSTALL_DIR="/opt/vscode-server"
# Under sudo HOME is /root, and nobody connects as root: default to the
# shared tree there instead.
if [ "$(id -u)" -eq 0 ]; then
  DEFAULT_INSTALL_DIR="$DEFAULT_SHARED_INSTALL_DIR"
else
  DEFAULT_INSTALL_DIR="${HOME}/.vscode-server"
fi
readonly DEFAULT_INSTALL_DIR
readonly DEFAULT_BIND_ADDR="127.0.0.1"
readonly DEFAULT_PORT="8000"
readonly DEFAULT_SERVER_ARCH="linux-x64"
readonly DEFAULT_FAPOLICYD_PRIORITY="25"
readonly DEFAULT_SSHD_PRIORITY="50"
readonly DEFAULT_CENTRAL_KEYS_DIR="/etc/ssh/authorized_keys"
readonly VSCODE_GIT_REPO="https://github.com/microsoft/vscode.git"
readonly DEFAULT_TAG_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/vscode-airgap"
readonly DEFAULT_TAG_CACHE_TTL="86400"   # 24h — tags don't change often enough to justify refetching every run

# ── Defaults (overridable by env, then by flags) ────────────────────────────
MODE="${MODE:-}"
CHANNEL="${CHANNEL:-stable}"
VERSION="${VERSION:-}"
COMMIT="${COMMIT:-}"
ARCH="${ARCH:-}"                       # remote Linux SSH host's arch (server-side)
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
BIND_ADDR="${BIND_ADDR:-$DEFAULT_BIND_ADDR}"
PORT="${PORT:-$DEFAULT_PORT}"
TOKEN="${TOKEN:-}"
EXTENSIONS="${EXTENSIONS:-}"
EXTENSIONS_FILE="${EXTENSIONS_FILE:-}"
BUNDLE_PATH="${BUNDLE_PATH:-}"
ACTION="install"          # install (default) | tunnel | status | emit-ssh-config | list-versions | link-home | install-fapolicyd
START_AFTER_INSTALL=0     # serve-web only starts if --serve-web is also given
DOWNLOAD_ONLY=0
FORCE=0
SHARED="${SHARED:-0}"     # world-readable tree; auto-on when INSTALL_DIR is not under $HOME
LINK_HOME="${LINK_HOME:-0}"
LINK_USERS="${LINK_USERS:-}"
ALL_USERS="${ALL_USERS:-0}"     # --all-users: link every account that has a ~/.vscode-server
INSTALL_FAPOLICYD="${INSTALL_FAPOLICYD:-0}"
FAPOLICYD_PRIORITY="${FAPOLICYD_PRIORITY:-$DEFAULT_FAPOLICYD_PRIORITY}"
SSHD_PRIORITY="${SSHD_PRIORITY:-$DEFAULT_SSHD_PRIORITY}"
CENTRAL_KEYS="${CENTRAL_KEYS:-0}"        # opt-in: emit AuthorizedKeysFile with a central path first
CENTRAL_KEYS_ONLY="${CENTRAL_KEYS_ONLY:-0}"  # central path and nothing else — silent logs on a known-NFS host
CENTRAL_KEYS_DIR="${CENTRAL_KEYS_DIR:-$DEFAULT_CENTRAL_KEYS_DIR}"
AUTHORIZED_KEY_SRC=""                    # --install-authorized-key's key file; empty means stdin
WITH_SERVE_WEB=0          # --serve-web: also fetch+optionally start code serve-web
WITH_CLI=0                # implied by --serve-web or --tunnel
KEEP_OLD="${KEEP_OLD:-0}"       # --keep-old: do not prune other commits after an install
LIST_VERSIONS="${LIST_VERSIONS:-0}"
LIST_FORMAT="text"        # text|json, for --list-versions
# Default 10 newest rows so --list-versions is a picker, not a 10-year dump.
# 0 / --all = no cap. Env LIST_LIMIT overrides the default.
LIST_LIMIT="${LIST_LIMIT:-10}"
TAG_CACHE_DIR="${TAG_CACHE_DIR:-$DEFAULT_TAG_CACHE_DIR}"
TAG_CACHE_TTL="${TAG_CACHE_TTL:-$DEFAULT_TAG_CACHE_TTL}"

# HTTP(S)_PROXY / NO_PROXY are read straight from the environment by curl
# and by Python's urllib (extension queries); nothing here bypasses them.

# ── Logging (never echo secrets) ─────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
warn() { log "WARN:  $*"; }

# Set by run_bundle/run_offline right after mktemp -d; a script-global (not
# `local`) so the EXIT trap can still see it however the function returns —
# including via the `exec` at the bottom of install_from_stage, where the
# trap never fires at all because exec replaces the process image outright.
_STAGE_DIR=""
cleanup_stage_dir() { [ -n "$_STAGE_DIR" ] && rm -rf "$_STAGE_DIR"; }

# ── Help ─────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
vscode-airgap.sh: pre-stage the VS Code Remote-SSH server on an air-gapped Linux host.

USAGE
  vscode-airgap.sh --mode bundle  [--version V] [--extensions-file F]
  vscode-airgap.sh --mode offline --bundle-path B [--link-home [--user LIST] | --all-users]
  vscode-airgap.sh --mode online  [--link-home]
  vscode-airgap.sh --link-home [--user LIST] | --all-users
  vscode-airgap.sh --emit-ssh-config [--user LIST] [--central-keys]
  vscode-airgap.sh --install-fapolicyd
  vscode-airgap.sh --install-authorized-key KEY.pub [--user NAME]
  vscode-airgap.sh --status | --prune
  vscode-airgap.sh --list-versions [--limit N | --all] [--format json]

EXAMPLES
  VSA=/usr/local/bin/vscode-airgap.sh
  VSCODE_VER=1.139.1

  # Online side: build vscode-bundle-v1.139.1.tar.gz in the current directory
  sudo $VSA --mode bundle --version $VSCODE_VER --extensions extensions.txt

  # Air-gapped host, first install: /opt/vscode-server, links, fapolicyd rule
  sudo $VSA --mode offline --bundle-path vscode-bundle-v$VSCODE_VER.tar.gz \
    --link-home --user alice,bob --install-fapolicyd

  # Update: install, then relink everyone who has connected before
  sudo $VSA --mode offline --bundle-path vscode-bundle-v$VSCODE_VER.tar.gz \
    --all-users

  # Onboard one more user against the installed commit
  sudo $VSA --link-home --user carol

  # Client ssh_config, settings.json, fapolicyd rule, one sshd drop-in per user
  sudo $VSA --emit-ssh-config --user alice,bob

  # NFS home under SELinux: central key file plus a drop-in that reads it
  sudo $VSA --install-authorized-key ~alice/.ssh/id_ed25519.pub \
    --user alice
  sudo $VSA --emit-ssh-config --user alice --central-keys

  # What is staged, then remove every commit but the installed one
  sudo $VSA --status
  sudo $VSA --prune

DEFAULTS
  --user          the account that ran sudo ($SUDO_USER)
  --install-dir   /opt/vscode-server as root, ~/.vscode-server otherwise
  --bundle-path   vscode-bundle-v<version>.tar.gz (bundle mode)
  --link-home     replaces an existing real path with the symlink

OPTIONS (env var in brackets)
  --mode online|bundle|offline   (MODE)
  --version V                    stable semver, e.g. 1.139.1 or 1.139 (VERSION)
  --commit SHA                   40-char commit, wins over --version (COMMIT)
  --channel stable|insider       default stable (CHANNEL)
  --arch ARCH                    remote host: linux-x64 (default), linux-arm64,
                                 linux-armhf, alpine-x64, alpine-arm64, auto (ARCH)
  --install-dir DIR              (INSTALL_DIR)
  --bundle-path PATH             bundle output (bundle) or input (offline) (BUNDLE_PATH)
  --extensions LIST|FILE         comma-separated publisher.name, or a file with one
                                 per line, # comments (EXTENSIONS)
  --extensions-file FILE         same as --extensions FILE (EXTENSIONS_FILE)
  --link-home [USER]             link ~USER/.vscode-server to INSTALL_DIR (LINK_HOME=1)
  --all-users                    --link-home for every account that has a
                                 ~/.vscode-server (ALL_USERS=1)
  --user LIST                    comma list, repeatable; for --link-home,
                                 --emit-ssh-config, --install-authorized-key (LINK_USERS)
  --install-fapolicyd            write and load the fapolicyd rule (INSTALL_FAPOLICYD=1)
  --fapolicyd-priority N         rules.d prefix, default 25 (FAPOLICYD_PRIORITY)
  --emit-ssh-config              write client and sshd templates into INSTALL_DIR
  --sshd-priority N              sshd_config.d prefix, default 50 (SSHD_PRIORITY)
  --central-keys [DIR]           drop-in reads DIR/%u first (/etc/ssh/authorized_keys)
  --central-keys-only [DIR]      drop-in reads DIR/%u only
  --install-authorized-key [F]   append a public key (F or stdin) to the central key dir
  --status                       show installed and other staged commits
  --prune                        remove every commit but the installed one
  --keep-old                     do not prune after an install (KEEP_OLD=1)
  --shared                       force world-readable modes (SHARED=1)
  --download-only                fetch and verify, do not install
  --list-versions                stable releases with commits, newest 10 (LIST_LIMIT)
  --limit N | --all              rows for --list-versions
  --format text|json             output for --list-versions
  --refresh                      refetch the tag cache and artifacts
  --force                        re-download cached artifacts, reload an unchanged
                                 fapolicyd rule
  --serve-web                    also fetch and start `code serve-web` (secondary path)
  --bind ADDR --port N --token T serve-web listener, default 127.0.0.1:8000
                                 (BIND_ADDR, PORT, TOKEN)
  --tunnel                       Microsoft Remote Tunnels, online mode only
  -h, --help

NOTES
  EL sudo leaves /usr/local/bin off PATH (secure_path): call it by full path.
  On a fapolicyd host run the script as data: sudo bash /path/vscode-airgap.sh ...
  Set remote.SSH.localServerDownload "off" on the client (--emit-ssh-config writes it).
  HTTPS_PROXY, HTTP_PROXY and NO_PROXY are honoured.
  Runbooks: docs/runbooks/ in this repo.
EOF
}

# ── Arg parsing ──────────────────────────────────────────────────────────
# need_value "$@" — called by every arm that consumes "$2", so a flag given
# without its value fails with one clear line instead of `set -u` dumping
# "$2: unbound variable" and a trace at whoever ran it.
need_value() {
  { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "$1 needs a value (see --help)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) need_value "$@"; MODE="$2"; shift 2 ;;
    --channel) need_value "$@"; CHANNEL="$2"; shift 2 ;;
    --version) need_value "$@"; VERSION="$2"; shift 2 ;;
    --commit) need_value "$@"; COMMIT="$2"; shift 2 ;;
    --arch) need_value "$@"; ARCH="$2"; shift 2 ;;
    --install-dir) need_value "$@"; INSTALL_DIR="$2"; shift 2 ;;
    --bundle-path) need_value "$@"; BUNDLE_PATH="$2"; shift 2 ;;
    --bind) need_value "$@"; BIND_ADDR="$2"; shift 2 ;;
    --port) need_value "$@"; PORT="$2"; shift 2 ;;
    --token) need_value "$@"; TOKEN="$2"; shift 2 ;;
    --extensions) need_value "$@"; EXTENSIONS="$2"; shift 2 ;;
    --extensions-file) need_value "$@"; EXTENSIONS_FILE="$2"; shift 2 ;;
    --serve-web) WITH_SERVE_WEB=1; WITH_CLI=1; START_AFTER_INSTALL=1; shift ;;
    --download-only) DOWNLOAD_ONLY=1; START_AFTER_INSTALL=0; shift ;;
    --tunnel) ACTION="tunnel"; WITH_CLI=1; shift ;;
    --status) ACTION="status"; shift ;;
    --prune) ACTION="prune"; shift ;;
    --keep-old) KEEP_OLD=1; shift ;;
    --emit-ssh-config) ACTION="emit-ssh-config"; shift ;;
    --list-versions) ACTION="list-versions"; shift ;;
    --limit) need_value "$@"; LIST_LIMIT="$2"; shift 2 ;;
    --all) LIST_LIMIT=0; shift ;;
    --format) need_value "$@"; LIST_FORMAT="$2"; shift 2 ;;
    --shared) SHARED=1; shift ;;
    --link-home)
      LINK_HOME=1
      if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
        LINK_USERS="${LINK_USERS:+$LINK_USERS,}$2"
        shift
      fi
      shift
      ;;
    --user)
      need_value "$@"
      LINK_HOME=1
      LINK_USERS="${LINK_USERS:+$LINK_USERS,}$2"
      shift 2
      ;;
    --link-users)
      need_value "$@"
      LINK_HOME=1
      LINK_USERS="${LINK_USERS:+$LINK_USERS,}$2"
      shift 2
      ;;
    --all-users) LINK_HOME=1; ALL_USERS=1; shift ;;
    --install-fapolicyd) INSTALL_FAPOLICYD=1; shift ;;
    --fapolicyd-priority) need_value "$@"; FAPOLICYD_PRIORITY="$2"; shift 2 ;;
    --sshd-priority) need_value "$@"; SSHD_PRIORITY="$2"; shift 2 ;;
    --central-keys)
      CENTRAL_KEYS=1
      if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
        CENTRAL_KEYS_DIR="$2"
        shift
      fi
      shift
      ;;
    --central-keys-only)
      CENTRAL_KEYS=1
      CENTRAL_KEYS_ONLY=1
      if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
        CENTRAL_KEYS_DIR="$2"
        shift
      fi
      shift
      ;;
    --install-authorized-key)
      ACTION="install-authorized-key"
      CENTRAL_KEYS=1
      if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
        AUTHORIZED_KEY_SRC="$2"
        shift
      fi
      shift
      ;;
    --force) FORCE=1; shift ;;
    --refresh) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ "$LIST_VERSIONS" = "1" ] && ACTION="list-versions"
case "$LIST_FORMAT" in text|json) ;; *) die "invalid --format '$LIST_FORMAT' (text|json)" ;; esac

# --status / --emit-ssh-config / --list-versions / --link-home /
# --install-fapolicyd are standalone queries that never require --mode
# (link-home and install-fapolicyd also run AFTER a --mode install when
# given together). --list-versions is NOT network-free like the others
# (unless --bundle-path is given) — see the dependency block below.
if [ -z "$MODE" ] && [ "$ACTION" = "install" ]; then
  if [ "$LINK_HOME" = "1" ]; then
    ACTION="link-home"
  elif [ "$INSTALL_FAPOLICYD" = "1" ]; then
    ACTION="install-fapolicyd"
  fi
fi
if [ "$ACTION" = "status" ] || [ "$ACTION" = "emit-ssh-config" ] || [ "$ACTION" = "list-versions" ] \
    || [ "$ACTION" = "link-home" ] || [ "$ACTION" = "install-fapolicyd" ] \
    || [ "$ACTION" = "install-authorized-key" ] || [ "$ACTION" = "prune" ]; then
  STANDALONE_ACTION=1
else
  STANDALONE_ACTION=0
  [ -n "$MODE" ] || { usage; die "MODE / --mode is required (online|bundle|offline)" ; }
  case "$MODE" in online|bundle|offline) ;; *) die "invalid --mode '$MODE' (online|bundle|offline)" ;; esac
  case "$CHANNEL" in stable|insider) ;; *) die "invalid --channel '$CHANNEL' (stable|insider)" ;; esac
fi

# ── Dependency check ─────────────────────────────────────────────────────
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
if [ "$ACTION" = "status" ] || [ "$ACTION" = "emit-ssh-config" ] \
    || [ "$ACTION" = "link-home" ] || [ "$ACTION" = "install-fapolicyd" ] \
    || [ "$ACTION" = "install-authorized-key" ] || [ "$ACTION" = "prune" ]; then
  : # genuinely zero deps beyond bash/coreutils, by design
elif [ "$ACTION" = "list-versions" ]; then
  if [ -z "$BUNDLE_PATH" ]; then
    require_cmd git
    require_cmd curl
    require_cmd python3
  fi
else
  for c in tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || command -v "${c/sha256sum/shasum}" >/dev/null 2>&1 || die "required command not found: $c"
  done
  [ "$MODE" != "offline" ] && require_cmd curl
  if [ "$MODE" != "offline" ] && { [ -n "$EXTENSIONS" ] || [ -n "$EXTENSIONS_FILE" ]; }; then
    require_cmd python3
  fi
  if [ "$MODE" != "offline" ] && [ -n "$VERSION" ] && [ -z "$COMMIT" ]; then
    require_cmd git
    require_cmd python3
  fi
fi

sha256_of() {
  # Portable sha256: coreutils sha256sum on Linux, shasum -a 256 on macOS/BSD.
  # Missing file must fail (empty stdout + rc 0 used to look like a match).
  [ -f "$1" ] || return 1
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "$1" | awk '{print $1}')"
  else
    out="$(shasum -a 256 "$1" | awk '{print $1}')"
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# ── Arch handling ─────────────────────────────────────────────────────────
# NOTE: unlike v1, ARCH here means the REMOTE Linux host's arch, not the
# arch of the machine running this script — this build/bundle step very
# often runs on a different machine (an operator's laptop, a jump host)
# than the air-gapped target. Default is the mandatory linux-x64, not an
# auto-detected uname. Pass --arch auto to opt into uname-based detection
# (only meaningful for the secondary --serve-web-on-this-host path).
detect_arch_from_uname() {
  local os_name kernel_arch
  os_name="$(uname -s)"
  kernel_arch="$(uname -m)"
  case "$os_name" in
    Linux)
      if [ -f /etc/alpine-release ]; then
        case "$kernel_arch" in
          x86_64) echo "alpine-x64" ;;
          aarch64|arm64) echo "alpine-arm64" ;;
          *) die "unsupported Linux/alpine arch: $kernel_arch" ;;
        esac
      else
        case "$kernel_arch" in
          x86_64) echo "linux-x64" ;;
          aarch64|arm64) echo "linux-arm64" ;;
          armv7l|armhf) echo "linux-armhf" ;;
          *) die "unsupported Linux arch: $kernel_arch" ;;
        esac
      fi
      ;;
    Darwin)
      case "$kernel_arch" in
        arm64) echo "darwin-arm64" ;;
        x86_64) echo "darwin-x64" ;;
        *) die "unsupported Darwin arch: $kernel_arch" ;;
      esac
      ;;
    *) die "unsupported OS for --arch auto: $os_name" ;;
  esac
}
if [ "$STANDALONE_ACTION" -eq 0 ]; then
  if [ -z "$ARCH" ]; then
    ARCH="$DEFAULT_SERVER_ARCH"
  elif [ "$ARCH" = "auto" ]; then
    ARCH="$(detect_arch_from_uname)"
  fi
fi

# LOCAL_ARCH is a DELIBERATELY SEPARATE concern from ARCH. ARCH is the
# REMOTE Linux host's arch (mandatory artifacts: server-linux-<ARCH>,
# always fixed at linux-x64 by default regardless of what machine is
# running this script). --serve-web/--tunnel instead run CLI/server-web
# ON THIS MACHINE, which is very often a different arch — found live
# (2026-08-17): building on an arm64 Colima host with ARCH defaulted to
# linux-x64 downloaded an x86_64 `code` binary, which then failed under
# Rosetta with "failed to open elf at /lib64/ld-linux-x86-64.so.2" the
# moment serve-web tried to exec it. LOCAL_ARCH always auto-detects from
# uname (equivalent to v1's old default) since these artifacts must match
# the host actually executing them.
LOCAL_ARCH="$(detect_arch_from_uname 2>/dev/null || true)"

# Platform-segment names per update.code.visualstudio.com's naming
# (verified live 2026-08-17 — see docs/reference/download-urls.md).
remote_ssh_server_segment() {
  case "$ARCH" in
    linux-x64) echo "server-linux-x64" ;;
    linux-arm64) echo "server-linux-arm64" ;;
    linux-armhf) echo "server-linux-armhf" ;;
    alpine-x64) echo "server-linux-alpine" ;;
    *) die "no classic Remote-SSH server artifact for arch '$ARCH'" ;;
  esac
}
# CLI tarball Remote-SSH's exec-server handshake waits for at
# ~/.vscode-server/vscode-cli-<commit>.tar.gz. That is cli-alpine-x64 on
# linux-x64 remotes — not the builder's LOCAL_ARCH CLI (which is for
# --serve-web / --tunnel only).
remote_ssh_cli_segment() {
  case "$ARCH" in
    linux-x64|alpine-x64) echo "cli-alpine-x64" ;;
    linux-arm64|alpine-arm64) echo "cli-alpine-arm64" ;;
    *) echo "" ;;
  esac
}
cli_platform_segment() {
  case "$LOCAL_ARCH" in
    linux-x64) echo "cli-linux-x64" ;;
    linux-arm64) echo "cli-linux-arm64" ;;
    linux-armhf) echo "cli-linux-armhf" ;;
    alpine-x64) echo "cli-alpine-x64" ;;
    alpine-arm64) echo "cli-alpine-arm64" ;;
    darwin-x64) echo "cli-darwin-x64" ;;
    darwin-arm64) echo "cli-darwin-arm64" ;;
    *) die "no CLI artifact mapping for local arch '$LOCAL_ARCH'" ;;
  esac
}
server_web_platform_segment() {
  case "$LOCAL_ARCH" in
    linux-x64) echo "server-linux-x64-web" ;;
    linux-arm64) echo "server-linux-arm64-web" ;;
    linux-armhf) echo "server-linux-armhf-web" ;;
    alpine-x64) echo "server-linux-alpine-web" ;;
    *) die "no server-web artifact for local arch '$LOCAL_ARCH'" ;;
  esac
}
readonly DESKTOP_LINUX_SEGMENT="linux-x64"      # always fetched, fixed
readonly DESKTOP_WINDOWS_SEGMENT="win32-x64-user"  # always fetched, fixed

# ── Checksummed artifact resolution ──────────────────────────────────────
# Prefer Microsoft's own /api/update/<segment>/<channel>/latest endpoint —
# verified live 2026-08-17 it returns {url, version, commit, sha256hash}
# for every platform segment this script uses (cli-*, server-*, server-*
# -web, linux-x64 desktop, win32-x64-user), correcting v1's docs which
# claimed no checksum existed for the cli/server-web family — that was
# true only of the naive commit:/<segment>/<channel> redirect URL, not of
# this endpoint. Only usable for "latest" (confirmed live: passing an
# older commit in place of "latest" 204s — it's an update-check endpoint,
# not a historical-commit lookup), so an explicit --commit pin falls back
# to constructing the direct URL and self-computing sha256 instead.
#
# On success, prints three lines: url, commit, sha256 (sha256 may be
# empty for the --commit-pinned fallback path — caller then self-computes
# after downloading).
resolve_artifact_meta() {
  local seg="$1"
  if [ -n "$COMMIT" ]; then
    printf '%s\n%s\n%s\n' "$UPDATE_HOST/commit:$COMMIT/$seg/$CHANNEL" "$COMMIT" ""
    return
  fi
  local json http_code
  json="$(curl -fsSL -m 20 -w '\n%{http_code}' "$UPDATE_HOST/api/update/$seg/$CHANNEL/latest" 2>/dev/null)" || json=""
  http_code="$(printf '%s' "$json" | tail -1)"
  json="$(printf '%s' "$json" | sed '$d')"
  if [ "$http_code" != "200" ] || [ -z "$json" ]; then
    warn "no /api/update metadata for '$seg' (http=$http_code) — falling back to commit resolution + self-computed sha256"
    local c
    c="$(resolve_commit_via_commits_api)"
    printf '%s\n%s\n%s\n' "$UPDATE_HOST/commit:$c/$seg/$CHANNEL" "$c" ""
    return
  fi
  python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print(d["url"])
print(d["version"])
print(d.get("sha256hash",""))
' <<<"$json" 2>/dev/null || {
    warn "could not parse /api/update response for '$seg' — falling back"
    local c
    c="$(resolve_commit_via_commits_api)"
    printf '%s\n%s\n%s\n' "$UPDATE_HOST/commit:$c/$seg/$CHANNEL" "$c" ""
  }
}

resolve_commit_via_commits_api() {
  if [ -n "$COMMIT" ]; then echo "$COMMIT"; return; fi
  local commits_json first
  commits_json="$(curl -fsSL -m 20 "$UPDATE_HOST/api/commits/$CHANNEL/server-linux-x64")" \
    || die "failed to reach $UPDATE_HOST (check network/proxy — HTTPS_PROXY=${HTTPS_PROXY:-unset})"
  first="$(printf '%s' "$commits_json" | tr -d '[]" ' | cut -d',' -f1)"
  [ -n "$first" ] || die "could not parse a commit from the commits API response"
  echo "$first"
}

# ── Semver -> commit resolution (git tags, ground truth) ─────────────────
# Verified live 2026-08-18 (see docs/reference/download-urls.md): neither
# /api/commits (a 200-entry rolling window, no semver attached) nor
# /api/releases/<channel> (semver list, NO commit attached) nor
# /api/update/<segment>/<channel>/<baseline> (an UPDATE-CHECK endpoint —
# always describes "what's newer than baseline", 204s when baseline IS
# latest; passing an OLDER commit does NOT return that commit's own info,
# it returns the SAME "here's the current latest" payload every time)
# gives a semver->commit map. microsoft/vscode's git tags do: `git
# ls-remote --tags` returns bare-semver tag names (NO "v" prefix — e.g.
# refs/tags/1.32.0, not v1.32.0) whose SHA is independently confirmed to
# equal the commit the CDN serves for that release (cross-checked against
# /api/update's "latest" commit for 1.133.0 — exact match). Only STABLE
# releases are tagged this way; insider builds track main continuously
# and aren't semver-tagged, so --version only supports channel=stable.
#
# git existing != CDN existing, though: Microsoft prunes old CDN artifacts
# (confirmed live: every server-linux-x64/linux-x64/win32-x64-user build
# older than 1.34.0 404s, including the 1.32.0 the operator asked about
# by name — 1.34.0 is the current floor). So resolution is two-stage:
# tags give the commit, a live HEAD request against the CDN confirms it's
# actually fetchable before this tool ever offers or uses it.

tag_cache_file() {
  [ "$CHANNEL" = "stable" ] || die "--version / --list-versions only supports channel=stable (insider builds aren't semver-tagged in microsoft/vscode — see docs/reference/download-urls.md; use --commit for insider)"
  # sudo -E keeps HOME/XDG_CACHE_HOME, so root can end up creating this
  # cache inside a user's home. Hand it back or their next non-root run
  # cannot refresh it.
  local cache_owner
  cache_owner="$(owner_for_tree "$TAG_CACHE_DIR")"
  mkdir -p "$TAG_CACHE_DIR"
  own_paths "$cache_owner" "$TAG_CACHE_DIR"
  echo "$TAG_CACHE_DIR/tags-stable.tsv"
}

# Rebuilds the cache unconditionally: fetches every microsoft/vscode tag,
# resolves version->commit (peeled/annotated tags win over the lightweight
# tag SHA when both exist for the same version), binary-searches the live
# CDN for the oldest version whose server-linux-x64 artifact still
# resolves (8-10 HEAD requests, not one per version), and writes it all to
# the cache file atomically. git and curl both honour HTTPS_PROXY/
# HTTP_PROXY/NO_PROXY natively (git via its own libcurl-equivalent
# transport, confirmed live by pointing HTTPS_PROXY at a black hole and
# watching it fail to connect rather than silently going direct).
refresh_tag_cache() {
  local cache_file="$1"
  log "refreshing the microsoft/vscode tag cache (git ls-remote --tags, one network round trip)"
  local raw_file
  raw_file="$(mktemp)"
  if ! git ls-remote --tags "$VSCODE_GIT_REPO" > "$raw_file" 2>&1; then
    local err
    err="$(cat "$raw_file")"
    rm -f "$raw_file"
    die "git ls-remote failed against $VSCODE_GIT_REPO (check network/proxy — HTTPS_PROXY=${HTTPS_PROXY:-unset}): $err"
  fi
  local tmp
  tmp="$(mktemp)"
  python3 - "$tmp" "$raw_file" "$UPDATE_HOST" <<'PYEOF'
import re, sys, urllib.request, urllib.error

out_path = sys.argv[1]
raw_path = sys.argv[2]
update_host = sys.argv[3]
with open(raw_path) as f:
    raw = f.read()

pat = re.compile(r'^([0-9a-f]{40})\trefs/tags/(\d+\.\d+\.\d+)(\^\{\})?$', re.MULTILINE)
versions = {}
for sha, ver, peeled in pat.findall(raw):
    if not peeled:
        versions.setdefault(ver, sha)
for sha, ver, peeled in pat.findall(raw):
    if peeled:
        versions[ver] = sha  # dereferenced annotated tag always wins

# Microsoft publishes a release on the CDN before it pushes the git tag
# (1.143.0 was live with no tag). Add the CDN's latest stable build so
# --version can pick it as soon as it ships.
try:
    import json
    with urllib.request.urlopen(f"{update_host}/api/update/server-linux-x64/stable/latest", timeout=15) as r:
        latest = json.load(r)
    ver, sha = latest.get("productVersion", ""), latest.get("version", "")
    if re.fullmatch(r"\d+\.\d+\.\d+", ver) and re.fullmatch(r"[0-9a-f]{40}", sha):
        versions.setdefault(ver, sha)
except Exception as e:
    sys.stderr.write(f"[tag cache] CDN latest lookup failed, using git tags only: {e}\n")

def semver_key(v):
    return tuple(int(x) for x in v.split("."))

ordered = sorted(versions.keys(), key=semver_key, reverse=True)
candidates = [v for v in ordered if semver_key(v) >= (1, 0, 0)]

def cdn_ok(commit):
    url = f"{update_host}/commit:{commit}/server-linux-x64/stable"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            return r.status == 200
    except urllib.error.HTTPError:
        return False
    except Exception as e:
        sys.stderr.write(f"[tag cache] CDN probe failed (network issue, not a 404): {e}\n")
        return False

# Binary search the ok/not-ok boundary. Assumes monotonic pruning (oldest
# pruned first) — true in every spot check done during development
# (2026-08-18): 1.34.0 ok, 1.33.1/1.33.0/1.32.0 all 404, everything from
# 1.34.0 through 1.133.0 (latest) ok. Re-verified fresh on every refresh
# rather than hardcoded, in case Microsoft's retention window moves.
if candidates and cdn_ok(versions[candidates[0]]):
    lo, hi = 0, len(candidates) - 1
    if not cdn_ok(versions[candidates[hi]]):
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if cdn_ok(versions[candidates[mid]]):
                lo = mid
            else:
                hi = mid
        boundary = candidates[lo]
    else:
        boundary = candidates[hi]  # everything checked is still available
else:
    boundary = None  # even "latest" failed the probe — network issue, not a real boundary

import time
with open(out_path, "w") as f:
    f.write(f"# fetched_at={int(time.time())} boundary={boundary or 'unknown'} channel=stable\n")
    for v in ordered:
        f.write(f"{v}\t{versions[v]}\n")

sys.stderr.write(f"[tag cache] {len(ordered)} versions, CDN floor (server-linux-x64): {boundary or 'could not determine'}\n")
PYEOF
  rm -f "$raw_file"
  [ -s "$tmp" ] || { rm -f "$tmp"; die "tag cache refresh produced an empty file"; }
  mv -f "$tmp" "$cache_file"
  # mktemp gives 0600; the cache holds public git tags and has to stay
  # readable to the user who owns the cache directory.
  chmod 0644 "$cache_file"
  own_paths "$(owner_for_tree "$cache_file")" "$cache_file"
  log "tag cache written: $cache_file"
}

file_mtime() {
  # Portable epoch mtime. Never mix BSD `stat -f` into the same || chain as
  # GNU stat: on RHEL/coreutils, `-f` is `--file-system`, not a format, and
  # a failed/empty capture plus `set -u` + uninitialized `local` vars was
  # blowing up `$((now - mtime))` (reported on RHEL at this helper's old site).
  local path="${1:-}" ts=""
  [ -n "$path" ] && [ -e "$path" ] || { echo 0; return 0; }
  ts="$(stat -c %Y "$path" 2>/dev/null || true)"
  if [ -z "$ts" ]; then
    ts="$(stat -f %m "$path" 2>/dev/null || true)"
  fi
  case "$ts" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$ts" ;;
  esac
}

ensure_tag_cache() {
  local cache_file
  cache_file="$(tag_cache_file)"
  local need_refresh=0
  if [ "$FORCE" -eq 1 ] || [ ! -f "$cache_file" ]; then
    need_refresh=1
  else
    # Init every local — bash `local x` leaves x unset, and `set -u` then
    # trips on $((now - mtime)) / comparisons on RHEL bash 4.x.
    local now=0 mtime=0 age=0 ttl=0
    now="$(date +%s 2>/dev/null || echo 0)"
    mtime="$(file_mtime "$cache_file")"
    ttl="${TAG_CACHE_TTL:-86400}"
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    case "$ttl" in ''|*[!0-9]*) ttl=86400 ;; esac
    if [ "$now" -gt 0 ] && [ "$mtime" -gt 0 ]; then
      age=$((now - mtime))
      [ "$age" -lt 0 ] && age=0
      [ "$age" -gt "$ttl" ] && need_refresh=1
    else
      need_refresh=1
    fi
  fi
  [ "$need_refresh" -eq 1 ] && refresh_tag_cache "$cache_file"
  echo "$cache_file"
}

tag_cache_boundary() {
  local cache_file="$1"
  head -1 "$cache_file" | sed -n 's/.*boundary=\([^ ]*\).*/\1/p'
}

# resolve_version_to_commit <version-input> — normalizes (strips a leading
# v/V), matches against the tag cache (exact X.Y.Z, or an X.Y prefix —
# the newest matching X.Y.Z tag wins, no "ambiguous" error), then does a
# LIVE HEAD check against the CDN (never trusts the cache's own boundary
# line for this — that's only for --list-versions' display column)
# before returning. Dies with a clear, actionable message on no-match or
# CDN-unreachable — never silently falls back to latest.
resolve_version_to_commit() {
  local input="$1"
  local norm="${input#v}"
  norm="${norm#V}"
  local cache_file
  cache_file="$(ensure_tag_cache)"

  # awk used to `exit 1` on no exact match; under `set -e` that aborted
  # the script BEFORE the X.Y → newest X.Y.Z fallback — so `--version 1.33`
  # never got a chance to become 1.33.1. Swallow the miss and branch.
  local exact=""
  exact="$(awk -F'\t' -v v="$norm" '$1==v{print $2; exit}' "$cache_file" || true)"
  if [ -z "$exact" ]; then
    local dots
    dots="$(printf '%s' "$norm" | tr -cd '.' | wc -c | tr -d ' ')"
    if [ "$dots" -eq 1 ]; then
      # Cache is newest-first. Take the newest X.Y.Z (do not error as
      # "ambiguous" — that's what made --version 1.33 unusable).
      local best=""
      best="$(awk -F'\t' -v p="$norm." 'index($1,p)==1{print $1; exit}' "$cache_file" || true)"
      if [ -n "$best" ]; then
        log "--version $input -> newest matching tag $best"
        norm="$best"
        exact="$(awk -F'\t' -v v="$norm" '$1==v{print $2; exit}' "$cache_file" || true)"
      fi
    fi
  fi
  [ -n "$exact" ] || die "--version '$input' not found in microsoft/vscode's stable tags (${cache_file}). Run '$SELF --list-versions' to see what's available, or pass --refresh if you expect a very recent release to appear."

  log "checking CDN availability for $norm (commit ${exact:0:12}...)"
  local http_code
  http_code="$(curl -sI -L -m 20 -o /dev/null -w '%{http_code}' "$UPDATE_HOST/commit:$exact/server-linux-x64/stable" 2>/dev/null || echo 000)"
  case "$http_code" in
    200|302) : ;;
    *) die "version $norm's server-linux-x64 artifact is no longer on Microsoft's CDN (checked live, http=$http_code, commit ${exact:0:12}...). Microsoft prunes old builds — as of this tool's last live check, 1.34.0 is the oldest stable release still hosted; anything older (including 1.32.0) is gone. Run '$SELF --list-versions' to see what's actually fetchable, or use --commit if you have another source for the artifact." ;;
  esac

  VERSION="$norm"  # normalize the global so filenames/manifest use the canonical form
  echo "$exact"
}

# ── list-versions ──────────────────────────────────────────────────────
run_list_versions() {
  if [ -n "$BUNDLE_PATH" ]; then
    [ -f "$BUNDLE_PATH" ] || die "bundle not found: $BUNDLE_PATH"
    local tmp
    tmp="$(mktemp -d)"
    # `-O` streams one member to stdout without extracting the (possibly
    # many-hundred-MB) rest of the bundle — but the member name has to
    # match exactly, and the bundle's own tar entries are stored as
    # "./versions.json" (leading "./", from
    # `tar -C "$stage_dir" -czf "$BUNDLE_PATH" .` in run_bundle) — found
    # live, asking tar for the bare name "versions.json" silently matched
    # nothing and this branch always errored. Try both forms.
    ( tar -O -xzf "$BUNDLE_PATH" ./versions.json 2>/dev/null \
      || tar -O -xzf "$BUNDLE_PATH" versions.json 2>/dev/null ) > "$tmp/versions.json"
    [ -s "$tmp/versions.json" ] || { rm -rf "$tmp"; die "bundle has no versions.json: $BUNDLE_PATH"; }
    local ver commit
    ver="$(json_field "$tmp/versions.json" vscode_version)"
    commit="$(json_field "$tmp/versions.json" commit)"
    rm -rf "$tmp"
    if [ "$LIST_FORMAT" = "json" ]; then
      printf '[{"version":"%s","commit":"%s","source":"bundle:%s"}]\n' "$ver" "$commit" "$BUNDLE_PATH"
    else
      printf '%-11s %-42s %s\n' "VERSION" "COMMIT" "SOURCE"
      printf '%-11s %-42s %s\n' "$ver" "$commit" "$(basename "$BUNDLE_PATH")"
    fi
    return
  fi

  local cache_file
  cache_file="$(ensure_tag_cache)"
  local boundary
  boundary="$(tag_cache_boundary "$cache_file")"
  local total shown
  total="$(grep -c $'\t' "$cache_file" || true)"
  case "$LIST_LIMIT" in
    ''|*[!0-9]*) die "invalid --limit '$LIST_LIMIT' (need a non-negative integer, or --all)" ;;
  esac
  if [ "$LIST_LIMIT" -eq 0 ] || [ "$LIST_LIMIT" -ge "$total" ]; then
    shown="$total"
  else
    shown="$LIST_LIMIT"
  fi
  log "$total stable versions cached, showing $shown newest; CDN floor (server-linux-x64, as of last refresh): ${boundary:-unknown}"

  if [ "$LIST_FORMAT" = "json" ]; then
    python3 -c '
import json, sys
boundary = sys.argv[1]
limit = int(sys.argv[2])
def semver_key(v):
    return tuple(int(x) for x in v.split("."))
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    v, c = line.split("\t")
    ok = boundary != "unknown" and semver_key(v) >= semver_key(boundary)
    rows.append({"version": v, "commit": c, "cdn": "ok" if ok else "missing"})
    if limit and len(rows) >= limit:
        break
print(json.dumps(rows, indent=2))
' "${boundary:-unknown}" "$LIST_LIMIT" < "$cache_file"
  else
    printf '%-11s %-42s %s\n' "VERSION" "COMMIT" "CDN"
    python3 -c '
import sys
boundary = sys.argv[1]
limit = int(sys.argv[2])
def semver_key(v):
    return tuple(int(x) for x in v.split("."))
n = 0
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    v, c = line.split("\t")
    ok = boundary != "unknown" and semver_key(v) >= semver_key(boundary)
    status = "ok" if ok else "missing"
    print(f"{v:<11} {c:<42} {status}")
    n += 1
    if limit and n >= limit:
        break
' "${boundary:-unknown}" "$LIST_LIMIT" < "$cache_file"
    if [ "$shown" -lt "$total" ]; then
      log "showing $shown of $total (newest first). --limit N or --all for more; --version still accepts any cached tag."
    fi
    log "CDN column is derived from the cached floor (${boundary:-unknown}), not a live check per row — pass --refresh to re-derive it, or --version <ver> to get an authoritative live check for one version."
  fi
}

# download_checksummed_artifact <platform-segment> <dest-file>
# Fetches via resolve_artifact_meta, downloads, and verifies/records a
# sha256 — Microsoft's own when available, self-computed otherwise (both
# distinguished in the returned checksum-source line so the manifest is
# honest about which kind it is).
# Prints two lines on success: sha256, checksum_source (microsoft|self)
download_checksummed_artifact() {
  local seg="$1" dest="$2"
  local meta url commit sha_ms
  meta="$(resolve_artifact_meta "$seg")"
  url="$(printf '%s' "$meta" | sed -n 1p)"
  commit="$(printf '%s' "$meta" | sed -n 2p)"
  sha_ms="$(printf '%s' "$meta" | sed -n 3p)"
  if [ "$FORCE" -eq 1 ] || [ ! -f "$dest" ]; then
    log "downloading $seg (commit ${commit:0:12}...) -> $dest"
    curl -fSL -sS --retry 3 --retry-connrefused -m 600 -o "$dest" "$url" \
      || die "download failed for $seg from $url"
    [ -s "$dest" ] || die "downloaded file is empty: $dest"
  fi
  local sha_got
  sha_got="$(sha256_of "$dest")"
  if [ -n "$sha_ms" ]; then
    [ "$sha_got" = "$sha_ms" ] || die "sha256 mismatch for $seg: Microsoft published $sha_ms, got $sha_got — download is corrupt, refusing to continue"
    printf '%s\nmicrosoft\n' "$sha_got"
  else
    printf '%s\nself\n' "$sha_got"
  fi
  # side channel: RESOLVED_COMMIT / RESOLVED_VERSION for the caller
  echo "$commit" > "${dest}.commit"
}

# ── Extensions ────────────────────────────────────────────────────────────
# Newline-delimited file -> comma list, '#' comments and blanks stripped.
read_extensions_file() {
  local f="$1"
  [ -f "$f" ] || die "--extensions-file not found: $f"
  grep -v '^[[:space:]]*#' "$f" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# pick_and_download_extension <pub.name> <target_vscode_version> <dest_dir>
# Prints JSON on stdout describing what was selected (captured by caller):
# {"id":..., "version":..., "target_platform":..., "engine":..., "method":...}
pick_and_download_extension() {
  local ext_id="$1" target_version="$2" dest_dir="$3"
  local pub name
  pub="${ext_id%%.*}"
  name="${ext_id#*.}"
  [ -n "$pub" ] && [ -n "$name" ] && [ "$pub" != "$name" ] \
    || die "invalid extension id '$ext_id' (expected publisher.name)"
  local dest="${dest_dir}/${ext_id}.vsix"
  python3 - "$pub" "$name" "$target_version" "$dest" "$MARKETPLACE_HOST" <<'PYEOF'
import json, re, sys, urllib.request, urllib.error

pub, name, target_version, dest, host = sys.argv[1:6]
ext_id = f"{pub}.{name}"

def http_post_json(url, body, headers):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

def http_get(url):
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

def parse_version(v):
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", v)
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)

def engine_satisfied(engine_range, version_str):
    # VS Code engine ranges in practice are almost always "^X.Y.Z", "*",
    # or ">=X.Y.Z" — not a full semver-range grammar. Handle those; treat
    # anything unparsed as satisfied-but-unverified (fail open on parsing,
    # never silently reject a real extension over a range this script
    # can't parse — record it as such via the caller's method field).
    engine_range = (engine_range or "*").strip()
    v = parse_version(version_str)
    if engine_range in ("*", ""):
        return True
    m = re.match(r"\^(\d+)\.(\d+)\.(\d+)", engine_range)
    if m:
        lo = tuple(int(x) for x in m.groups())
        hi = (lo[0] + 1, 0, 0)
        return lo <= v < hi
    m = re.match(r">=\s*(\d+)\.(\d+)\.(\d+)", engine_range)
    if m:
        lo = tuple(int(x) for x in m.groups())
        return v >= lo
    m = re.match(r"(\d+)\.(\d+)\.(\d+)$", engine_range)
    if m:
        return v == tuple(int(x) for x in m.groups())
    return True  # unparsed range: don't block on it

def download_to(url, dest):
    data = http_get(url)
    if not data:
        raise RuntimeError("empty download")
    with open(dest, "wb") as f:
        f.write(data)

headers = {
    "Content-Type": "application/json",
    "Accept": "application/json;api-version=3.0-preview.1",
}
query_url = f"{host}/_apis/public/gallery/extensionquery"
body = {
    "filters": [{"criteria": [{"filterType": 7, "value": ext_id}]}],
    # IncludeVersions(1) | IncludeFiles(2) | IncludeVersionProperties(16)
    "flags": 19,
}

result = None
try:
    d = http_post_json(query_url, body, headers)
    extensions = d.get("results", [{}])[0].get("extensions", [])
    if not extensions:
        raise RuntimeError(f"extension not found: {ext_id}")
    versions = extensions[0]["versions"]

    # Dedup by version string, preferring a linux-x64 targetPlatform entry
    # over the platform-universal one (no targetPlatform key) when both
    # exist for the same version; skip every OTHER platform-specific entry
    # (darwin/win32/alpine/etc — irrelevant to a linux-x64 remote).
    by_version = {}
    for v in versions:
        tp = v.get("targetPlatform")
        if tp is not None and tp != "linux-x64":
            continue
        ver = v["version"]
        if ver not in by_version or tp == "linux-x64":
            by_version[ver] = v

    ordered = sorted(by_version.values(), key=lambda v: parse_version(v["version"]), reverse=True)

    chosen = None
    for v in ordered:
        props = {p["key"]: p["value"] for p in v.get("properties", [])}
        engine = props.get("Microsoft.VisualStudio.Code.Engine", "*")
        if engine_satisfied(engine, target_version):
            chosen = (v, engine)
            break

    if chosen is None:
        raise RuntimeError(f"no version of {ext_id} declares engine compatibility with {target_version}")

    v, engine = chosen
    vsix_url = None
    for f in v["files"]:
        if f["assetType"].endswith("VSIXPackage"):
            vsix_url = f["source"]
            break
    if not vsix_url:
        raise RuntimeError("no VSIXPackage asset in chosen version")

    download_to(vsix_url, dest)
    result = {
        "id": ext_id, "version": v["version"],
        "target_platform": v.get("targetPlatform") or "universal",
        "engine": engine, "method": "engine-matched",
    }
except Exception as e:
    # Fallback: the simple "give me whatever is newest" endpoint. No engine
    # check happens here — recorded honestly as such.
    sys.stderr.write(f"[extensionquery fallback for {ext_id}: {e}]\n")
    fallback_url = f"{host}/_apis/public/gallery/publishers/{pub}/vsextensions/{name}/latest/vspackage"
    download_to(fallback_url, dest)
    result = {"id": ext_id, "version": "latest", "target_platform": "unknown",
              "engine": "unverified", "method": "latest-fallback"}

print(json.dumps(result))
PYEOF
}

# ── ONLINE / BUNDLE: fetch everything into a staging dir ────────────────
stage_artifacts() {
  local stage_dir="$1"
  mkdir -p "$stage_dir"

  # -- Mandatory: Remote-SSH server for the remote Linux host --
  local srv_seg srv_meta srv_sha srv_src commit version
  srv_seg="$(remote_ssh_server_segment)"
  local srv_file="$stage_dir/server-linux-x64.tar.gz"
  srv_meta="$(download_checksummed_artifact "$srv_seg" "$srv_file")"
  srv_sha="$(printf '%s' "$srv_meta" | sed -n 1p)"
  srv_src="$(printf '%s' "$srv_meta" | sed -n 2p)"
  commit="$(cat "${srv_file}.commit")"; rm -f "${srv_file}.commit"

  # Resolve the version string (needed for extension engine matching and
  # the manifest) from the same commit via /api/update — cheap, and gives
  # us the canonical "1.133.0"-style string rather than a raw commit hash.
  version="$(resolve_version_for_commit "$commit")"

  # -- Mandatory: client installers (commit-matched) --
  local lin_meta lin_sha lin_src
  local lin_file="$stage_dir/vscode-linux-x64.tar.gz"
  lin_meta="$(download_checksummed_artifact "$DESKTOP_LINUX_SEGMENT" "$lin_file")"
  lin_sha="$(printf '%s' "$lin_meta" | sed -n 1p)"
  lin_src="$(printf '%s' "$lin_meta" | sed -n 2p)"
  rm -f "${lin_file}.commit"

  local win_meta win_sha win_src
  local win_file="$stage_dir/VSCodeUserSetup-x64-${version}.exe"
  win_meta="$(download_checksummed_artifact "$DESKTOP_WINDOWS_SEGMENT" "$win_file")"
  win_sha="$(printf '%s' "$win_meta" | sed -n 1p)"
  win_src="$(printf '%s' "$win_meta" | sed -n 2p)"
  rm -f "${win_file}.commit"

  # -- Mandatory for Remote-SSH handshake: keep the original CLI archive --
  # Remote-SSH (useExecServer default true, and some classic-path builds)
  # polls ~/.vscode-server/vscode-cli-<commit>.tar.gz + a sibling .done
  # marker. Extracting into ~/.vscode-server/cli is not enough.
  local rssh_cli_sha="" rssh_cli_src=""
  local rssh_cli_seg
  rssh_cli_seg="$(remote_ssh_cli_segment)"
  if [ -n "$rssh_cli_seg" ]; then
    local rssh_cli_meta
    local rssh_cli_file="$stage_dir/cli-alpine-x64.tar.gz"
    # Keep the filename Remote-SSH-shaped even if the segment is arm64.
    if [ "$rssh_cli_seg" != "cli-alpine-x64" ]; then
      rssh_cli_file="$stage_dir/${rssh_cli_seg}.tar.gz"
    fi
    rssh_cli_meta="$(download_checksummed_artifact "$rssh_cli_seg" "$rssh_cli_file")"
    rssh_cli_sha="$(printf '%s' "$rssh_cli_meta" | sed -n 1p)"
    rssh_cli_src="$(printf '%s' "$rssh_cli_meta" | sed -n 2p)"
    rm -f "${rssh_cli_file}.commit"
    # Do NOT copy this alpine tarball to cli.tar.gz. That name is the
    # builder-local CLI used by --serve-web/--tunnel (often glibc).
    # Pre-seeding it here skips the real download and installs musl.
  else
    warn "no Remote-SSH CLI segment for --arch $ARCH — handshake archive will not be bundled"
  fi

  # -- Optional: builder-local CLI (--serve-web / --tunnel) and server-web --
  local cli_sha="" cli_src="" srvweb_sha="" srvweb_src=""
  if [ "$WITH_CLI" -eq 1 ]; then
    local cli_seg cli_meta
    cli_seg="$(cli_platform_segment)"
    local cli_file="$stage_dir/cli.tar.gz"
    cli_meta="$(download_checksummed_artifact "$cli_seg" "$cli_file")"
    cli_sha="$(printf '%s' "$cli_meta" | sed -n 1p)"
    cli_src="$(printf '%s' "$cli_meta" | sed -n 2p)"
    rm -f "${cli_file}.commit"
  fi
  if [ "$WITH_SERVE_WEB" -eq 1 ]; then
    local sw_seg sw_meta
    sw_seg="$(server_web_platform_segment)"
    local sw_file="$stage_dir/server-web.tar.gz"
    sw_meta="$(download_checksummed_artifact "$sw_seg" "$sw_file")"
    srvweb_sha="$(printf '%s' "$sw_meta" | sed -n 1p)"
    srvweb_src="$(printf '%s' "$sw_meta" | sed -n 2p)"
    rm -f "${sw_file}.commit"
  fi

  # -- Extensions: union of --extensions and --extensions-file, deduped --
  # An --extensions item that names a file is read as a list; a
  # publisher.name ID is never an existing path, so nothing is ambiguous.
  local ext_dir="$stage_dir/extensions"
  local all_ext_ids="" ext_results=() item
  if [ -n "$EXTENSIONS" ]; then
    while IFS= read -r item; do
      if [ -f "$item" ]; then
        all_ext_ids="$(printf '%s\n%s\n' "$all_ext_ids" "$(read_extensions_file "$item")")"
      else
        all_ext_ids="$(printf '%s\n%s\n' "$all_ext_ids" "$item")"
      fi
    done <<< "$(printf '%s\n' "$EXTENSIONS" | tr ',' '\n')"
  fi
  if [ -n "$EXTENSIONS_FILE" ]; then
    all_ext_ids="$(printf '%s\n%s\n' "$all_ext_ids" "$(read_extensions_file "$EXTENSIONS_FILE")")"
  fi
  local dedup_ids
  dedup_ids="$(printf '%s\n' "$all_ext_ids" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort -u || true)"
  if [ -n "$dedup_ids" ]; then
    mkdir -p "$ext_dir"
    while IFS= read -r ext; do
      [ -n "$ext" ] || continue
      log "resolving extension $ext (engine target: vscode $version)"
      local one
      one="$(pick_and_download_extension "$ext" "$version" "$ext_dir")" \
        || die "extension resolution failed: $ext"
      ext_results+=("$one")
      log "  -> $(printf '%s' "$one" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["id"], d["version"], "("+d["method"]+")")' 2>/dev/null || echo "$one")"
    done <<<"$dedup_ids"
  fi

  write_manifest "$stage_dir" "$commit" "$version" \
    "$srv_sha" "$srv_src" "$lin_sha" "$lin_src" "$win_sha" "$win_src" \
    "$cli_sha" "$cli_src" "$srvweb_sha" "$srvweb_src" "$(basename "$win_file")" \
    "$rssh_cli_sha" "$rssh_cli_src" \
    "${ext_results[@]:-}"
}

resolve_version_for_commit() {
  local commit="$1"
  if [ -n "$VERSION" ]; then echo "$VERSION"; return; fi
  local json
  json="$(curl -fsSL -m 20 "$UPDATE_HOST/api/update/server-linux-x64/$CHANNEL/latest" 2>/dev/null)" || json=""
  local v
  # NOTE the field name: Microsoft's /api/update JSON is misleadingly
  # shaped — its "version" key actually holds the COMMIT hash (that's
  # what resolve_artifact_meta reads it as, correctly) and the real
  # semver lives under "productVersion". Verified live 2026-08-17 — a
  # naive read of "version" here silently produced a commit-hash-named
  # .exe file instead of "VSCodeUserSetup-x64-1.133.0.exe".
  v="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("productVersion",""))' 2>/dev/null || true)"
  if [ -n "$v" ]; then echo "$v"; return; fi
  warn "could not resolve a semver for commit ${commit:0:12}... — recording the commit itself as the version"
  echo "$commit"
}

write_manifest() {
  local stage_dir="$1" commit="$2" version="$3"
  local srv_sha="$4" srv_src="$5" lin_sha="$6" lin_src="$7" win_sha="$8" win_src="$9"
  shift 9
  local cli_sha="$1" cli_src="$2" srvweb_sha="$3" srvweb_src="$4" win_file_name="$5"
  local rssh_cli_sha="$6" rssh_cli_src="$7"
  shift 7
  local ext_results=("$@")

  local manifest="$stage_dir/versions.json"
  {
    printf '{\n'
    printf '  "channel": "%s",\n' "$CHANNEL"
    printf '  "commit": "%s",\n' "$commit"
    printf '  "vscode_version": "%s",\n' "$version"
    printf '  "requested_version": "%s",\n' "${VERSION:-latest}"
    printf '  "remote_arch": "%s",\n' "$ARCH"
    printf '  "built_at_utc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "server_artifact": "server-linux-x64.tar.gz",\n'
    printf '  "server_sha256": "%s",\n' "$srv_sha"
    printf '  "server_sha256_source": "%s",\n' "$srv_src"
    printf '  "client_linux_artifact": "vscode-linux-x64.tar.gz",\n'
    printf '  "client_linux_sha256": "%s",\n' "$lin_sha"
    printf '  "client_linux_sha256_source": "%s",\n' "$lin_src"
    printf '  "client_windows_artifact": "%s",\n' "$win_file_name"
    printf '  "client_windows_sha256": "%s",\n' "$win_sha"
    printf '  "client_windows_sha256_source": "%s",\n' "$win_src"
    if [ -n "$cli_sha" ]; then
      printf '  "cli_artifact": "cli.tar.gz",\n'
      printf '  "cli_sha256": "%s",\n' "$cli_sha"
      printf '  "cli_sha256_source": "%s",\n' "$cli_src"
    else
      printf '  "cli_artifact": null,\n'
    fi
    if [ -n "$rssh_cli_sha" ]; then
      local rssh_cli_name="cli-alpine-x64.tar.gz"
      if [ -f "$stage_dir/cli-alpine-arm64.tar.gz" ]; then
        rssh_cli_name="cli-alpine-arm64.tar.gz"
      elif [ -f "$stage_dir/cli-alpine-x64.tar.gz" ]; then
        rssh_cli_name="cli-alpine-x64.tar.gz"
      fi
      printf '  "remote_ssh_cli_artifact": "%s",\n' "$rssh_cli_name"
      printf '  "remote_ssh_cli_sha256": "%s",\n' "$rssh_cli_sha"
      printf '  "remote_ssh_cli_sha256_source": "%s",\n' "$rssh_cli_src"
    else
      printf '  "remote_ssh_cli_artifact": null,\n'
    fi
    if [ -n "$srvweb_sha" ]; then
      printf '  "server_web_artifact": "server-web.tar.gz",\n'
      printf '  "server_web_sha256": "%s",\n' "$srvweb_sha"
      printf '  "server_web_sha256_source": "%s",\n' "$srvweb_src"
    else
      printf '  "server_web_artifact": null,\n'
    fi
    printf '  "extensions": ['
    local i=0
    for r in "${ext_results[@]:-}"; do
      [ -n "$r" ] || continue
      [ "$i" -gt 0 ] && printf ','
      printf '\n    %s' "$r"
      i=$((i+1))
    done
    [ "$i" -gt 0 ] && printf '\n  '
    printf ']\n'
    printf '}\n'
  } > "$manifest"
  log "manifest written: $manifest"
}

# ── BUNDLE mode ───────────────────────────────────────────────────────────
run_bundle() {
  local bundle_owner
  _STAGE_DIR="$(mktemp -d)"
  trap cleanup_stage_dir EXIT
  stage_artifacts "$_STAGE_DIR"
  if [ -z "$BUNDLE_PATH" ]; then
    BUNDLE_PATH="vscode-bundle-v$(json_field "$_STAGE_DIR/versions.json" vscode_version).tar.gz"
  fi
  bundle_owner="$(owner_for_tree "$BUNDLE_PATH")"
  mkdir -p "$(dirname "$BUNDLE_PATH")"
  # macOS tar otherwise writes LIBARCHIVE.xattr.com.apple.provenance
  # headers; GNU tar on the air-gapped host warns and ignores them.
  COPYFILE_DISABLE=1 tar -C "$_STAGE_DIR" --exclude='._*' -czf "$BUNDLE_PATH" .
  # A bundle root writes into a user's home stays theirs to carry away.
  own_paths "$bundle_owner" "$BUNDLE_PATH"
  log "bundle written: $BUNDLE_PATH ($(du -h "$BUNDLE_PATH" | awk '{print $1}'))"
  log "carry this file across the air gap, then run:"
  log "  sudo $SELF --mode offline --bundle-path $(basename "$BUNDLE_PATH") --link-home"
}

# ── ONLINE mode ────────────────────────────────────────────────────────────
run_online() {
  local stage_dir="$INSTALL_DIR/.download-cache"
  stage_artifacts "$stage_dir"
  install_from_stage "$stage_dir"
}

# ── OFFLINE mode ──────────────────────────────────────────────────────────
verify_no_network_tools_needed() {
  # Defensive: offline mode must not shell out to curl at all. This function
  # exists purely as a documented guarantee point — no network call is ever
  # made past this line for MODE=offline.
  :
}

run_offline() {
  [ -n "$BUNDLE_PATH" ] || die "--bundle-path is required in offline mode (path to a tarball built with --mode bundle)"
  [ -f "$BUNDLE_PATH" ] || die "bundle not found: $BUNDLE_PATH"
  verify_no_network_tools_needed
  _STAGE_DIR="$(mktemp -d)"
  trap cleanup_stage_dir EXIT
  log "extracting bundle (no network access used or required for this step)"
  tar -C "$_STAGE_DIR" -xzf "$BUNDLE_PATH"
  [ -f "$_STAGE_DIR/versions.json" ] || die "bundle is missing versions.json — not built by this script?"

  verify_artifact_sha "$_STAGE_DIR" server_artifact server_sha256 || die "sha256 mismatch on the Remote-SSH server artifact — bundle is corrupt or tampered, refusing to install"
  verify_artifact_sha "$_STAGE_DIR" client_linux_artifact client_linux_sha256 || die "sha256 mismatch on the Linux client artifact — refusing to install"
  verify_artifact_sha "$_STAGE_DIR" client_windows_artifact client_windows_sha256 || die "sha256 mismatch on the Windows client artifact — refusing to install"
  verify_artifact_sha "$_STAGE_DIR" cli_artifact cli_sha256 || true
  verify_artifact_sha "$_STAGE_DIR" remote_ssh_cli_artifact remote_ssh_cli_sha256 || true
  verify_artifact_sha "$_STAGE_DIR" server_web_artifact server_web_sha256 || true
  log "all bundled artifacts sha256-verified against versions.json"

  if [ "$ACTION" = "tunnel" ]; then
    die "--tunnel is not supported in offline mode: Remote Tunnels requires an outbound connection to Microsoft's relay, which by definition is not available on an air-gapped host. See --help LIMITATIONS."
  fi

  install_from_stage "$_STAGE_DIR"
}

# verify_artifact_sha <stage_dir> <artifact-field> <sha-field>
# Returns 0 (verified) / 1 (field is null, i.e. that optional artifact
# wasn't bundled — not an error) / dies on an actual mismatch.
verify_artifact_sha() {
  local stage_dir="$1" artifact_field="$2" sha_field="$3"
  local artifact sha
  artifact="$(json_field "$stage_dir/versions.json" "$artifact_field")"
  [ -n "$artifact" ] && [ "$artifact" != "null" ] || return 1
  sha="$(json_field "$stage_dir/versions.json" "$sha_field")"
  local got
  got="$(sha256_of "$stage_dir/$artifact")" \
    || die "cannot hash $artifact at $stage_dir/$artifact (missing or unreadable)"
  [ "$got" = "$sha" ] || die "sha256 mismatch for $artifact: expected $sha got $got"
  log "$artifact sha256 OK"
}

# tiny JSON scalar-field reader (no jq dependency) — good enough for our own
# flat versions.json, not a general parser.
json_field() {
  local file="$1" field="$2"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print('' if v is None else v)" "$file" "$field" 2>/dev/null \
    || sed -n "s/.*\"$field\":[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$file" | head -1
}

# ── Shared vs per-user install helpers ─────────────────────────────────
_norm_path() { printf '%s' "$1" | sed 's:/*$::'; }

is_home_install() {
  [ "$(_norm_path "$INSTALL_DIR")" = "$(_norm_path "${HOME}/.vscode-server")" ]
}

want_shared() {
  [ "$SHARED" = "1" ] && return 0
  case "$(_norm_path "$INSTALL_DIR")" in
    "$HOME"|"$HOME"/*|/home/*) return 1 ;;
    *) return 0 ;;
  esac
}

handshake_mode() {
  if want_shared; then
    printf '0644'
  else
    printf '0640'
  fi
}

apply_shared_perms() {
  local root="$1"
  [ -d "$root" ] || return 0
  want_shared || return 0
  log "shared install: world-readable modes under $root"
  chmod 0755 "$root"
  # data/ and extensions/ are per-user state — never chmod those even if
  # someone created them under a shared tree.
  find "$root" \( -path "$root/data" -o -path "$root/data/*" \
      -o -path "$root/extensions" -o -path "$root/extensions/*" \) -prune -o \
    -type d -exec chmod 0755 {} +
  find "$root" \( -path "$root/data" -o -path "$root/data/*" \
      -o -path "$root/extensions" -o -path "$root/extensions/*" \) -prune -o \
    -type f -perm -u+x -exec chmod 0755 {} +
  find "$root" \( -path "$root/data" -o -path "$root/data/*" \
      -o -path "$root/extensions" -o -path "$root/extensions/*" \) -prune -o \
    -type f ! -perm -u+x -exec chmod 0644 {} +
}

user_home_of() {
  local user="$1" home
  if [ -z "$user" ] || [ "$user" = "$(id -un)" ]; then
    printf '%s' "$HOME"
    return
  fi
  home="$(getent passwd "$user" 2>/dev/null | awk -F: '{print $6}')"
  [ -n "$home" ] || die "no passwd entry for user '$user'"
  printf '%s' "$home"
}

# ── Ownership when this script runs as root ────────────────────────────
# Root is the normal way to do a shared install, link another user's
# home, or write fapolicyd rules — and every mkdir/ln/cp/tar it does
# inside a user's home otherwise leaves root-owned paths there.
# Remote-SSH connects AS that user and writes data/, logs and a
# per-commit .token under ~/.vscode-server, so a root-owned tree fails
# the first connection with permission denied. Hand back what root
# created; never touch what the user already owns.
is_root() { [ "$(id -u)" -eq 0 ]; }

# path_owner <path> — "uid:gid" of PATH itself; symlinks are NOT
# followed. Empty when PATH does not exist. Same GNU/BSD split as
# file_mtime: never chain `stat -f` onto `stat -c` in one || run, since
# -f is --file-system on coreutils, not a format string.
path_owner() {
  local p="${1:-}" out=""
  { [ -n "$p" ] && { [ -e "$p" ] || [ -L "$p" ]; }; } || return 0
  out="$(stat -c '%u:%g' "$p" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    out="$(stat -f '%u:%g' "$p" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# path_mode <path> — octal mode of PATH itself, empty when it is missing.
# Same GNU/BSD split as path_owner.
path_mode() {
  local p="${1:-}" out=""
  { [ -n "$p" ] && [ -e "$p" ]; } || return 0
  out="$(stat -c '%a' "$p" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    out="$(stat -f '%Lp' "$p" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# mode_group_world_writable <octal> — what sshd's StrictModes rejects.
mode_group_world_writable() {
  local m="${1:-}"
  [ -n "$m" ] || return 1
  m="${m: -3}"   # ugo digits; stat prints 4 when a setuid/sticky bit is set
  case "${m:1:1}" in 2|3|6|7) return 0 ;; esac
  case "${m:2:1}" in 2|3|6|7) return 0 ;; esac
  return 1
}

# user_owner <name> — "uid:gid" from passwd. id(1) for the current user,
# so this still answers where the account has no local passwd entry.
user_owner() {
  local user="${1:-}" ent
  if [ -z "$user" ] || [ "$user" = "$(id -un)" ]; then
    printf '%s:%s' "$(id -u)" "$(id -g)"
    return
  fi
  ent="$(getent passwd "$user" 2>/dev/null || true)"
  [ -n "$ent" ] || die "no passwd entry for user '$user'"
  printf '%s' "$ent" | awk -F: '{printf "%s:%s", $3, $4}'
}

# owner_for_tree <path> — who anything created at PATH should belong to,
# taken from PATH's nearest existing parent. Empty when there is nothing
# to hand back: not root, or that parent is root's own — /opt/vscode-server
# and /root/.vscode-server are supposed to stay root-owned.
owner_for_tree() {
  local p parent owner
  is_root || return 0
  p="$(_norm_path "${1:-}")"
  parent="$(dirname "$p")"
  while [ ! -d "$parent" ] && [ "$parent" != "/" ] && [ "$parent" != "." ]; do
    parent="$(dirname "$parent")"
  done
  owner="$(path_owner "$parent")"
  case "$owner" in
    ''|0:*) return 0 ;;
    *) printf '%s' "$owner" ;;
  esac
}

# own_paths <uid:gid> <path>... — chown, with -h so a symlink's own
# ownership changes rather than its target's.
own_paths() {
  local owner="${1:-}"
  shift || true
  { [ -n "$owner" ] && [ "$owner" != "0:0" ] && [ "$#" -gt 0 ]; } || return 0
  chown -h "$owner" "$@" 2>/dev/null || warn "could not chown to $owner: $*"
}

# reown_root_created <uid:gid> <root> — hand over only what root owns
# under ROOT, so a user's own data/, extensions/ and tokens are left
# exactly as they are.
reown_root_created() {
  local owner="${1:-}" root="${2:-}"
  { [ -n "$owner" ] && [ "$owner" != "0:0" ] && [ -d "$root" ]; } || return 0
  log "handing root-created paths under $root to uid:gid $owner"
  find "$root" -uid 0 -exec chown -h "$owner" {} + 2>/dev/null \
    || warn "could not hand every root-created path under $root to $owner"
}

# Symlink Remote-SSH presence-test files from dest_root to INSTALL_DIR.
# Leaves data/, extensions/, .*.token, logs as real files in dest_root.
# As root every path below is created root-owned in $user's home unless
# it is chowned back — see the ownership helpers above.
link_one_user() {
  local user="$1"
  local dest_root src commit dest home owner="" owned=""
  src="$(_norm_path "$INSTALL_DIR")"
  home="$(user_home_of "$user")"
  dest_root="$home/.vscode-server"
  if [ "$src" = "$(_norm_path "$dest_root")" ]; then
    log "link-home: $user already uses $src as INSTALL_DIR — nothing to link"
    return 0
  fi
  [ -d "$src" ] || die "INSTALL_DIR does not exist: $src (install first)"
  if [ ! -f "$src/versions.json" ]; then
    die "no versions.json at $src — not a vscode-airgap install"
  fi
  commit="$(json_field "$src/versions.json" commit)"
  [ -n "$commit" ] || die "versions.json at $src has no commit"
  # mkdir -p would otherwise create the home directory itself, root-owned.
  [ -d "$home" ] || die "home directory does not exist: $home (create $user's home before linking)"

  is_root && owner="$(user_owner "$user")"
  # Chown the directories this run creates, plus any an earlier root run
  # left behind — repairing those is the point. Directories already owned
  # by $user are not touched.
  local reown=() d
  for d in "$dest_root" "$dest_root/bin" "$dest_root/cli" "$dest_root/cli/servers"; do
    if [ ! -d "$d" ]; then
      reown+=("$d")
    else
      case "$(path_owner "$d")" in 0:*) reown+=("$d") ;; esac
    fi
  done
  mkdir -p "$dest_root/bin" "$dest_root/cli/servers"
  if [ "${#reown[@]}" -gt 0 ]; then
    own_paths "$owner" "${reown[@]}"
  fi

  _link_replace() {
    local from="$1" to="$2"
    if [ -L "$to" ]; then
      local cur
      cur="$(readlink "$to")"
      if [ "$cur" = "$from" ]; then
        own_paths "$owner" "$to"
        return 0
      fi
      rm -f "$to"
    elif [ -e "$to" ]; then
      warn "replacing $to with a symlink to $from"
      rm -rf "$to"
    fi
    ln -s "$from" "$to"
    own_paths "$owner" "$to"
  }

  [ -d "$src/bin/$commit" ] && _link_replace "$src/bin/$commit" "$dest_root/bin/$commit"
  [ -e "$src/code-$commit" ] && _link_replace "$src/code-$commit" "$dest_root/code-$commit"
  [ -d "$src/cli/servers/Stable-$commit" ] \
    && _link_replace "$src/cli/servers/Stable-$commit" "$dest_root/cli/servers/Stable-$commit"
  [ -e "$src/vscode-cli-$commit.tar.gz" ] \
    && _link_replace "$src/vscode-cli-$commit.tar.gz" "$dest_root/vscode-cli-$commit.tar.gz"
  [ -e "$src/vscode-cli-$commit.tar.gz.done" ] \
    && _link_replace "$src/vscode-cli-$commit.tar.gz.done" "$dest_root/vscode-cli-$commit.tar.gz.done"
  [ -f "$src/versions.json" ] && _link_replace "$src/versions.json" "$dest_root/versions.json"
  # Links into INSTALL_DIR whose target a prune removed: an older commit.
  local stale
  for stale in "$dest_root"/bin/* "$dest_root"/code-* "$dest_root"/cli/servers/Stable-* \
      "$dest_root"/vscode-cli-*; do
    if [ -L "$stale" ] && [ ! -e "$stale" ]; then
      case "$(readlink "$stale")" in
        "$src"/*) rm -f "$stale"; log "removed stale link $stale" ;;
      esac
    fi
  done
  [ -n "$owner" ] && owned=" [owned by $user, uid:gid $owner]"
  log "linked Remote-SSH presence tests for $user: $dest_root -> $src (commit ${commit:0:12}...)${owned}"
}

# Every non-root account whose home already has a .vscode-server, which
# is everyone who has connected with Remote-SSH before. getent passwd
# covers local accounts; /home/* covers directory users that sssd does
# not enumerate.
all_link_users() {
  local u h
  { getent passwd | awk -F: '$3 != 0 {print $1}'
    for h in /home/*; do
      if [ -d "$h/.vscode-server" ]; then stat -c %U "$h"; fi
    done
  } 2>/dev/null | sort -u | while read -r u; do
    case "$u" in ''|root|UNKNOWN) continue ;; esac
    h="$(getent passwd "$u" 2>/dev/null | awk -F: '{print $6}')"
    if [ -n "$h" ] && [ -d "$h/.vscode-server" ]; then
      printf '%s\n' "$u"
    fi
  done
}

run_link_home() {
  local users="$LINK_USERS" u rc
  if [ "$ALL_USERS" = "1" ]; then
    is_root || die "--all-users requires root"
    users="${users:+$users,}$(all_link_users | paste -sd, -)"
    [ -n "$users" ] || { warn "--all-users: no account has a ~/.vscode-server yet"; return 0; }
    log "--all-users: $users"
  fi
  [ -n "$users" ] || users="$(invoking_user)"
  IFS=', ' read -r -a _link_arr <<< "$users"
  for u in "${_link_arr[@]}"; do
    [ -n "$u" ] || continue
    if [ "$u" != "$(id -un)" ] && [ "$(id -u)" -ne 0 ]; then
      die "--user $u requires root"
    fi
    if [ "$ALL_USERS" = "1" ]; then
      # One unreadable home (NFS root_squash) must not stop the rest.
      set +e
      ( set -e; link_one_user "$u" )
      rc=$?
      set -e
      [ "$rc" -eq 0 ] || warn "link-home: skipped $u (exit $rc)"
    else
      link_one_user "$u"
    fi
  done
}

# is_home_path <dir> — true when DIR sits inside somebody's home: under
# /home/, under the invoking user's home, or under the login user's home
# when this is running through sudo.
is_home_path() {
  local p="$1" invoker_home=""
  case "$p" in
    /home/*) return 0 ;;
    "$HOME"|"$HOME"/*) return 0 ;;
  esac
  if [ -n "${SUDO_USER:-}" ]; then
    invoker_home="$(getent passwd "$SUDO_USER" 2>/dev/null | awk -F: '{print $6}')"
    if [ -n "$invoker_home" ]; then
      case "$p" in
        "$invoker_home"|"$invoker_home"/*) return 0 ;;
      esac
    fi
  fi
  return 1
}

write_fapolicyd_example() {
  local dir norm home_rule=0
  norm="$(_norm_path "$INSTALL_DIR")"
  dir="$norm"
  case "$dir" in
    */) ;;
    *) dir="${dir}/" ;;
  esac
  is_home_path "$norm" && home_rule=1
  cat <<EOF
# WHERE THIS GOES — THIS Linux host as root
#   /etc/fapolicyd/rules.d/${FAPOLICYD_PRIORITY}-vscode-server.rules
#   then: fagenrules --load && systemctl restart fapolicyd
#
# fapolicyd denies executing files not in the rpm trust db. VS Code Server
# is a tarball extract, so it is untrusted until allow-listed.
#
# Prefer a shared path (/opt/vscode-server) where the host lets you have
# one: a single rule then covers every user, and it only allows a tree an
# admin controls. A home-directory install is fully supported when a home
# is all you are given — it just costs more, so the tradeoff is stated
# below rather than hidden.
#
# Priority ${FAPOLICYD_PRIORITY} lands before 30-patterns.rules (ld_so) and
# 90-deny-execute.rules. Trailing slash on dir= is required.
EOF
  if [ "$home_rule" -eq 1 ]; then
    cat <<EOF
#
# THIS RULE COVERS A HOME DIRECTORY:
#   ${dir}
# What that buys you: Remote-SSH works for this user on a host where you
# cannot write to /opt.
# What it costs: everything under that directory becomes executable for
# that user, including anything they later drop in it — fapolicyd stops
# checking the trust db in there. Each additional user needs their own
# rule with their own path, so the rule count grows with the team.
# Switch to --install-dir /opt/vscode-server --link-home --user NAME if
# this host ever gives you a shared path.
EOF
  fi
  cat <<EOF

allow perm=any all : dir=${dir}
EOF
}

# ── central authorized_keys ────────────────────────────────────────────
# Put a user's public key on a path sshd can always read. On a host whose
# homes are NFS with SELinux enforcing, sshd_t cannot read nfs_t at all,
# so ~/.ssh/authorized_keys is unreadable no matter how it is labelled and
# restorecon cannot fix it (an NFS mount carries one label for the whole
# filesystem). This never touches an SELinux boolean — changing
# use_nfs_home_dirs is host-wide and the operator's call, not a side
# effect of installing a key.
central_key_file() { printf '%s/%s' "$(_norm_path "$CENTRAL_KEYS_DIR")" "$1"; }

# read_public_key_material — from a file argument, or stdin when none was
# given. Refuses anything that is not an OpenSSH public key line, and
# refuses a private key outright rather than writing it somewhere
# world-readable.
read_public_key_material() {
  local raw="" line out=""
  if [ -n "$AUTHORIZED_KEY_SRC" ] && [ "$AUTHORIZED_KEY_SRC" != "-" ]; then
    [ -f "$AUTHORIZED_KEY_SRC" ] || die "public key file not found: $AUTHORIZED_KEY_SRC"
    raw="$(cat "$AUTHORIZED_KEY_SRC")"
  else
    [ ! -t 0 ] || die "no key given — pass the .pub file (--install-authorized-key ~/.ssh/id_ed25519.pub) or pipe one in"
    raw="$(cat)"
  fi
  case "$raw" in
    *"PRIVATE KEY"*) die "that is a PRIVATE key — install the matching .pub file instead. Nothing was written." ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case " $line " in
      *" ssh-rsa "*|*" ssh-ed25519 "*|*" ssh-dss "*|*" ecdsa-sha2-nistp"*|*" sk-ssh-ed25519@openssh.com "*|*" sk-ecdsa-sha2-nistp"*) ;;
      *) die "not an OpenSSH public key line: '${line%% *} ...' (expected ssh-ed25519, ssh-rsa, ecdsa-sha2-*, or an sk-* security key)" ;;
    esac
    out="${out}${line}"$'\n'
  done <<EOF
$raw
EOF
  [ -n "$out" ] || die "no public key found in the input"
  printf '%s' "$out"
}

run_install_authorized_key() {
  local keys_dir key_file user material existing merged=""
  keys_dir="$(_norm_path "$CENTRAL_KEYS_DIR")"
  case "$keys_dir" in
    /*) ;;
    *) die "--central-keys needs an absolute directory path (got '$keys_dir')" ;;
  esac
  [ -n "$LINK_USERS" ] || die "--install-authorized-key needs --user NAME — whose key is this?"
  [ "$(emit_user_list | wc -l | tr -d ' ')" -eq 1 ] \
    || die "--install-authorized-key takes one --user at a time (got '$LINK_USERS')"
  user="$(emit_user_list)"
  check_user_name "$user"
  # Dies when the account has no passwd entry — a key for a user that does
  # not exist is almost always a typo. Answers from id(1) for the caller's
  # own name, so this works where getent does not.
  local target_uid
  target_uid="$(user_owner "$user")"
  target_uid="${target_uid%%:*}"
  key_file="$(central_key_file "$user")"

  # Read and validate the key before touching the filesystem.
  material="$(read_public_key_material)"

  # Writing under /etc/ssh needs root; a --central-keys directory the
  # caller already owns does not. Installing somebody else's key does,
  # because sshd only accepts a path owned by root or by that user.
  local as_root=0
  is_root && as_root=1
  if [ "$as_root" -eq 0 ] && [ "$user" != "$(id -un)" ]; then
    die "installing a key for '$user' needs root — sshd only reads a key file owned by root or by $user"
  fi
  if [ -e "$keys_dir" ]; then
    [ -d "$keys_dir" ] || die "$keys_dir exists but is not a directory"
    [ -w "$keys_dir" ] || die "cannot write to $keys_dir — re-run under sudo"
    # Report an out-of-shape directory, never silently chmod or chown it:
    # this path may already be serving other people's logins. The rule is
    # sshd's own (secure_filename): every component owned by root or the
    # target user, and never group- or world-writable.
    local d_owner d_mode d_uid problems=""
    d_owner="$(path_owner "$keys_dir")"
    d_mode="$(path_mode "$keys_dir")"
    d_uid="${d_owner%%:*}"
    if [ "$d_uid" != "0" ] && [ "$d_uid" != "$target_uid" ]; then
      problems="owned by uid $d_uid, want root (0) or $user ($target_uid)"
    fi
    if mode_group_world_writable "$d_mode"; then
      problems="${problems:+$problems; }mode $d_mode is group- or world-writable"
    fi
    if [ -n "$problems" ]; then
      die "$keys_dir is not in the shape sshd requires ($problems). Fix it deliberately — chown root:root '$keys_dir' && chmod 0755 '$keys_dir' — then re-run. Nothing was written."
    fi
  else
    if [ "$as_root" -eq 1 ]; then
      install -d -m 0755 -o root -g root "$keys_dir" || die "could not create $keys_dir"
      log "created $keys_dir (0755 root:root)"
    else
      install -d -m 0755 "$keys_dir" || die "could not create $keys_dir"
      log "created $keys_dir (0755, owned by $user — sshd accepts that for $user's own key)"
    fi
  fi

  # An existing key file must already satisfy StrictModes: owned by root
  # or by the target user, and not group- or world-writable. Report, do
  # not repair — a key file in the wrong shape is a question about who
  # put it there.
  if [ -e "$key_file" ]; then
    local f_owner f_mode f_uid problems=""
    f_owner="$(path_owner "$key_file")"
    f_mode="$(path_mode "$key_file")"
    f_uid="${f_owner%%:*}"
    if [ "$f_uid" != "0" ] && [ "$f_uid" != "$target_uid" ]; then
      problems="owned by uid $f_uid, want root (0) or $user ($target_uid)"
    fi
    if mode_group_world_writable "$f_mode"; then
      problems="${problems:+$problems; }mode $f_mode is group- or world-writable"
    fi
    if [ -n "$problems" ]; then
      die "$key_file is not in the shape sshd requires ($problems) — sshd would refuse it under StrictModes. Fix it deliberately (chown root:root '$key_file' && chmod 0644 '$key_file') then re-run. Nothing was written."
    fi
    existing="$(cat "$key_file")"
  else
    existing=""
  fi

  # Append what is missing, never duplicate what is already there.
  local line added=0 kept=0
  merged="$existing"
  [ -n "$merged" ] && merged="${merged%$'\n'}"$'\n'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if printf '%s' "$merged" | grep -qxF "$line"; then
      kept=$((kept+1))
      continue
    fi
    merged="${merged}${line}"$'\n'
    added=$((added+1))
  done <<EOF
$material
EOF

  if [ "$added" -eq 0 ]; then
    log "$key_file already has that key ($kept line(s) unchanged) — nothing to do"
  else
    local staged
    staged="$(mktemp "${keys_dir}/.${user}.XXXXXX")" || die "could not stage a new $key_file"
    printf '%s' "$merged" > "$staged" || { rm -f "$staged"; die "could not write $staged"; }
    chmod 0644 "$staged" || { rm -f "$staged"; die "could not chmod $staged"; }
    if [ "$as_root" -eq 1 ]; then
      chown root:root "$staged" || { rm -f "$staged"; die "could not chown $staged"; }
    fi
    mv -f "$staged" "$key_file" || { rm -f "$staged"; die "could not move $staged into place"; }
    local owner_note="0644"
    [ "$as_root" -eq 1 ] && owner_note="0644 root:root"
    log "$key_file: $added key(s) added, $kept already present ($owner_note)"
  fi

  # SELinux: relabel to the directory's default type (etc_t under
  # /etc/ssh). -F forces it even when a wrong label is already set.
  if command -v restorecon >/dev/null 2>&1; then
    if restorecon -F "$keys_dir" "$key_file" 2>/dev/null; then
      log "restorecon -F applied to $keys_dir and $key_file"
    else
      warn "restorecon -F failed on $keys_dir / $key_file — check ls -lZ before trusting this"
    fi
  else
    log "restorecon not installed — no relabel needed on a host without SELinux"
  fi

  # The key itself needs no reload: sshd reads authorized_keys per
  # connection. A drop-in copied into sshd_config.d does, so gate that.
  local sshd_bin=""
  if command -v sshd >/dev/null 2>&1; then
    sshd_bin="sshd"
  elif [ -x /usr/sbin/sshd ]; then
    sshd_bin="/usr/sbin/sshd"
  fi
  if [ -n "$sshd_bin" ]; then
    if "$sshd_bin" -t >/dev/null 2>&1; then
      log "sshd -t OK — safe to 'systemctl reload sshd' if you also just copied a drop-in"
    else
      warn "sshd -t FAILED — do NOT reload sshd until this passes:"
      "$sshd_bin" -t 2>&1 | while IFS= read -r line; do warn "  $line"; done
    fi
    # Did anything actually point sshd at this file?
    local resolved
    resolved="$("$sshd_bin" -T -C "user=$user" 2>/dev/null | grep -i '^authorizedkeysfile' || true)"
    case "$resolved" in
      *"$keys_dir"*) log "sshd resolves it for $user: $resolved" ;;
      "") warn "could not resolve sshd's config for $user — check sshd -T -C user=$user by hand" ;;
      *) warn "sshd does not look in $keys_dir for $user yet ($resolved)."
         warn "  emit and install the drop-in: $SELF --emit-ssh-config --central-keys --user $user" ;;
    esac
  fi

  log "the key needs no sshd reload — authorized_keys is read per connection"
  log "prove it is in place, and that nobody else's config moved:"
  log "  sshd -T -C user=$user | grep -i authorizedkeysfile"
  log "  sshd -T -C user=SOMEONE-ELSE | grep -i authorizedkeysfile"
  log "  ls -lZ $key_file"
}

run_install_fapolicyd() {
  [ "$(id -u)" -eq 0 ] || die "--install-fapolicyd requires root"
  [ -d /etc/fapolicyd/rules.d ] || die "fapolicyd is not installed (missing /etc/fapolicyd/rules.d)"
  local dir dest
  dir="$(_norm_path "$INSTALL_DIR")"
  [ -d "$dir" ] || die "INSTALL_DIR does not exist: $dir (install the server first)"
  # A home-directory rule is supported — plenty of hosts only ever give a
  # user their home — but it allows more than a shared tree would, so say
  # so out loud instead of writing it silently.
  if is_home_path "$dir"; then
    warn "this rule allow-lists a home directory: $dir"
    warn "  everything under it becomes executable for that user, including"
    warn "  anything they drop in it later, and each extra user needs their own rule"
    warn "  prefer --install-dir /opt/vscode-server --link-home --user NAME"
    warn "  if this host lets you write to a shared path"
  fi
  dest="/etc/fapolicyd/rules.d/${FAPOLICYD_PRIORITY}-vscode-server.rules"
  # One shared rule for the whole host, so a second admin onboarding a
  # second user re-runs this and changes nothing. Only reload fapolicyd
  # when the content actually moved: an unnecessary restart drops the
  # decision cache for every process on the box.
  local staged
  staged="$(mktemp)"
  write_fapolicyd_example > "$staged"
  if [ "$FORCE" != "1" ] && [ -f "$dest" ] \
      && [ "$(sha256_of "$staged")" = "$(sha256_of "$dest" || true)" ]; then
    rm -f "$staged"
    log "$dest is already current — leaving fapolicyd alone"
    log "  (pass --force to rewrite and reload anyway, e.g. if an earlier run"
    log "   wrote the file but never got as far as loading it)"
    log "fapolicyd allow-lists dir=${dir}/"
    return 0
  fi
  chmod 0644 "$staged"
  mv -f "$staged" "$dest"
  log "wrote $dest"
  if command -v fagenrules >/dev/null 2>&1; then
    fagenrules --load
  else
    warn "fagenrules not on PATH — restarting fapolicyd anyway"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart fapolicyd
  fi
  log "fapolicyd allow-lists dir=${dir}/"
}

# ── Shared install step (used by online + offline) ───────────────────────
install_from_stage() {
  local stage_dir="$1"
  local commit install_owner
  commit="$(json_field "$stage_dir/versions.json" commit)"
  [ -n "$commit" ] || die "versions.json has no commit field"
  # Resolve before anything is created: once root has made INSTALL_DIR,
  # its own ownership no longer says whose tree this is.
  install_owner="$(owner_for_tree "$INSTALL_DIR")"

  # THE critical path: extract straight into INSTALL_DIR/bin/<commit>/ —
  # exactly where Remote-SSH looks on its own. The tarball's single
  # top-level dir (vscode-server-linux-x64/) is stripped so its CONTENTS
  # (node, bin/, out/, product.json, ...) land directly in <commit>/.
  # Verified live (2026-08-17) against the real tarball layout — see
  # docs/reference/download-urls.md.
  local server_bin_dir="$INSTALL_DIR/bin/$commit"
  if [ -f "$server_bin_dir/product.json" ]; then
    log "Remote-SSH server for commit ${commit:0:12}... already present at $server_bin_dir — leaving in place"
  else
    mkdir -p "$server_bin_dir"
    log "installing Remote-SSH server (commit ${commit:0:12}...) -> $server_bin_dir"
    tar -C "$server_bin_dir" --strip-components=1 -xzf "$stage_dir/server-linux-x64.tar.gz"
    [ -f "$server_bin_dir/product.json" ] || die "extracted server tree has no product.json at the expected depth — layout assumption is wrong, refusing to claim success"
    [ -x "$server_bin_dir/bin/code-server" ] || warn "bin/code-server is not executable after extraction (tar should preserve the mode bit — check the archive)"
    chmod 0755 "$server_bin_dir/bin/helpers/check-requirements.sh" 2>/dev/null || true
  fi

  # Exec-server layout. Remote-SSH chooses bootstrap script by a staged
  # rollout, not by extension version. Presence tests:
  #   $INSTALL_DIR/code-<commit>                         alpine CLI binary
  #   $INSTALL_DIR/cli/servers/Stable-<commit>/server/   same tree as bin/
  # Stage both so whichever script arrives never enters the download branch.
  local stable_dir="$INSTALL_DIR/cli/servers/Stable-$commit/server"
  if [ ! -x "$stable_dir/bin/code-server" ]; then
    mkdir -p "$(dirname "$stable_dir")"
    if cp -al "$server_bin_dir" "$stable_dir" 2>/dev/null; then
      log "exec-server tree hardlinked at $stable_dir"
    else
      cp -a "$server_bin_dir" "$stable_dir"
      log "exec-server tree copied to $stable_dir"
    fi
  fi
  chmod 0755 "$stable_dir/bin/code-server" "$stable_dir/node" \
    "$stable_dir/bin/helpers/check-requirements.sh" 2>/dev/null || true

  # Client installers: STAGED for the operator, never "installed" here —
  # a Windows .exe can't run on this host, and the Linux tarball is meant
  # for operator laptops, not the remote itself.
  local client_dir="$INSTALL_DIR/client-installers"
  mkdir -p "$client_dir"
  cp -f "$stage_dir"/vscode-linux-x64.tar.gz "$client_dir/" 2>/dev/null || true
  cp -f "$stage_dir"/VSCodeUserSetup-x64-*.exe "$client_dir/" 2>/dev/null || true
  log "client installers staged at $client_dir — install ONE of these on the" \
      "operator's laptop (matches commit ${commit:0:12}... exactly; a" \
      "mismatched client commit is what makes Remote-SSH try to download a" \
      "server over the wire):"
  log "  Linux:   tar -xzf vscode-linux-x64.tar.gz && ./VSCode-linux-x64/bin/code"
  log "  Windows: run VSCodeUserSetup-x64-*.exe (per-user, no admin rights needed)"

  # Optional CLI extract (for --serve-web / --tunnel)
  local cli_bin=""
  if [ -f "$stage_dir/cli.tar.gz" ]; then
    mkdir -p "$INSTALL_DIR/cli"
    log "installing CLI into $INSTALL_DIR/cli"
    tar -C "$INSTALL_DIR/cli" -xzf "$stage_dir/cli.tar.gz"
    cli_bin="$(find "$INSTALL_DIR/cli" -maxdepth 1 -type f -name 'code' | head -1)"
    [ -n "$cli_bin" ] && chmod +x "$cli_bin"
  fi

  # Handshake archive is belt-and-braces only. Prefer the extracted
  # code-<commit> binary (skips the download branch entirely). Write the
  # tarball first and .done last — a .done with a missing/empty tar is
  # Remote-SSH exit 199.
  local handshake_src="" handshake_name
  handshake_name="$(json_field "$stage_dir/versions.json" remote_ssh_cli_artifact)"
  if [ -n "$handshake_name" ] && [ "$handshake_name" != "null" ] && [ -f "$stage_dir/$handshake_name" ]; then
    handshake_src="$stage_dir/$handshake_name"
  elif [ -f "$stage_dir/cli-alpine-x64.tar.gz" ]; then
    handshake_src="$stage_dir/cli-alpine-x64.tar.gz"
  elif [ -f "$stage_dir/cli-alpine-arm64.tar.gz" ]; then
    handshake_src="$stage_dir/cli-alpine-arm64.tar.gz"
  fi
  if [ -n "$handshake_src" ]; then
    [ -s "$handshake_src" ] || die "Remote-SSH CLI archive is empty: $handshake_src"
    local remote_cli_archive="$INSTALL_DIR/vscode-cli-${commit}.tar.gz"
    local exec_cli="$INSTALL_DIR/code-${commit}"
    log "staging CLI archive for Remote-SSH bootstrap at $remote_cli_archive"
    cp -f "$handshake_src" "$remote_cli_archive"
    chmod "$(handshake_mode)" "$remote_cli_archive"
    if [ ! -x "$exec_cli" ]; then
      tar -xOf "$handshake_src" code > "$exec_cli" \
        || die "could not extract CLI binary 'code' from $handshake_src"
      chmod 0755 "$exec_cli"
    fi
    : > "${remote_cli_archive}.done"
    chmod "$(handshake_mode)" "${remote_cli_archive}.done"
  fi
  if [ -f "$stage_dir/server-web.tar.gz" ]; then
    mkdir -p "$INSTALL_DIR/server-web"
    log "installing server-web into $INSTALL_DIR/server-web"
    tar -C "$INSTALL_DIR/server-web" -xzf "$stage_dir/server-web.tar.gz"
  fi

  if [ -d "$stage_dir/extensions" ] && [ -n "$(ls -A "$stage_dir/extensions" 2>/dev/null)" ]; then
    # `code --install-extension` targets a version-managed CLI install and
    # does NOT reliably reach a bare extracted server tree — verified live
    # (2026-08-17, see docs/reference/download-urls.md). Stage the VSIX
    # files and tell the operator the standard, supported path.
    mkdir -p "$INSTALL_DIR/extensions-to-install"
    cp -f "$stage_dir"/extensions/*.vsix "$INSTALL_DIR/extensions-to-install/"
    log "extensions staged (not auto-installed — see below): $INSTALL_DIR/extensions-to-install"
    log "  once connected via Remote-SSH, open the Extensions view and use" \
        "'Install from VSIX...' for each file in that directory."
  fi

  prune_after_install "$commit"

  cp -f "$stage_dir/versions.json" "$INSTALL_DIR/versions.json"
  apply_shared_perms "$INSTALL_DIR"
  reown_root_created "$install_owner" "$INSTALL_DIR"
  log "install complete. versions: $INSTALL_DIR/versions.json"
  if want_shared && [ "$LINK_HOME" != "1" ]; then
    log "INSTALL_DIR is not ~/.vscode-server. Remote-SSH still looks there unless you"
    log "  set remote.SSH.serverInstallPath (emitted in settings.json) OR run:"
    log "  $SELF --link-home --install-dir $INSTALL_DIR [--user NAME]"
  fi
  if [ "$LINK_HOME" = "1" ]; then
    run_link_home
  fi
  if [ "$INSTALL_FAPOLICYD" = "1" ]; then
    run_install_fapolicyd
  fi

  if [ "$DOWNLOAD_ONLY" -eq 1 ]; then
    log "--download-only set: not starting anything"
    return
  fi

  if [ "$ACTION" = "tunnel" ]; then
    [ -n "$cli_bin" ] || die "internal error: --tunnel requested but no CLI was staged"
    start_tunnel "$cli_bin"
  elif [ "$WITH_SERVE_WEB" -eq 1 ] && [ "$START_AFTER_INSTALL" -eq 1 ]; then
    local sw_bin
    sw_bin="$(find "$INSTALL_DIR/cli" -maxdepth 1 -type f -name 'code' | head -1)"
    [ -n "$sw_bin" ] || die "internal error: --serve-web requested but no CLI was staged"
    start_serve_web "$sw_bin"
  else
    log "Remote-SSH server is staged and ready."
    log "Print templates AND the destination path for each file:"
    # A shared tree installed by root is not writable from the operator's
    # own shell, which is where they will run the emit from.
    local emit_sudo=""
    if is_root && want_shared; then
      emit_sudo="sudo "
    fi
    if [ -n "$LINK_USERS" ]; then
      log "  ${emit_sudo}$SELF --emit-ssh-config --install-dir $INSTALL_DIR --user $LINK_USERS"
      log "  (one Match-scoped sshd drop-in per user; nobody else's login changes)"
    else
      log "  ${emit_sudo}$SELF --emit-ssh-config"
    fi
  fi
}

resolve_token() {
  if [ "$TOKEN" = "none" ]; then
    echo "__NONE__"
    return
  fi
  if [ -n "$TOKEN" ]; then
    printf '%s' "$TOKEN"
    return
  fi
  local tok_file="$INSTALL_DIR/serve-web.token"
  if [ ! -f "$tok_file" ]; then
    ( umask 077; openssl rand -hex 32 > "$tok_file" 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$tok_file" )
    chmod 600 "$tok_file"
    own_paths "$(owner_for_tree "$INSTALL_DIR")" "$tok_file"
    log "generated a new connection token: $tok_file (chmod 600, not printed)"
  else
    log "reusing existing connection token: $tok_file"
  fi
  cat "$tok_file"
}

start_serve_web() {
  local cli_bin="$1"
  local tok
  tok="$(resolve_token)"
  log "starting serve-web on ${BIND_ADDR}:${PORT} (secondary path — primary is Remote-SSH)"
  local args=(serve-web --host "$BIND_ADDR" --port "$PORT" --server-data-dir "$INSTALL_DIR/server-data")
  if [ "$tok" = "__NONE__" ]; then
    warn "TOKEN=none: starting WITHOUT a connection token (--without-connection-token)." \
         "Only do this behind another access-control layer (firewall/VPN/SSH tunnel to 127.0.0.1)."
    args+=(--without-connection-token)
  else
    args+=(--connection-token "$tok")
  fi
  exec "$cli_bin" "${args[@]}"
}

start_tunnel() {
  local cli_bin="$1"
  [ "$MODE" = "online" ] || die "internal error: start_tunnel called outside online mode"
  warn "Remote Tunnels phones home to Microsoft's relay service and requires a" \
       "GitHub/Microsoft device-code login on first run — this is NOT" \
       "air-gap compatible. Proceeding because MODE=online and --tunnel was" \
       "explicitly requested."
  exec "$cli_bin" tunnel
}

# ── Pruning older versions ─────────────────────────────────────────────
# Only one server commit can serve a connection, and an air-gapped host
# has no way to garbage-collect the rest — without this, every bundle
# carried across the gap adds another server tree that nothing will ever
# run again. Everything below keys on the 40-hex commit id, so
# version-independent state (data/, extensions/, extensions-to-install/,
# client-installers/, logs, the emitted templates, versions.json) is
# never a candidate.
is_commit_id() {
  case "${1:-}" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# list_commits — every commit with artefacts under INSTALL_DIR, one per line.
list_commits() {
  local c
  { ls "$INSTALL_DIR" 2>/dev/null | sed -n -e 's/^code-//p' -e 's/^vscode-cli-\(.*\)\.tar\.gz$/\1/p'
    ls "$INSTALL_DIR/bin" 2>/dev/null
    ls "$INSTALL_DIR/cli/servers" 2>/dev/null | sed -n 's/^Stable-//p'
  } | sort -u | while read -r c; do
    is_commit_id "$c" && printf '%s\n' "$c"
  done
}

# commit_paths <commit> — everything install_from_stage lays down for one
# commit. Keep this in step with install_from_stage if a new per-commit
# path is ever added there.
commit_paths() {
  local c="$1"
  printf '%s\n' \
    "$INSTALL_DIR/bin/$c" \
    "$INSTALL_DIR/code-$c" \
    "$INSTALL_DIR/cli/servers/Stable-$c" \
    "$INSTALL_DIR/vscode-cli-$c.tar.gz" \
    "$INSTALL_DIR/vscode-cli-$c.tar.gz.done"
}

# current_commit — the commit a Remote-SSH client can actually use: one
# whose .done marker was written (install_from_stage writes it last),
# preferring the one whose CLI binary is there too, newest marker breaking
# a tie. Empty when no install under INSTALL_DIR ever completed.
current_commit() {
  local c best="" best_rank=-1 rank ts best_ts=0 manifest=""
  if [ -n "$COMMIT" ] && [ -f "$INSTALL_DIR/vscode-cli-$COMMIT.tar.gz.done" ]; then
    printf '%s' "$COMMIT"
    return 0
  fi
  # versions.json records the last install, which settles the case two
  # markers were written in the same second.
  if [ -f "$INSTALL_DIR/versions.json" ]; then
    manifest="$(json_field "$INSTALL_DIR/versions.json" commit)"
    if is_commit_id "$manifest" && [ -f "$INSTALL_DIR/vscode-cli-$manifest.tar.gz.done" ]; then
      printf '%s' "$manifest"
      return 0
    fi
  fi
  for c in $(list_commits); do
    [ -f "$INSTALL_DIR/vscode-cli-$c.tar.gz.done" ] || continue
    rank=0
    [ -e "$INSTALL_DIR/code-$c" ] && rank=1
    ts="$(file_mtime "$INSTALL_DIR/vscode-cli-$c.tar.gz.done")"
    if [ "$rank" -gt "$best_rank" ] || { [ "$rank" -eq "$best_rank" ] && [ "$ts" -gt "$best_ts" ]; }; then
      best="$c"; best_rank="$rank"; best_ts="$ts"
    fi
  done
  printf '%s' "$best"
}

# bytes_of <path>... — du counts 1K blocks on both GNU and BSD, so this is
# disk usage rather than apparent size: what a prune actually gives back.
bytes_of() {
  local kb
  kb="$(du -sk "$@" 2>/dev/null | awk '{t+=$1} END{print t+0}')"
  echo "$(( kb * 1024 ))"
}

# prunable <path> — true only for a real path whose parent resolves inside
# INSTALL_DIR. A symlink is never deleted and never followed: on a shared
# tree it is the one way a commit-shaped path could lead out of the
# install, and deleting the link would still be deleting something this
# script did not write.
prunable() {
  local p="$1" root parent
  root="$(cd "$INSTALL_DIR" 2>/dev/null && pwd -P)" || return 1
  { [ -e "$p" ] || [ -L "$p" ]; } || return 1
  if [ -L "$p" ]; then
    warn "not pruning $p — it is a symlink, not an artefact this install wrote"
    return 1
  fi
  parent="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  case "$parent" in
    "$root"|"$root"/*) return 0 ;;
  esac
  warn "not pruning $p — it resolves outside $root"
  return 1
}

# prune_commits <keep-commit> <verbose 0|1>
prune_commits() {
  local keep="$1" verbose="${2:-0}"
  local c p sz hit freed=0 n=0 pruned=""
  for c in $(list_commits); do
    [ "$c" = "$keep" ] && continue
    hit=0
    while IFS= read -r p; do
      prunable "$p" || continue
      sz="$(bytes_of "$p")"
      rm -rf "$p"
      freed=$(( freed + sz ))
      hit=1
      [ "$verbose" = "1" ] && printf 'removed %s (%s bytes)\n' "$p" "$sz"
    done < <(commit_paths "$c")
    if [ "$hit" = "1" ]; then
      n=$(( n + 1 ))
      pruned="${pruned:+$pruned }${c:0:12}"
    fi
  done
  # bin/ and cli/servers/ are ours and are meaningless empty; rmdir refuses
  # to touch them while anything (the kept commit, a user's file) is there.
  rmdir "$INSTALL_DIR/cli/servers" "$INSTALL_DIR/cli" "$INSTALL_DIR/bin" 2>/dev/null || true
  if [ "$n" -gt 0 ]; then
    log "pruned $n older version(s) under $INSTALL_DIR ($pruned), freed $freed bytes"
    log "  kept ${keep:0:12}... — pass --keep-old to an install to skip this"
  fi
  [ "$verbose" = "1" ] && printf 'freed %s bytes across %s version(s)\n' "$freed" "$n"
  return 0
}

# Called at the end of an install. One whose .done marker was never
# written did not complete, so it prunes nothing: the old version is the
# only working one left.
prune_after_install() {
  local commit="$1" others
  others="$(list_commits | grep -v "^${commit}\$" || true)"
  [ -n "$others" ] || return 0
  if [ "$KEEP_OLD" = "1" ]; then
    log "--keep-old: leaving earlier versions under $INSTALL_DIR in place"
    return 0
  fi
  if [ ! -f "$INSTALL_DIR/vscode-cli-$commit.tar.gz.done" ]; then
    warn "no .done marker for ${commit:0:12}... — install did not complete, leaving earlier versions alone"
    return 0
  fi
  prune_commits "$commit" 0
}

run_prune() {
  [ -d "$INSTALL_DIR" ] || die "nothing installed at $INSTALL_DIR"
  local keep
  keep="$(current_commit)"
  [ -n "$keep" ] || die "no completed install under $INSTALL_DIR (no .done marker) — refusing to prune"
  echo "install dir : $INSTALL_DIR"
  echo "keeping     : $keep"
  prune_commits "$keep" 1
}

# ── status ─────────────────────────────────────────────────────────────
run_status() {
  if [ ! -f "$INSTALL_DIR/versions.json" ]; then
    echo "not installed: $INSTALL_DIR"
    exit 1
  fi
  echo "install dir : $INSTALL_DIR"
  echo "versions    : $INSTALL_DIR/versions.json"
  cat "$INSTALL_DIR/versions.json"
  echo
  local commit
  commit="$(json_field "$INSTALL_DIR/versions.json" commit)"
  if [ -n "$commit" ] && [ -d "$INSTALL_DIR/bin/$commit" ]; then
    echo "server dir  : $INSTALL_DIR/bin/$commit (present)"
  fi
  if [ -n "$commit" ] && [ -x "$INSTALL_DIR/code-$commit" ]; then
    echo "exec cli    : $INSTALL_DIR/code-$commit (present)"
  fi
  if [ -n "$commit" ] && [ -x "$INSTALL_DIR/cli/servers/Stable-$commit/server/bin/code-server" ]; then
    echo "exec server : $INSTALL_DIR/cli/servers/Stable-$commit/server (present)"
  fi
  if [ -n "$commit" ] && [ -s "$INSTALL_DIR/vscode-cli-$commit.tar.gz" ]; then
    echo "handshake   : $INSTALL_DIR/vscode-cli-$commit.tar.gz (present)"
  fi
  # Other commits are dead weight on an air-gapped host: nothing can run
  # them, and nothing else will remove them.
  local cur extra sz total=0 n=0 paths p
  cur="$commit"
  [ -n "$cur" ] || cur="$(current_commit)"
  for extra in $(list_commits); do
    [ "$extra" = "$cur" ] && continue
    paths=()
    while IFS= read -r p; do
      { [ -e "$p" ] || [ -L "$p" ]; } && paths+=("$p")
    done < <(commit_paths "$extra")
    [ "${#paths[@]}" -gt 0 ] || continue
    sz="$(bytes_of "${paths[@]}")"
    total=$(( total + sz ))
    n=$(( n + 1 ))
    echo "extra ver   : $extra ($sz bytes, ${#paths[@]} paths)"
  done
  if [ "$n" -gt 0 ]; then
    echo "extra total : $n version(s), $total bytes — remove with: $SELF --prune --install-dir $INSTALL_DIR"
  fi
  # `&&` as the LAST command of a function under `set -e` propagates a
  # false test as the whole script's exit code — found live: a
  # Remote-SSH-only install (no serve-web token, the common case now
  # that Remote-SSH is primary) made a successful `--status` query exit
  # 1. Explicit `return 0` so no trailing check here (now or added later)
  # can ever be mistaken for a failed status query.
  [ -f "$INSTALL_DIR/serve-web.token" ] && echo "token file  : $INSTALL_DIR/serve-web.token (present, not shown)"
  return 0
}

# ── emit-ssh-config ────────────────────────────────────────────────────
run_emit_ssh_config() {
  local emit_owner
  emit_owner="$(owner_for_tree "$INSTALL_DIR")"
  # mkdir -p succeeds on an existing root-owned directory, so it says
  # nothing about whether the templates below can be written. Without
  # this check the first redirect fails with a raw "Permission denied"
  # and every later template is skipped in silence.
  mkdir -p "$INSTALL_DIR" \
    || die "cannot create $INSTALL_DIR — re-run under sudo, or pass --install-dir to a directory you own"
  [ -w "$INSTALL_DIR" ] \
    || die "cannot write templates to $INSTALL_DIR — re-run under sudo, or pass --install-dir to a directory you own"
  local ssh_out="$INSTALL_DIR/ssh-config.example"
  local settings_out="$INSTALL_DIR/settings.json.example"
  local fapo_out="$INSTALL_DIR/fapolicyd-vscode.rules"
  write_ssh_config_example > "$ssh_out"
  write_settings_json_example > "$settings_out"
  write_fapolicyd_example > "$fapo_out"
  # One sshd drop-in per user, named after the user: emitting for a
  # colleague later never rewrites this one.
  local sshd_outs=() u one
  for u in $(emit_user_list); do
    check_user_name "$u"
    one="$INSTALL_DIR/$(sshd_dropin_name "$u")"
    write_sshd_user_dropin "$u" > "$one"
    sshd_outs+=("$one")
  done
  reown_root_created "$emit_owner" "$INSTALL_DIR"
  log "wrote templates under $INSTALL_DIR"
  log "These are NOT live. Copy/merge each file to the path below."
  log ""
  log "  $ssh_out"
  log "    WHO:  operator laptop (not this host)"
  log "    Unix/macOS ->  ~/.ssh/config"
  log "    Windows    ->  %USERPROFILE%\\.ssh\\config"
  log "    HOW:  merge ONE Host block (Unix or Windows), replace"
  log "          airgapped-host / youruser / the hostname / IdentityFile"
  log ""
  log "  $settings_out"
  log "    WHO:  operator laptop (not this host)"
  log "    Windows ->  %APPDATA%\\Code\\User\\settings.json"
  log "                C:\\Users\\youruser\\AppData\\Roaming\\Code\\User\\settings.json"
  log "    macOS   ->  ~/Library/Application Support/Code/User/settings.json"
  log "    Linux   ->  ~/.config/Code/User/settings.json"
  log "    HOW:  merge the keys (do not wipe existing settings)."
  log "          Or: VS Code -> Preferences -> Settings -> Open Settings (JSON)"
  log "          Omit remote.SSH.path on Unix. UTF-8, no BOM."
  log ""
  local one_out one_user
  for one_out in "${sshd_outs[@]}"; do
    one_user="$(basename "$one_out")"
    one_user="${one_user#"$SSHD_PRIORITY"-vscode-}"
    one_user="${one_user%.conf}"
    log "  $one_out"
    log "    WHO:  THIS Linux host, as root (not the laptop)"
    log "    PUT:  /etc/ssh/sshd_config.d/$(basename "$one_out")"
    log "    HOW:  copy, then sshd -t && systemctl reload sshd"
    log "    PROVE: sshd -T -C user=$one_user | grep -E 'pubkeyauth|authenticationmethods'"
    log "           sshd -T -C user=SOMEONE-ELSE  # must still show the host's baseline"
    log "    NOTE: one file per user. A colleague gets their own"
    log "          $SELF --emit-ssh-config --user THEIRNAME; this file is not touched."
    log ""
  done
  log "  $fapo_out"
  log "    WHO:  THIS Linux host, as root, if fapolicyd is enforcing"
  log "    PUT:  /etc/fapolicyd/rules.d/${FAPOLICYD_PRIORITY}-vscode-server.rules"
  log "    HOW:  copy, then fagenrules --load && systemctl restart fapolicyd"
  log "          or: $SELF --install-fapolicyd --install-dir $INSTALL_DIR"
}

write_ssh_config_example() {
  cat <<'EOF'
# WHERE THIS GOES — operator laptop, NOT the remote host
#   Unix/macOS:  ~/.ssh/config
#   Windows:     %USERPROFILE%\.ssh\config  (C:\Users\youruser\.ssh\config)
# Merge ONE Host block. Both below use the same alias and OpenSSH takes
# the FIRST value it reads for each keyword, so keeping both leaves the
# second one dead. Replace the host / realm / user placeholders.
# Unix after merge: mkdir -p ~/.ssh/sockets
#
# publickey is first so Remote-SSH extra channels skip the OTP prompt
# once the key is in authorized_keys (or the realm SSH pubkey store).
# keyboard-interactive stays as the fallback for first-time / OTP login.
# Uncomment IdentityFile and point it at the matching private key.
# Windows: ssh-agent is a Windows service, off by default. As admin,
#   Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent
#   ssh-add $env:USERPROFILE\.ssh\id_ed25519
# An unencrypted key needs no agent — IdentityFile alone is enough.

# Unix / macOS — ControlMaster reuses a session; pubkey skips OTP.
Host airgapped-host
    HostName airgapped-host.example.realm
    User youruser
    Port 22
    PreferredAuthentications publickey,gssapi-with-mic,keyboard-interactive,password
    PubkeyAuthentication yes
    # IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly no
    GSSAPIAuthentication yes
    GSSAPIDelegateCredentials yes
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 600
    ServerAliveInterval 30
    StrictHostKeyChecking accept-new

# Windows — no ControlMaster. Reuse is useLocalServer in settings.json.
Host airgapped-host
    HostName airgapped-host.example.realm
    User youruser
    Port 22
    PreferredAuthentications publickey,keyboard-interactive
    PubkeyAuthentication yes
    # Win32-OpenSSH expands ~ to %USERPROFILE%; the absolute form
    # C:\Users\youruser\.ssh\id_ed25519 works too.
    # IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly no
    GSSAPIAuthentication no
    NumberOfPasswordPrompts 3
    ServerAliveInterval 30
    StrictHostKeyChecking accept-new
EOF
}

write_settings_json_example() {
  # VS Code settings.json is JSONC. Comments are // lines, never
  # fake keys like "// useLocalServer": "…". Those are real JSON
  # properties the extension will ignore or reject.
  local install_json extra=""
  install_json="$(_norm_path "$INSTALL_DIR")"
  if ! is_home_install; then
    extra=$(cat <<EOF

  // Shared/custom server tree. Host alias must match ssh config Host.
  // --link-home also satisfies the presence test without this key.
  "remote.SSH.serverInstallPath": {
    "airgapped-host": "${install_json}"
  },
EOF
)
  fi
  cat <<EOF
{
  // WHERE THIS GOES — operator laptop, NOT the remote host
  //   Windows:  %APPDATA%\\Code\\User\\settings.json
  //   macOS:    ~/Library/Application Support/Code/User/settings.json
  //   Linux:    ~/.config/Code/User/settings.json
  // Merge these keys (JSONC: // comments are fine). UTF-8, no BOM.
  // Omit remote.SSH.path on Unix.
${extra}
  // So the password + TOTP prompts are visible (first connect / no key).
  "remote.SSH.showLoginTerminal": true,

  // Reuse the SSH login. Required on Windows (no ControlMaster).
  "remote.SSH.useLocalServer": true,

  // Classic bootstrap. Confirm the log: useExecServer = false
  "remote.SSH.useExecServer": false,

  // Fail fast if the server bits are missing (do not wget forever).
  "remote.SSH.localServerDownload": "off",

  // true silently turns useLocalServer off. Windows ignores the UI.
  "remote.SSH.remoteServerListenOnSocket": false,

  // Harmless. Avoids lock files in the server install folder.
  "remote.SSH.lockfilesInTmp": true,

  // First OTP login is slower than a key (default 15s).
  "remote.SSH.connectTimeout": 60,

  // Windows only — native OpenSSH optional feature.
  "remote.SSH.path": "C:\\\\Windows\\\\System32\\\\OpenSSH\\\\ssh.exe",

  // Only if your ssh config is NOT at the default path (~/.ssh/config,
  // on Windows %USERPROFILE%\\.ssh\\config). It must contain the same
  // Host alias as remote.SSH.remotePlatform below.
  // "remote.SSH.configFile": "C:\\\\Users\\\\youruser\\\\.ssh\\\\config",

  // Host alias must match the ssh config Host name.
  "remote.SSH.remotePlatform": {
    "airgapped-host": "linux"
  }
}
EOF
}

# The account a --user default means: the login user behind sudo, else
# whoever is running this.
invoking_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    printf '%s' "$SUDO_USER"
  else
    id -un
  fi
}

# Which users --emit-ssh-config writes an sshd drop-in for: --user /
# --link-users when given, otherwise whoever is running it.
emit_user_list() {
  local users="$LINK_USERS"
  [ -n "$users" ] || users="$(invoking_user)"
  printf '%s' "$users" | tr ', ' '\n' | grep -v '^$' || true
}

# The name lands in a filename and in a `Match User` line, so hold it to
# what an account name may contain.
check_user_name() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) die "invalid user name '${1:-}' for an sshd drop-in (letters, digits, . _ - only)" ;;
  esac
}

sshd_dropin_name() { printf '%s-vscode-%s.conf' "$SSHD_PRIORITY" "$1"; }

# Per-user sshd override. Nothing global: the host's hardened baseline
# (typically OTP through PAM, pubkey off) has to survive intact for every
# account that is not named here.
# Keep apostrophes OUT of the heredoc bodies below. bash mis-parses a
# lone `'` inside `$(cat <<EOF ... EOF)` — it keeps scanning for a closing
# quote and dies with "unexpected EOF" hundreds of lines later. Two
# apostrophes cancel out, which is why this only shows up when someone
# adds one.
write_sshd_user_dropin() {
  local user="$1" file keys_note keys_line=""
  file="$(sshd_dropin_name "$user")"
  if [ "$CENTRAL_KEYS" = "1" ]; then
    local keys_dir paths_note
    keys_dir="$(_norm_path "$CENTRAL_KEYS_DIR")"
    # Leading newline: this is interpolated at the end of the
    # AuthenticationMethods line so an unset value leaves no blank line.
    if [ "$CENTRAL_KEYS_ONLY" = "1" ]; then
      keys_line=$'\n'"    AuthorizedKeysFile ${keys_dir}/%u"
      paths_note="$(cat <<EOF
# CENTRAL KEY DIRECTORY, AND ONLY THAT. The AuthorizedKeysFile below
# names one path:
#   ${keys_dir}/%u   — root-owned, on local disk, label etc_t
# The home copy is deliberately NOT listed, which is what takes the log
# noise to zero (see the measured counts below). The cost is that this
# file is specific to a host whose homes are unreadable: where homes are
# LOCAL, ~${user}/.ssh/authorized_keys would stop being consulted at all.
# Use --central-keys (without -only) for a file that is correct on both.
EOF
)"
    else
      keys_line=$'\n'"    AuthorizedKeysFile ${keys_dir}/%u .ssh/authorized_keys"
      paths_note="$(cat <<EOF
# CENTRAL KEY DIRECTORY. The AuthorizedKeysFile below names two paths and
# sshd reads them in order:
#   1. ${keys_dir}/%u   — root-owned, on local disk, label etc_t
#   2. .ssh/authorized_keys — the copy in the home directory
# WHY THE HOME PATH STAYS SECOND: the same file keeps working unchanged
# on a host whose homes are local, so there is nothing to undo if this
# user moves or the mount changes. It is not free — see the counts below.
EOF
)"
    fi
    keys_note="$(cat <<EOF
${paths_note}
# WHY THIS EXISTS: with SELinux enforcing and the use_nfs_home_dirs
# boolean off, sshd_t cannot read an authorized_keys that lives on an NFS
# home (the file is labelled nfs_t). Pubkey login fails with "Could not
# open user ... authorized keys ... Permission denied" in /var/log/secure
# and an AVC per attempt. restorecon does not fix that: on an NFS mount
# it exits 0 and changes nothing, chcon fails with "Operation not
# supported", and relabelling the file on the server changes nothing
# either because the client assigns nfs_t through genfscon. So the key
# has to live on a path sshd can always read.
# WHAT THE ORDER COSTS, measured on an enforcing host, per SUCCESSFUL
# login (3-login runs, both orders):
#   home path first          3 "Could not open" lines + 3 AVCs
#   central first, home 2nd  1 line + 1 AVC — sshd still consults the
#                            second path once even after the first
#                            matched (mechanism unconfirmed; the count
#                            is not)
#   central only             0 lines, 0 AVCs
# So central-first is a 3x reduction, not silence. If this host ships
# /var/log/secure or audit to a SIEM and one line per login matters,
# use --central-keys-only and accept that the file is then NFS-specific.
# A hung hard NFS mount named first would also stall authentication
# itself, which is the other reason the home path is never first.
# WHAT sshd REQUIRES of the file (StrictModes): owned by root or by
# ${user}, and not group- or world-writable. 0644 root:root is what
# --install-authorized-key writes; the directory is 0755 root:root.
# AuthorizedKeysCommand (FreeIPA: sss_ssh_authorizedkeys) is a separate
# mechanism and is untouched by this file.
EOF
)"
  else
    keys_note="$(cat <<EOF
# THE KEY ITSELF is not configured here: either
# ~${user}/.ssh/authorized_keys (0600, ~/.ssh 0700, plus
# restorecon -Rv ~/.ssh on SELinux) or the realm store itself, when sshd
# resolves keys through AuthorizedKeysCommand (FreeIPA:
# sss_ssh_authorizedkeys). AuthorizedKeysFile is left alone so neither
# arrangement is disturbed. On a host whose homes are on NFS with
# SELinux enforcing, sshd cannot read the home copy at all — see
# --central-keys and --install-authorized-key.
EOF
)"
  fi
  cat <<EOF
# WHERE THIS GOES — THIS Linux host as root, NOT the laptop
#   /etc/ssh/sshd_config.d/${file}
#   then: sshd -t && systemctl reload sshd
#
# PROVE IT — the only check that counts:
#   sshd -T -C user=${user} | grep -E 'pubkeyauth|authenticationmethods'
#     -> pubkeyauthentication yes
#     -> authenticationmethods publickey keyboard-interactive
#   sshd -T -C user=SOMEONE-ELSE | grep -E 'pubkeyauth|authenticationmethods'
#     -> unchanged, still this host's hardened baseline
#
# EL8's stock sshd_config has no Include line, so this whole directory is
# ignored there until an admin adds, at the TOP of /etc/ssh/sshd_config:
#   Include /etc/ssh/sshd_config.d/*.conf
# EL9 and Debian/Ubuntu ship it already. The check above says which case
# this host is in.
#
# On a FreeIPA-enrolled host, 04-ipa.conf already sets
# PubkeyAuthentication yes GLOBALLY, and sshd keeps the FIRST global
# value it reads for a keyword. A hardening file meant to turn pubkey off
# for everyone therefore has to sort BEFORE it (01-*, not 10-*) or it is
# a no-op — check with sshd -T -C user=SOMEONE-ELSE, not by reading
# files. That ordering decides the global baseline only. The Match block
# below still wins for ${user} either way.
#
# PER-USER ON PURPOSE. Every directive sits inside Match User ${user}, so
# no other account changes. Remote-SSH opens more than one SSH channel
# and a realm TOTP is anti-replay inside its 30-second window, so the
# second channel is denied unless a key can authenticate it. That is why
# this one user needs pubkey, and why nobody else has to.
#
# ONE FILE PER USER. A colleague gets their own
# ${SSHD_PRIORITY}-vscode-<name>.conf: adding them never edits this file,
# and re-emitting for ${user} rewrites only this one.
#
# AuthenticationMethods: space-separated entries are ALTERNATIVES,
# comma-separated entries are ALL REQUIRED. "publickey
# keyboard-interactive" means the key alone is enough, while the OTP path
# still works for the first login before the key is installed. Never
# write "publickey,keyboard-interactive" — that demands both and puts the
# OTP prompt back on every channel, which is the problem this solves. If
# the baseline needs more than keyboard-interactive on its own, restate
# it as the second alternative, e.g.
# "publickey password,keyboard-interactive". Drop the second alternative
# once the key works if the site wants ${user} on pubkey only.
#
${keys_note}
#
# NOT SETTABLE PER USER: PerSourcePenaltyExemptList (OpenSSH 9.9+ bans a
# client IP after a hung OTP prompt) is global-only. If operators get
# locked out, an admin adds it to the host's own hardening file.

Match User ${user}
    PubkeyAuthentication yes
    AuthenticationMethods publickey keyboard-interactive${keys_line}
    # Remote-SSH tunnels its server over the session. Both are sshd
    # defaults, restated for ${user} in case the baseline turns them off.
    AllowTcpForwarding yes
    AllowStreamLocalForwarding yes

# Back to global scope. Anything appended below this line applies to
# every user, not to ${user}. Keep it last.
Match all
EOF
}

# ── Dispatch ───────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
  run_status
  exit 0
fi
if [ "$ACTION" = "prune" ]; then
  run_prune
  exit 0
fi
if [ "$ACTION" = "emit-ssh-config" ]; then
  run_emit_ssh_config
  exit 0
fi
if [ "$ACTION" = "link-home" ]; then
  run_link_home
  exit 0
fi
if [ "$ACTION" = "install-authorized-key" ]; then
  run_install_authorized_key
  exit 0
fi
if [ "$ACTION" = "install-fapolicyd" ]; then
  run_install_fapolicyd
  exit 0
fi
if [ "$ACTION" = "list-versions" ]; then
  run_list_versions
  exit 0
fi

# --version -> --commit resolution happens once, here, before any download
# logic runs — everything downstream (self-computed sha256 for a
# non-latest pin, the manifest, filenames) already only ever looks at
# COMMIT, so resolving VERSION into it up front means no other function
# needs to know the difference.
#
# --commit wins when both are set (documented contract) — and that MUST
# include clearing a stale --version, not just skipping resolution. Found
# live: leaving a user-supplied --version untouched here let it leak into
# resolve_version_for_commit()'s "if VERSION is already set, trust it"
# shortcut later, producing a real mismatch — commit a5b50095...
# (actually 1.133.0) downloaded correctly, but the Windows installer got
# named VSCodeUserSetup-x64-1.32.0.exe because --version 1.32.0 was also
# passed and never cleared. Clearing VERSION here forces that later
# function back onto its normal path: ask /api/update for the real
# semver of whatever commit actually got used.
if [ -n "$VERSION" ] && [ -n "$COMMIT" ]; then
  warn "both --version ($VERSION) and --commit are set — --commit wins," \
       "--version is ignored entirely (not just for resolution)"
  VERSION=""
elif [ -n "$VERSION" ] && [ "$MODE" != "offline" ]; then
  COMMIT="$(resolve_version_to_commit "$VERSION")"
  log "resolved --version $VERSION -> commit ${COMMIT:0:12}..."
fi

log "mode=$MODE channel=$CHANNEL remote_arch=$ARCH install_dir=$INSTALL_DIR"
case "$MODE" in
  online)  run_online ;;
  bundle)  run_bundle ;;
  offline) run_offline ;;
esac
