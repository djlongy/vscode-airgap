#!/usr/bin/env bash
# vscode-airgap.sh — stage a Remote-SSH connection to an air-gapped Linux
# host: pre-install the exact VS Code Server commit at ~/.vscode-server so
# the client never needs to download it, plus matching client installers
# (Linux + Windows) so Help > About reports the same commit. Also supports
# Microsoft's Remote Tunnels and `code serve-web` as secondary, online-only
# / optional paths.
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
readonly DEFAULT_INSTALL_DIR="${HOME}/.vscode-server"
readonly DEFAULT_BIND_ADDR="127.0.0.1"
readonly DEFAULT_PORT="8000"
readonly DEFAULT_SERVER_ARCH="linux-x64"
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
ACTION="install"          # install (default) | tunnel | status | emit-ssh-config | list-versions
START_AFTER_INSTALL=0     # serve-web only starts if --serve-web is also given
DOWNLOAD_ONLY=0
FORCE=0
WITH_SERVE_WEB=0          # --serve-web: also fetch+optionally start code serve-web
WITH_CLI=0                # implied by --serve-web or --tunnel
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
vscode-airgap.sh — stage VS Code Remote-SSH for an air-gapped Linux host

Primary path: pre-install the exact VS Code Server commit on the
air-gapped host so Remote-SSH finds a matching install and never tries
to download one over the wire. Stages BOTH layouts the client may pick
(classic ~/.vscode-server/bin/<commit>/ AND exec-server
~/.vscode-server/code-<commit> plus cli/servers/Stable-<commit>/server/)
plus matching Linux/Windows client installers so Help > About reports
the same commit. Connects over plain SSH port 22 with realm
(GSSAPI/Kerberos) + OTP auth — see
docs/runbooks/remote-ssh-realm-otp.md. `code serve-web` and Remote Tunnels
are supported as secondary, opt-in paths (--serve-web / --tunnel).

USAGE
  vscode-airgap.sh --mode online   [options]   # internet-connected host
  vscode-airgap.sh --mode bundle   [options]   # internet-connected host: pack a bundle
  vscode-airgap.sh --mode offline  [options]   # air-gapped host: install from a bundle
  vscode-airgap.sh --emit-ssh-config [--install-dir DIR]
  vscode-airgap.sh --status [--install-dir DIR]
  vscode-airgap.sh --list-versions [--limit N|--all] [--format text|json] [--refresh]
  vscode-airgap.sh --help

