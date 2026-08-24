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
# publickey must be FIRST in every block: extra Remote-SSH channels only
# skip the OTP prompt while the key is tried before keyboard-interactive.
awk '/^[[:space:]]*PreferredAuthentications/ { if ($2 !~ /^publickey/) exit 1 }' \
  "$OUT/ssh-config.example" || fail "a PreferredAuthentications line does not start with publickey"
grep -qF '%USERPROFILE%\.ssh\config' "$OUT/ssh-config.example" \
  || fail "client ssh_config does not name the Windows config path"
if grep -q 'PubkeyAuthentication no' "$OUT/ssh-config.example"; then
  fail "client ssh_config still disables pubkey"
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
# Neither of these templates depends on INSTALL_DIR, so the browsable
# copies must be exactly what --emit-ssh-config writes.
diff -q "$ROOT/contrib/ssh-config.example" "$OUT/ssh-config.example" >/dev/null \
  || fail "contrib/ssh-config.example is out of sync with the emitted template"
"$SCRIPT" --emit-ssh-config --install-dir "$TMP/contribcheck" --user youruser >/dev/null
diff -q "$ROOT/contrib/remote-host.example" "$TMP/contribcheck/50-vscode-youruser.conf" >/dev/null \
  || fail "contrib/remote-host.example is out of sync with the emitted per-user drop-in"

# ── per-user sshd drop-in, nothing global ───────────────────────────────
"$SCRIPT" --emit-ssh-config --install-dir "$OUT" --user alice >/dev/null
DROPIN="$OUT/50-vscode-alice.conf"
[ -f "$DROPIN" ] || fail "no per-user sshd drop-in at $DROPIN"
grep -q '^Match User alice$' "$DROPIN" || fail "drop-in is not scoped with 'Match User alice'"
grep -q 'PubkeyAuthentication yes' "$DROPIN" || fail "drop-in does not enable pubkey for the user"
# The host's hardened baseline must survive for everyone else: the first
# directive has to be the Match, and the file has to end back at global
# scope so an appended line is not silently user-scoped.
FIRST_DIRECTIVE="$(grep -vE '^[[:space:]]*(#|$)' "$DROPIN" | head -1)"
[ "$FIRST_DIRECTIVE" = "Match User alice" ] \
  || fail "first directive is not the Match block: $FIRST_DIRECTIVE"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$DROPIN" | tail -1)" = "Match all" ] \
  || fail "drop-in does not return to global scope with a trailing 'Match all'"
awk '/^Match /{seen=1} /^[[:space:]]*PubkeyAuthentication/{ if (!seen) exit 1 }' "$DROPIN" \
  || fail "drop-in sets PubkeyAuthentication outside a Match block"
grep -q 'AuthenticationMethods publickey keyboard-interactive' "$DROPIN" \
  || fail "drop-in does not offer publickey as an ALTERNATIVE to keyboard-interactive"
if grep -q 'AuthenticationMethods publickey,keyboard-interactive' "$DROPIN"; then
  fail "drop-in requires publickey AND keyboard-interactive, which puts OTP back on every channel"
fi

# ── additive: a colleague is a new file, never an edit to the first ─────
ALICE_BEFORE="$(cat "$DROPIN")"
"$SCRIPT" --emit-ssh-config --install-dir "$OUT" --user bob >/dev/null
[ -f "$OUT/50-vscode-bob.conf" ] || fail "second user did not get their own drop-in"
grep -q '^Match User bob$' "$OUT/50-vscode-bob.conf" || fail "bob's drop-in is not scoped to bob"
[ "$ALICE_BEFORE" = "$(cat "$DROPIN")" ] || fail "emitting for bob rewrote alice's drop-in"
"$SCRIPT" --emit-ssh-config --install-dir "$TMP/prio" --user alice,bob --sshd-priority 70 >/dev/null
[ -f "$TMP/prio/70-vscode-alice.conf" ] && [ -f "$TMP/prio/70-vscode-bob.conf" ] \
  || fail "--sshd-priority is not reflected in the emitted filenames"
