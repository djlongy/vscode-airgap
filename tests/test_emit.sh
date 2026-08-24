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

# ── --central-keys: AuthorizedKeysFile, central path FIRST ──────────────
# For hosts where sshd cannot read an NFS home under SELinux.
CK="$TMP/central"
"$SCRIPT" --emit-ssh-config --install-dir "$CK" --user alice --central-keys >/dev/null
CK_DROPIN="$CK/50-vscode-alice.conf"
AKF="$(grep -E '^[[:space:]]*AuthorizedKeysFile' "$CK_DROPIN" || true)"
[ -n "$AKF" ] || fail "--central-keys emitted no AuthorizedKeysFile line"
# field 2 is the first path sshd tries; it must be the central one
[ "$(printf '%s\n' "$AKF" | awk '{print $2}')" = "/etc/ssh/authorized_keys/%u" ] \
  || fail "central path is not first in: $AKF"
[ "$(printf '%s\n' "$AKF" | awk '{print $3}')" = ".ssh/authorized_keys" ] \
  || fail "home path is not kept as the second AuthorizedKeysFile entry: $AKF"
# still per-user: the directive lives inside the Match block
awk '/^Match /{seen=1} /^[[:space:]]*AuthorizedKeysFile/{ if (!seen) exit 1 }' "$CK_DROPIN" \
  || fail "AuthorizedKeysFile was emitted outside the Match block"
grep -q 'nfs_t' "$CK_DROPIN" || fail "central-keys drop-in does not explain why it exists"
"$SCRIPT" --emit-ssh-config --install-dir "$TMP/central2" --user alice --central-keys /srv/ssh-keys >/dev/null
grep -qF 'AuthorizedKeysFile /srv/ssh-keys/%u .ssh/authorized_keys' "$TMP/central2/50-vscode-alice.conf" \
  || fail "--central-keys DIR was not honoured"
# Default emission must stay exactly as it was: no AuthorizedKeysFile line
# at all, so a FreeIPA host's AuthorizedKeysCommand is left alone.
grep -qE '^[[:space:]]*AuthorizedKeysFile' "$DROPIN" \
  && fail "the default drop-in gained an AuthorizedKeysFile line"
diff -q "$ROOT/contrib/remote-host-central-keys.example" \
  "$TMP/contribcheck-ck/50-vscode-youruser.conf" >/dev/null 2>&1 || {
  "$SCRIPT" --emit-ssh-config --install-dir "$TMP/contribcheck-ck" --user youruser --central-keys >/dev/null
  diff -q "$ROOT/contrib/remote-host-central-keys.example" \
    "$TMP/contribcheck-ck/50-vscode-youruser.conf" >/dev/null \
    || fail "contrib/remote-host-central-keys.example is out of sync with the emitted drop-in"
}

# ── --install-authorized-key refuses what sshd would refuse ─────────────
KEYSRC="$TMP/id_test.pub"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYFORTESTSONLYxxxxxxxxxxxxxxxxxxxxx test@example\n' > "$KEYSRC"
BADDIR="$TMP/badkeys"
mkdir -p "$BADDIR"
chmod 0777 "$BADDIR"
if "$SCRIPT" --install-authorized-key "$KEYSRC" --user "$(id -un)" --central-keys "$BADDIR" \
    >/dev/null 2>"$TMP/key-err"; then
  fail "installing into a world-writable key directory should fail"
fi
grep -q 'not in the shape sshd requires' "$TMP/key-err" \
  || fail "key install did not explain the refusal: $(cat "$TMP/key-err")"
[ -z "$(ls -A "$BADDIR")" ] || fail "key was written into a directory sshd would reject"
chmod 0755 "$BADDIR"
# a world-writable existing key file is refused the same way, unchanged
printf 'ssh-ed25519 AAAAOLDKEY old@example\n' > "$BADDIR/$(id -un)"
chmod 0666 "$BADDIR/$(id -un)"
if "$SCRIPT" --install-authorized-key "$KEYSRC" --user "$(id -un)" --central-keys "$BADDIR" \
    >/dev/null 2>"$TMP/key-err2"; then
  fail "installing over a world-writable key file should fail"
fi
grep -q 'StrictModes' "$TMP/key-err2" || fail "key-file refusal does not mention StrictModes"
grep -qF 'AAAAOLDKEY' "$BADDIR/$(id -un)" || fail "refused install still modified the key file"
[ "$(wc -l < "$BADDIR/$(id -un)" | tr -d ' ')" -eq 1 ] || fail "refused install appended to the key file"
# a private key must never be installed
if printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nnope\n' | \
    "$SCRIPT" --install-authorized-key --user "$(id -un)" --central-keys "$TMP/privkeys" \
    >/dev/null 2>&1; then
  fail "a private key was accepted"
fi
[ -d "$TMP/privkeys" ] && fail "a refused private key still created the key directory"

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

# ── a home-directory install is supported, with the tradeoff stated ─────
# Some hosts only ever give a user their home. The rule must be live, and
# the cost of allow-listing a home tree must travel with it.
HOME_INSTALL="$TMP/fakehome/.vscode-server"
mkdir -p "$TMP/fakehome"
HOME="$TMP/fakehome" "$SCRIPT" --emit-ssh-config --install-dir "$HOME_INSTALL" >/dev/null
grep -q "^allow perm=any all : dir=${HOME_INSTALL}/" "$HOME_INSTALL/fapolicyd-vscode.rules" \
  || fail "no active fapolicyd allow-rule for a home-directory install"
grep -q '^#allow' "$HOME_INSTALL/fapolicyd-vscode.rules" \
  && fail "home-directory rule was commented out instead of emitted"
grep -q 'THIS RULE COVERS A HOME DIRECTORY' "$HOME_INSTALL/fapolicyd-vscode.rules" \
  || fail "home-directory rule does not state the tradeoff"
grep -qi 'each additional user needs their own' "$HOME_INSTALL/fapolicyd-vscode.rules" \
  || fail "home-directory rule does not mention the per-user rule cost"
[ -f "$HOME_INSTALL/ssh-config.example" ] \
  || fail "the home-directory warning stopped the other templates being written"
# a shared path carries the rule without the home-directory note
grep -q 'THIS RULE COVERS A HOME DIRECTORY' "$OUT/fapolicyd-vscode.rules" \
  && fail "a non-home install dir was described as a home directory"

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