MODES
  online    Resolve latest (or pinned) commit, download server-linux-<arch>
            (Remote-SSH server, mandatory), the Linux x64 desktop tarball
            and the Windows x64 User Setup (client installers, mandatory —
            both are needed so at least one operator platform's Help >
            About commit matches the staged server), any --extensions /
            --extensions-file, install the server at
            INSTALL_DIR/bin/<commit>/ (classic) AND
            INSTALL_DIR/code-<commit> plus
            cli/servers/Stable-<commit>/server/ (exec-server), plus the
            handshake tarball vscode-cli-<commit>.tar.gz with its
            sibling .done written last. INSTALL_DIR defaults to
            ~/.vscode-server — the real path Remote-SSH itself uses.
            Stage the client installers + extension VSIX for the
            operator to pick up. Add --serve-web to also
            fetch+start `code serve-web`, or --tunnel for real Remote
            Tunnels (internet-only, see LIMITATIONS).
  bundle    Same download step as online, but instead of installing, packs
            everything into a single tarball (BUNDLE_PATH) with a
            versions.json manifest (commit, version, arch, channel, date,
            sha256 of every artifact — Microsoft-published where available,
            self-computed otherwise, both recorded distinctly). Run this on
            a machine with internet access, then carry the tarball across
            the air gap.
  offline   Installs from a bundle tarball with ZERO outbound network calls.
            Refuses to run if BUNDLE_PATH is missing, and verifies every
            artifact's sha256 against the bundle's own versions.json before
            extracting anything. Installs both Remote-SSH layouts
            (classic bin/<commit>/ and exec-server code-<commit> +
            cli/servers/Stable-<commit>/server/) plus the handshake
            tarball, and stages client installers + extensions for the
            operator. --tunnel is rejected in this mode
            (Remote Tunnels needs Microsoft's relay — see LIMITATIONS).

OPTIONS (env var equivalents in parentheses)
  --mode MODE             online|bundle|offline (MODE)
  --channel CHANNEL       stable|insider, default stable (CHANNEL)
  --version VERSION       Exact stable semver to pin, e.g. 1.96.2 (a
                          leading 'v' is accepted and stripped: v1.96.2
                          works too). Resolved to its commit via
                          microsoft/vscode's git tags (ground truth,
                          verified live 2026-08-18 — Microsoft's own APIs
                          don't expose a semver->commit map; see
                          docs/reference/download-urls.md), then confirmed
                          reachable on Microsoft's CDN before use — an old
                          version whose tag exists but whose CDN artifact
                          has been pruned fails loudly rather than
                          silently falling back to latest. A 2-component
                          version (e.g. 1.96 or 1.33) picks the newest
                          matching patch tag, then a live CDN HEAD.
                          insider
                          channel is not supported for --version (only
                          stable has tagged releases in the sense this
                          resolves) — use --commit instead. Ignored if
                          --commit is also set. See --list-versions.
                          (VERSION)
  --commit COMMIT         40-char git commit hash to pin exactly. WINS over
                          --version when both are set. Also switches
                          checksum verification to self-computed sha256
                          (Microsoft's /api/update/*/latest checksum
                          endpoint only serves the CURRENT latest build per
                          platform, confirmed live — it 204s for an older
                          commit). (COMMIT)
  --list-versions         Print stable VS Code releases with commit,
                          newest first (standalone — no --mode required).
                          Default: the most recent 10 (LIST_LIMIT=10) so
                          the picker stays short. Use --limit N or --all
                          for more; --version still accepts any cached
                          tag, not only the printed rows. CDN column is
                          from the cached availability floor (see
                          --refresh), not a live check per row — pick
                          with --version for an authoritative HEAD.
                          With --bundle-path, prints the single version
                          already staged in that bundle (offline).
                          (LIST_VERSIONS=1)
  --limit N               How many newest rows --list-versions prints.
                          Default 10. 0 means all. (LIST_LIMIT)
  --all                   Same as --limit 0: print the full tag list.
  --format text|json      Output format for --list-versions. Default text.
  --refresh               Force-refetch the git tag cache (also implies
                          --force for artifact downloads). Tag list is
                          cached at ~/.cache/vscode-airgap/ with a 24h TTL
                          by default (TAG_CACHE_TTL, seconds).
  --arch ARCH             The REMOTE Linux host's architecture, for the
                          Remote-SSH server artifact:
                          linux-x64 (default, mandatory support) |
                          linux-arm64 | linux-armhf | alpine-x64 |
                          alpine-arm64 | auto (detect from the arch running
                          this script instead — only useful for the
                          secondary --serve-web-on-this-host path). Does
                          NOT affect the client installers, which are
                          always Linux x64 + Windows x64 regardless of
                          --arch. (ARCH)
  --install-dir DIR       Default: ~/.vscode-server — deliberately the
                          SAME path Remote-SSH uses on its own. Leave it at
                          the default on the actual air-gapped host/user
                          Remote-SSH will connect as; override only for
                          testing. (INSTALL_DIR)
  --bundle-path PATH      Bundle tarball: output path (mode=bundle) or
                          input path (mode=offline). (BUNDLE_PATH)
  --extensions LIST       Comma-separated publisher.name IDs. (EXTENSIONS)
  --extensions-file PATH  Newline-delimited publisher.name IDs, UTF-8,
                          '#' comments and blank lines ignored. Unioned
                          with --extensions (duplicates deduped).
                          (EXTENSIONS_FILE)
                          For each ID: queries the Marketplace gallery for
                          every published version, prefers a linux-x64
                          target-platform build when one exists (falls back
                          to the platform-universal build), and picks the
                          NEWEST version whose `engines.vscode` range
                          accepts the bundled VS Code version (the commit's
                          own version, e.g. 1.133.0) — not an old pin. If
                          the query fails outright, falls back to the
                          simple /latest/vspackage endpoint and records
                          that fallback in versions.json (engine
                          compatibility unverified in that case).
  --serve-web             Also fetch the CLI + server-web artifacts and, on
                          install, start `code serve-web` bound to
                          BIND_ADDR:PORT. Secondary path — see LIMITATIONS.
  --tunnel                Also fetch the CLI and, after install, run
                          `code tunnel` instead of installing Remote-SSH's
                          server. online mode only — see LIMITATIONS.
  --bind ADDR             serve-web bind address, default 127.0.0.1.
                          (BIND_ADDR)
  --port PORT             serve-web port, default 8000 (PORT)
  --token TOKEN           serve-web connection token; TOKEN=none runs
                          --without-connection-token. See --serve-web.
                          (TOKEN)
  --download-only         Fetch/verify artifacts but do not install/start.
  --status                Print install state for INSTALL_DIR and exit.
                          Standalone — no MODE/network/curl required.
  --emit-ssh-config       Write three templates into INSTALL_DIR and
                          print where each one is copied (laptop
                          ~/.ssh/config, laptop VS Code user
                          settings.json, this host's sshd drop-in).
                          JSONC // comments, not fake "// key" pairs.
                          Standalone — no MODE/network required.
  --force                 Re-download even if a matching cached artifact
                          already exists.
  -h, --help              This text.

PROXY
  HTTPS_PROXY / HTTP_PROXY / NO_PROXY are honoured for every download —
  curl reads them natively, and the extension-query helper (Python's
  urllib) picks up the same standard env vars.

EXAMPLES
  # Online side: latest stable, install Remote-SSH server + both client
  # installers into ~/.vscode-server, with two extensions from a file
  ./vscode-airgap.sh --mode online --extensions-file team-extensions.txt

  # Online side: pin an exact commit, build a portable bundle
  COMMIT=a5b500951314efd502d07465bd138dfbd714a960 \
    ./vscode-airgap.sh --mode bundle --bundle-path ./vscode-bundle.tar.gz \
    --extensions ms-python.python

  # Carry vscode-bundle.tar.gz to the air-gapped host, log in as the SAME
  # user Remote-SSH will connect as, then:
  ./vscode-airgap.sh --mode offline --bundle-path ./vscode-bundle.tar.gz

  # Print ssh_config + JSONC settings.json + remote-host notes
  ./vscode-airgap.sh --emit-ssh-config

  # Optional secondary path: serve-web instead of / alongside Remote-SSH
  ./vscode-airgap.sh --mode online --serve-web

  # Match an already-running remote server instead of always fetching latest:
  # 1. On the remote, find its exact commit (no network needed):
  #      ./vscode-airgap.sh --status
  #      # or: cat ~/.vscode-server/bin/*/product.json
  # 2. On a connected host, see what semver that commit corresponds to and
  #    pick a version explicitly instead of re-resolving "latest" every run:
  ./vscode-airgap.sh --list-versions | head -20
  ./vscode-airgap.sh --mode bundle --version 1.96.2 --bundle-path ./v1.96.2.tar.gz

LIMITATIONS — READ THIS BEFORE CHOOSING --tunnel OR --serve-web
  Microsoft's Remote Tunnels (`code tunnel`) are NOT air-gap compatible.
  The CLI authenticates against github.com/login.microsoftonline.com and
  then keeps a persistent outbound connection to Microsoft's tunnel relay
  for the lifetime of the tunnel — there is no offline or self-hosted
  relay mode. Online mode only; offline mode refuses --tunnel outright.

  `code serve-web` works air-gapped (no relay involved) but is now the
  SECONDARY path — the primary answer to "a client can connect to an
  air-gapped VS Code Server" is Remote-SSH over the port that's already
  open (22), which is what --mode online/offline do by default. Pass
  --serve-web only if you specifically want the browser-based path too.

  There is no VS Code setting that means "never attempt any server
  download, ever". `remote.SSH.localServerDownload: "off"` is still
  required: a staging miss otherwise wget -O truncates the CLI tarball
  to zero bytes and the install script polls forever. The fail-closed
  mechanism is what this script does: pre-stage BOTH Remote-SSH layouts
  (classic ~/.vscode-server/bin/<commit>/ AND exec-server
  ~/.vscode-server/code-<commit> plus
  cli/servers/Stable-<commit>/server/) BEFORE the first connection, so
  whichever bootstrap script arrives, its presence test passes and the
  download branch is never entered. Also set
  remote.SSH.remoteServerListenOnSocket: false in settings.json —
  true silently forces useLocalServer off (Windows ignores the UI
  toggle). See docs/runbooks/remote-ssh-realm-otp.md.
EOF
}