if "$SCRIPT" --emit-ssh-config --install-dir "$TMP/bad" --user '../root' >/dev/null 2>&1; then
  fail "an invalid user name was accepted into a Match line and a filename"
fi

# ── emit into a directory we cannot write dies with advice ──────────────
# mkdir -p succeeds on an existing root-owned dir, so this used to fail
# as a raw redirect error after writing part of the set.
UNWRITABLE="$TMP/unwritable"
mkdir -p "$UNWRITABLE"
chmod 0555 "$UNWRITABLE"
if "$SCRIPT" --emit-ssh-config --install-dir "$UNWRITABLE" >/dev/null 2>"$TMP/emit-err"; then
  fail "emitting into an unwritable directory should fail"
fi
grep -q 'cannot write templates to' "$TMP/emit-err" \
  || fail "unwritable emit did not explain itself: $(cat "$TMP/emit-err")"
[ -f "$UNWRITABLE/ssh-config.example" ] && fail "wrote a template into an unwritable directory"
chmod 0755 "$UNWRITABLE"

# ── fapolicyd rule refuses a home directory unless forced ───────────────
HOME_INSTALL="$TMP/fakehome/.vscode-server"
mkdir -p "$TMP/fakehome"
HOME="$TMP/fakehome" "$SCRIPT" --emit-ssh-config --install-dir "$HOME_INSTALL" >/dev/null
grep -q '^allow perm=any all : dir=' "$HOME_INSTALL/fapolicyd-vscode.rules" \
  && fail "emitted an active fapolicyd allow-rule for a home directory"
grep -q '^#allow perm=any all : dir=' "$HOME_INSTALL/fapolicyd-vscode.rules" \
  || fail "home-directory fapolicyd rule is neither active nor commented out"
grep -q 'REFUSED' "$HOME_INSTALL/fapolicyd-vscode.rules" \
  || fail "commented-out fapolicyd rule does not say why"
# the refusal must not cost the operator the rest of the templates
[ -f "$HOME_INSTALL/ssh-config.example" ] \
  || fail "a refused fapolicyd rule stopped the other templates being written"
HOME="$TMP/fakehome" "$SCRIPT" --emit-ssh-config --install-dir "$HOME_INSTALL" --force >/dev/null
grep -q '^allow perm=any all : dir=' "$HOME_INSTALL/fapolicyd-vscode.rules" \
  || fail "--force did not emit the home-directory rule"

# ── help documents ownership and the multi-user design ──────────────────
HELP="$("$SCRIPT" --help)"
printf '%s' "$HELP" | grep -q 'OWNERSHIP UNDER sudo' \
  || fail "--help does not document ownership under sudo"
printf '%s' "$HELP" | grep -q 'chowned to that user' \
  || fail "--help does not say --link-home chowns to the target user"
printf '%s' "$HELP" | grep -q 'MULTI-USER, ONE HOST' \
  || fail "--help does not document the multi-user design"
printf '%s' "$HELP" | grep -q 'Match User NAME' \
  || fail "--help does not say the sshd drop-in is Match-scoped"

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
# Every directory and symlink link-home creates belongs to the user whose
# home it is. Root does the same by uid — see OWNERSHIP UNDER sudo.
WRONG_OWNER="$(find "$DEST" ! -uid "$(id -u)" -print 2>/dev/null | head -5)"
[ -z "$WRONG_OWNER" ] || fail "link-home left paths owned by another uid: $WRONG_OWNER"
# second run is a no-op
HOME="$HOME_FAKE" "$SCRIPT" --link-home --install-dir "$SRC" >/dev/null

# A missing home must not be created (mkdir -p would make it root-owned)
if HOME="$TMP/no-such-home" "$SCRIPT" --link-home --install-dir "$SRC" >/dev/null 2>&1; then
  fail "link-home into a non-existent home should fail"
fi
[ -e "$TMP/no-such-home" ] && fail "link-home created a home directory that did not exist"

echo "OK"
