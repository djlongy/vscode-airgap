#!/usr/bin/env bash
# Offline checks for --emit-ssh-config, --link-home, and shared-path templates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/vscode-airgap.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── emit for a shared install dir ───────────────────────────────────────
"$SCRIPT" --emit-ssh-config --install-dir "$TMP/opt/vscode-server" >/dev/null
OUT="$TMP/opt/vscode-server"

grep -q 'PubkeyAuthentication yes' "$OUT/ssh-config.example" \
  || fail "client ssh_config missing PubkeyAuthentication yes"
grep -q 'PreferredAuthentications publickey' "$OUT/ssh-config.example" \
  || fail "client ssh_config does not prefer publickey"
if grep -q 'PubkeyAuthentication no' "$OUT/ssh-config.example"; then
  fail "client ssh_config still disables pubkey"
fi
grep -q 'PubkeyAuthentication yes' "$OUT/remote-host.example" \
  || fail "sshd drop-in missing PubkeyAuthentication yes"
if grep -q 'AuthenticationMethods keyboard-interactive$' "$OUT/remote-host.example"; then
  fail "sshd drop-in forces keyboard-interactive only"
fi
grep -qF "dir=${TMP}/opt/vscode-server/" "$OUT/fapolicyd-vscode.rules" \
  || fail "fapolicyd rule missing dir=${TMP}/opt/vscode-server/"
grep -qF '"airgapped-host":' "$OUT/settings.json.example" \
  || fail "settings.json missing host alias"
grep -qF "$TMP/opt/vscode-server" "$OUT/settings.json.example" \
  || fail "settings.json missing serverInstallPath for custom install dir"

# contrib copies stay on the documented shared path
grep -qF 'dir=/opt/vscode-server/' "$ROOT/contrib/fapolicyd-vscode.rules" \
  || fail "contrib fapolicyd rule is not /opt/vscode-server"
grep -q 'PubkeyAuthentication yes' "$ROOT/contrib/ssh-config.example" \
  || fail "contrib ssh-config missing pubkey yes"

# ── --link-home ─────────────────────────────────────────────────────────
COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SRC="$TMP/opt/vscode-server"
mkdir -p "$SRC/bin/$COMMIT" "$SRC/cli/servers/Stable-$COMMIT/server"
echo '{"commit":"'"$COMMIT"'"}' > "$SRC/versions.json"
printf 'fake-cli' > "$SRC/code-$COMMIT"
chmod 0755 "$SRC/code-$COMMIT"
: > "$SRC/vscode-cli-${COMMIT}.tar.gz"
: > "$SRC/vscode-cli-${COMMIT}.tar.gz.done"

HOME_FAKE="$TMP/home"
mkdir -p "$HOME_FAKE"
# link-home uses getent / $HOME. Override HOME so dest is the fake home.
HOME="$HOME_FAKE" "$SCRIPT" --link-home --install-dir "$SRC" >/dev/null

DEST="$HOME_FAKE/.vscode-server"
[ -L "$DEST/code-$COMMIT" ] || fail "code-<commit> was not a symlink"
[ "$(readlink "$DEST/code-$COMMIT")" = "$SRC/code-$COMMIT" ] \
  || fail "code-<commit> symlink target wrong"
[ -L "$DEST/bin/$COMMIT" ] || fail "bin/<commit> was not a symlink"
[ -d "$DEST/data" ] && fail "link-home must not create per-user data/ under dest"
# second run is a no-op
HOME="$HOME_FAKE" "$SCRIPT" --link-home --install-dir "$SRC" >/dev/null

echo "OK"