# ── Arg parsing ──────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --commit) COMMIT="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --bundle-path) BUNDLE_PATH="$2"; shift 2 ;;
    --bind) BIND_ADDR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --extensions) EXTENSIONS="$2"; shift 2 ;;
    --extensions-file) EXTENSIONS_FILE="$2"; shift 2 ;;
    --serve-web) WITH_SERVE_WEB=1; WITH_CLI=1; START_AFTER_INSTALL=1; shift ;;
    --download-only) DOWNLOAD_ONLY=1; START_AFTER_INSTALL=0; shift ;;
    --tunnel) ACTION="tunnel"; WITH_CLI=1; shift ;;
    --status) ACTION="status"; shift ;;
    --emit-ssh-config) ACTION="emit-ssh-config"; shift ;;
    --list-versions) ACTION="list-versions"; shift ;;
    --limit) LIST_LIMIT="$2"; shift 2 ;;
    --all) LIST_LIMIT=0; shift ;;
    --format) LIST_FORMAT="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --refresh) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ "$LIST_VERSIONS" = "1" ] && ACTION="list-versions"
case "$LIST_FORMAT" in text|json) ;; *) die "invalid --format '$LIST_FORMAT' (text|json)" ;; esac

# --status / --emit-ssh-config / --list-versions are standalone queries
# that never require --mode. --list-versions is NOT network-free like the
# other two (unless --bundle-path is given) — see the dependency block
# below for its own, narrower requirements.
if [ "$ACTION" = "status" ] || [ "$ACTION" = "emit-ssh-config" ] || [ "$ACTION" = "list-versions" ]; then
  STANDALONE_ACTION=1
else
  STANDALONE_ACTION=0
  [ -n "$MODE" ] || { usage; die "MODE / --mode is required (online|bundle|offline)"; }
  case "$MODE" in online|bundle|offline) ;; *) die "invalid --mode '$MODE' (online|bundle|offline)" ;; esac
  case "$CHANNEL" in stable|insider) ;; *) die "invalid --channel '$CHANNEL' (stable|insider)" ;; esac
fi

# ── Dependency check ─────────────────────────────────────────────────────
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
if [ "$ACTION" = "status" ] || [ "$ACTION" = "emit-ssh-config" ]; then
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
  mkdir -p "$TAG_CACHE_DIR"
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
  local ext_dir="$stage_dir/extensions"
  local all_ext_ids="" ext_results=()
  [ -n "$EXTENSIONS" ] && all_ext_ids="$(echo "$EXTENSIONS" | tr ',' '\n')"
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
  [ -n "$BUNDLE_PATH" ] || die "--bundle-path is required in bundle mode"
  _STAGE_DIR="$(mktemp -d)"
  trap cleanup_stage_dir EXIT
  stage_artifacts "$_STAGE_DIR"
  mkdir -p "$(dirname "$BUNDLE_PATH")"
  # macOS tar otherwise writes LIBARCHIVE.xattr.com.apple.provenance
  # headers; GNU tar on the air-gapped host warns and ignores them.
  COPYFILE_DISABLE=1 tar -C "$_STAGE_DIR" --exclude='._*' -czf "$BUNDLE_PATH" .
  log "bundle written: $BUNDLE_PATH ($(du -h "$BUNDLE_PATH" | awk '{print $1}'))"
  log "carry this file across the air gap, log in as the SAME user Remote-SSH" \
      "will connect as, then run:"
  log "  $SELF --mode offline --bundle-path <path-to-bundle>"
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

# ── Shared install step (used by online + offline) ───────────────────────
install_from_stage() {
  local stage_dir="$1"
  local commit
  commit="$(json_field "$stage_dir/versions.json" commit)"
  [ -n "$commit" ] || die "versions.json has no commit field"

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
    chmod 640 "$remote_cli_archive" 2>/dev/null || chmod 600 "$remote_cli_archive"
    if [ ! -x "$exec_cli" ]; then
      tar -xOf "$handshake_src" code > "$exec_cli" \
        || die "could not extract CLI binary 'code' from $handshake_src"
      chmod 0755 "$exec_cli"
    fi
    : > "${remote_cli_archive}.done"
    chmod 640 "${remote_cli_archive}.done" 2>/dev/null || chmod 600 "${remote_cli_archive}.done"
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

  cp -f "$stage_dir/versions.json" "$INSTALL_DIR/versions.json"
  log "install complete. versions: $INSTALL_DIR/versions.json"

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
    log "  $SELF --emit-ssh-config"
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
  mkdir -p "$INSTALL_DIR"
  local ssh_out="$INSTALL_DIR/ssh-config.example"
  local settings_out="$INSTALL_DIR/settings.json.example"
  local remote_out="$INSTALL_DIR/remote-host.example"
  write_ssh_config_example > "$ssh_out"
  write_settings_json_example > "$settings_out"
  write_remote_host_example > "$remote_out"
  log "wrote templates under $INSTALL_DIR"
  log "These are NOT live. Copy/merge each file to the path below."
  log ""
  log "  $ssh_out"
  log "    WHO:  operator laptop (not this host)"
  log "    Unix/macOS ->  ~/.ssh/config"
  log "    Windows    ->  C:\\Users\\youruser\\.ssh\\config"
  log "    HOW:  merge ONE Host block (Unix or Windows), replace"
  log "          airgapped-host / youruser / the hostname"
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
  log "  $remote_out"
  log "    WHO:  THIS Linux host, as root (not the laptop)"
  log "    PUT:  /etc/ssh/sshd_config.d/50-remote-ssh-airgap.conf"
  log "    HOW:  copy the file, then sshd -t && systemctl reload sshd"
}

write_ssh_config_example() {
  cat <<'EOF'
# WHERE THIS GOES — operator laptop, NOT the remote host
#   Unix/macOS:  ~/.ssh/config
#   Windows:     C:\Users\youruser\.ssh\config
# Merge ONE Host block. Replace the host / realm / user placeholders.
# Unix after merge: mkdir -p ~/.ssh/sockets

# Unix / macOS — ControlMaster reuses the OTP login (anti-replay).
Host airgapped-host
    HostName airgapped-host.example.realm
    User youruser
    Port 22
    PreferredAuthentications gssapi-with-mic,keyboard-interactive,password
    GSSAPIAuthentication yes
    GSSAPIDelegateCredentials yes
    PubkeyAuthentication no
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
    PreferredAuthentications keyboard-interactive
    PubkeyAuthentication no
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
  cat <<'EOF'
{
  // WHERE THIS GOES — operator laptop, NOT the remote host
  //   Windows:  %APPDATA%\Code\User\settings.json
  //   macOS:    ~/Library/Application Support/Code/User/settings.json
  //   Linux:    ~/.config/Code/User/settings.json
  // Merge these keys (JSONC: // comments are fine). UTF-8, no BOM.
  // Omit remote.SSH.path on Unix.

  // So the password + TOTP prompts are visible.
  "remote.SSH.showLoginTerminal": true,

  // Reuse the OTP login. Required on Windows (no ControlMaster).
  "remote.SSH.useLocalServer": true,

  // Classic bootstrap. Confirm the log: useExecServer = false
  "remote.SSH.useExecServer": false,

  // Fail fast if the server bits are missing (do not wget forever).
  "remote.SSH.localServerDownload": "off",

  // true silently turns useLocalServer off. Windows ignores the UI.
  "remote.SSH.remoteServerListenOnSocket": false,

  // Harmless. Avoids lock files in the server install folder.
  "remote.SSH.lockfilesInTmp": true,

  // OTP login is slower than a key (default 15s).
  "remote.SSH.connectTimeout": 60,

  // Windows only — native OpenSSH optional feature.
  "remote.SSH.path": "C:\\Windows\\System32\\OpenSSH\\ssh.exe",

  // Host alias must match the ssh config Host name.
  "remote.SSH.remotePlatform": {
    "airgapped-host": "linux"
  }
}
EOF
}

write_remote_host_example() {
  cat <<'EOF'
# WHERE THIS GOES — THIS Linux host as root, NOT the laptop
#   /etc/ssh/sshd_config.d/50-remote-ssh-airgap.conf
#   then: sshd -t && systemctl reload sshd
#
# Makes sshd accept password+OTP and allow Remote-SSH forwarding.
# First Factor = password. Second Factor = TOTP (not the password again).
# remote.SSH.* keys do not go here.

PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
# OpenSSH 9.9+ bans the client IP after a hung OTP prompt.
# Replace with the operator workstation CIDRs.
PerSourcePenaltyExemptList 192.0.2.0/24,198.51.100.0/24
EOF
}

# ── Dispatch ───────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
  run_status
  exit 0
fi
if [ "$ACTION" = "emit-ssh-config" ]; then
  run_emit_ssh_config
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
