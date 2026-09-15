#!/usr/bin/env bash
# Offline checks for version pruning: the default install-path prune,
# --keep-old, standalone --prune, --status, and the two refusals (an
# install that never completed, and anything outside INSTALL_DIR).
# Set BASH_BIN to run the script under a specific bash (3.2 vs 5).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/vscode-airgap.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

VSA=("$SCRIPT")
[ -n "${BASH_BIN:-}" ] && VSA=("$BASH_BIN" "$SCRIPT")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
D=dddddddddddddddddddddddddddddddddddddddd

# fake_commit <install-dir> <commit> [done=1] — the tree install_from_stage
# lays down for one commit, without needing a real 400MB server tarball.
fake_commit() {
  local dir="$1" c="$2" want_done="${3:-1}"
  mkdir -p "$dir/bin/$c/bin" "$dir/cli/servers/Stable-$c/server/bin"
  printf '{"commit":"%s"}\n' "$c" > "$dir/bin/$c/product.json"
  printf 'server\n' > "$dir/bin/$c/bin/code-server"
  printf 'server\n' > "$dir/cli/servers/Stable-$c/server/bin/code-server"
  printf 'cli\n' > "$dir/code-$c"
  chmod 0755 "$dir/code-$c"
  printf 'archive\n' > "$dir/vscode-cli-$c.tar.gz"
  [ "$want_done" = "1" ] && : > "$dir/vscode-cli-$c.tar.gz.done"
  return 0
}

# version-independent state plus two things the prune must never reach:
# a file that is not commit-shaped, and a symlink out of the tree.
fake_extras() {
  local dir="$1"
  mkdir -p "$dir/data/User" "$dir/extensions/some.ext" "$dir/client-installers"
  printf '{}\n' > "$dir/data/User/settings.json"
  printf 'ext\n' > "$dir/extensions/some.ext/package.json"
  printf 'installer\n' > "$dir/client-installers/vscode-linux-x64.tar.gz"
  printf 'log\n' > "$dir/server.log"
  printf 'stray\n' > "$dir/not-a-commit.txt"
  ln -s "$OUTSIDE" "$dir/bin/$D"
}

OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE"
printf 'do not touch\n' > "$OUTSIDE/keepme"

# make_bundle <commit> <out.tar.gz> [with_cli=1] — a bundle in exactly the
# shape --mode bundle writes, small enough to fabricate here. with_cli=0
# omits the Remote-SSH CLI archive, which is what makes install_from_stage
# skip the .done marker: an install that did not complete.
make_bundle() {
  local commit="$1" out="$2" with_cli="${3:-1}"
  local b="$TMP/stage-$commit-$with_cli" srv="vscode-server-linux-x64"
  rm -rf "$b"
  mkdir -p "$b/src/$srv/bin/helpers"
  printf '{"commit":"%s","version":"1.0.0"}\n' "$commit" > "$b/src/$srv/product.json"
  printf '#!/bin/sh\necho server\n' > "$b/src/$srv/bin/code-server"
  printf '#!/bin/sh\nexit 0\n' > "$b/src/$srv/bin/helpers/check-requirements.sh"
  printf 'node\n' > "$b/src/$srv/node"
  chmod 0755 "$b/src/$srv/bin/code-server" "$b/src/$srv/node"
  tar -C "$b/src" -czf "$b/server-linux-x64.tar.gz" "$srv"
  printf 'linux client\n' | gzip > "$b/vscode-linux-x64.tar.gz"
  printf 'windows client\n' > "$b/VSCodeUserSetup-x64-1.0.0.exe"
  if [ "$with_cli" = "1" ]; then
    mkdir -p "$b/src-cli"
    printf '#!/bin/sh\necho cli\n' > "$b/src-cli/code"
    chmod 0755 "$b/src-cli/code"
    tar -C "$b/src-cli" -czf "$b/cli-alpine-x64.tar.gz" code
  fi
  {
    printf '{\n'
    printf '  "channel": "stable",\n'
    printf '  "commit": "%s",\n' "$commit"
    printf '  "vscode_version": "1.0.0",\n'
    printf '  "remote_arch": "linux-x64",\n'
    printf '  "server_artifact": "server-linux-x64.tar.gz",\n'
    printf '  "server_sha256": "%s",\n' "$(sha_of "$b/server-linux-x64.tar.gz")"
    printf '  "client_linux_artifact": "vscode-linux-x64.tar.gz",\n'
    printf '  "client_linux_sha256": "%s",\n' "$(sha_of "$b/vscode-linux-x64.tar.gz")"
    printf '  "client_windows_artifact": "VSCodeUserSetup-x64-1.0.0.exe",\n'
    printf '  "client_windows_sha256": "%s",\n' "$(sha_of "$b/VSCodeUserSetup-x64-1.0.0.exe")"
    printf '  "cli_artifact": null,\n'
    if [ "$with_cli" = "1" ]; then
      printf '  "remote_ssh_cli_artifact": "cli-alpine-x64.tar.gz",\n'
      printf '  "remote_ssh_cli_sha256": "%s",\n' "$(sha_of "$b/cli-alpine-x64.tar.gz")"
    else
      printf '  "remote_ssh_cli_artifact": null,\n'
    fi
    printf '  "server_web_artifact": null,\n'
    printf '  "extensions": []\n'
    printf '}\n'
  } > "$b/versions.json"
  rm -rf "$b/src" "$b/src-cli"
  tar -C "$b" -czf "$out" .
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

assert_extras_intact() {
  local dir="$1" what="$2"
  [ -f "$dir/data/User/settings.json" ] || fail "$what: data/ was pruned"
  [ -f "$dir/extensions/some.ext/package.json" ] || fail "$what: extensions/ was pruned"
  [ -f "$dir/client-installers/vscode-linux-x64.tar.gz" ] || fail "$what: client-installers/ was pruned"
  [ -f "$dir/server.log" ] || fail "$what: a log file was pruned"
  [ -f "$dir/not-a-commit.txt" ] || fail "$what: a non-commit file was pruned"
  [ -f "$OUTSIDE/keepme" ] || fail "$what: something outside INSTALL_DIR was removed"
  [ -d "$OUTSIDE" ] || fail "$what: the symlink target directory outside INSTALL_DIR was removed"
}

assert_commit_gone() {
  local dir="$1" c="$2" what="$3"
  [ -e "$dir/bin/$c" ] && fail "$what: bin/$c survived"
  [ -e "$dir/code-$c" ] && fail "$what: code-$c survived"
  [ -e "$dir/cli/servers/Stable-$c" ] && fail "$what: cli/servers/Stable-$c survived"
  [ -e "$dir/vscode-cli-$c.tar.gz" ] && fail "$what: the CLI archive survived"
  [ -e "$dir/vscode-cli-$c.tar.gz.done" ] && fail "$what: the .done marker survived"
  return 0
}

assert_commit_present() {
  local dir="$1" c="$2" what="$3"
  [ -f "$dir/bin/$c/product.json" ] || fail "$what: bin/$c is missing"
  [ -e "$dir/code-$c" ] || fail "$what: code-$c is missing"
  [ -d "$dir/cli/servers/Stable-$c" ] || fail "$what: cli/servers/Stable-$c is missing"
}

BUNDLE_C="$TMP/bundle-c.tar.gz"
BUNDLE_C_NOCLI="$TMP/bundle-c-nocli.tar.gz"
make_bundle "$C" "$BUNDLE_C"
make_bundle "$C" "$BUNDLE_C_NOCLI" 0

# ── default: a completed install leaves exactly one version ─────────────
DIR1="$TMP/install1"
mkdir -p "$DIR1"
fake_commit "$DIR1" "$A"
fake_commit "$DIR1" "$B"
fake_extras "$DIR1"
BEFORE1="$(cd "$DIR1" && find . | sort)"
printf '%s\n' "$BEFORE1" > "$TMP/before1.txt"
"${VSA[@]}" --mode offline --bundle-path "$BUNDLE_C" --install-dir "$DIR1" >/dev/null 2>"$TMP/install1.log"
(cd "$DIR1" && find . | sort) > "$TMP/after1.txt"
assert_commit_present "$DIR1" "$C" "install prune"
assert_commit_gone "$DIR1" "$A" "install prune"
assert_commit_gone "$DIR1" "$B" "install prune"
assert_extras_intact "$DIR1" "install prune"
[ -L "$DIR1/bin/$D" ] || fail "install prune: the symlink out of the tree was removed"
grep -q 'pruned 2 older version' "$TMP/install1.log" \
  || fail "install prune did not log what it pruned: $(cat "$TMP/install1.log")"

# ── --keep-old opts out ─────────────────────────────────────────────────
DIR2="$TMP/install2"
mkdir -p "$DIR2"
fake_commit "$DIR2" "$A"
fake_commit "$DIR2" "$B"
fake_extras "$DIR2"
"${VSA[@]}" --mode offline --bundle-path "$BUNDLE_C" --install-dir "$DIR2" --keep-old >/dev/null 2>&1
for c in "$A" "$B" "$C"; do
  assert_commit_present "$DIR2" "$c" "--keep-old"
done
assert_extras_intact "$DIR2" "--keep-old"

# ── an install that never completed prunes nothing ──────────────────────
# No CLI archive in the bundle means no .done marker for the new commit.
DIR3="$TMP/install3"
mkdir -p "$DIR3"
fake_commit "$DIR3" "$A"
fake_commit "$DIR3" "$B"
fake_extras "$DIR3"
"${VSA[@]}" --mode offline --bundle-path "$BUNDLE_C_NOCLI" --install-dir "$DIR3" >/dev/null 2>"$TMP/install3.log"
[ -e "$DIR3/vscode-cli-$C.tar.gz.done" ] && fail "the no-CLI bundle wrote a .done marker after all"
for c in "$A" "$B"; do
  assert_commit_present "$DIR3" "$c" "incomplete install"
done
assert_extras_intact "$DIR3" "incomplete install"
grep -q 'install did not complete' "$TMP/install3.log" \
  || fail "an incomplete install did not say why it skipped the prune"

# ── standalone --prune keeps the current commit ─────────────────────────
DIR4="$TMP/install4"
mkdir -p "$DIR4"
fake_commit "$DIR4" "$A"
fake_commit "$DIR4" "$B"
fake_commit "$DIR4" "$C"
fake_extras "$DIR4"
# A and B carry markers and CLI binaries too. No versions.json here, so
# the newest marker decides, and C's is newest.
touch -t 202001010000 "$DIR4/vscode-cli-$A.tar.gz.done" "$DIR4/vscode-cli-$B.tar.gz.done"
touch "$DIR4/vscode-cli-$C.tar.gz.done"
"${VSA[@]}" --prune --install-dir "$DIR4" > "$TMP/prune4.out" 2>"$TMP/prune4.log"
assert_commit_present "$DIR4" "$C" "--prune"
assert_commit_gone "$DIR4" "$A" "--prune"
assert_commit_gone "$DIR4" "$B" "--prune"
assert_extras_intact "$DIR4" "--prune"
grep -q "keeping     : $C" "$TMP/prune4.out" || fail "--prune did not name the commit it kept"
grep -qF "removed $DIR4/bin/$A" "$TMP/prune4.out" || fail "--prune did not print the paths it removed"
grep -qE '^freed [0-9]+ bytes across 2 version' "$TMP/prune4.out" \
  || fail "--prune did not print the bytes freed: $(cat "$TMP/prune4.out")"
# nothing left to do the second time
"${VSA[@]}" --prune --install-dir "$DIR4" > "$TMP/prune4b.out" 2>&1
grep -q 'across 0 version' "$TMP/prune4b.out" || fail "a second --prune found work to do"

# ── --prune refuses when no install ever completed ──────────────────────
DIR5="$TMP/install5"
mkdir -p "$DIR5"
fake_commit "$DIR5" "$A" 0
fake_commit "$DIR5" "$B" 0
if "${VSA[@]}" --prune --install-dir "$DIR5" >/dev/null 2>"$TMP/prune5.err"; then
  fail "--prune with no .done marker anywhere should refuse"
fi
grep -q 'refusing to prune' "$TMP/prune5.err" || fail "--prune refusal did not explain itself"
assert_commit_present "$DIR5" "$A" "--prune refusal"
assert_commit_present "$DIR5" "$B" "--prune refusal"

# ── --status reports the extra versions and their size ──────────────────
DIR6="$TMP/install6"
mkdir -p "$DIR6"
fake_commit "$DIR6" "$A"
fake_commit "$DIR6" "$B"
fake_commit "$DIR6" "$C"
printf '{"commit":"%s"}\n' "$C" > "$DIR6/versions.json"
"${VSA[@]}" --status --install-dir "$DIR6" > "$TMP/status6.out" 2>&1
grep -q "extra ver   : $A" "$TMP/status6.out" || fail "--status did not list extra version A"
grep -q "extra ver   : $B" "$TMP/status6.out" || fail "--status did not list extra version B"
grep -q "extra ver   : $C" "$TMP/status6.out" && fail "--status called the installed commit an extra version"
grep -qE '^extra total : 2 version\(s\), [0-9]+ bytes' "$TMP/status6.out" \
  || fail "--status did not total the space: $(cat "$TMP/status6.out")"
grep -q -- '--prune' "$TMP/status6.out" || fail "--status does not say how to reclaim the space"

# ── shared install: --link-home symlinks still resolve after a prune ────
SHARED_DIR="$TMP/opt/vscode-server"
mkdir -p "$SHARED_DIR"
fake_commit "$SHARED_DIR" "$A"
HOME_FAKE="$TMP/linkhome"
mkdir -p "$HOME_FAKE"
printf '{"commit":"%s"}\n' "$A" > "$SHARED_DIR/versions.json"
HOME="$HOME_FAKE" "${VSA[@]}" --link-home --install-dir "$SHARED_DIR" >/dev/null 2>&1
HOME="$HOME_FAKE" "${VSA[@]}" --mode offline --bundle-path "$BUNDLE_C" \
  --install-dir "$SHARED_DIR" --link-home >/dev/null 2>&1
assert_commit_gone "$SHARED_DIR" "$A" "shared prune"
DEST="$HOME_FAKE/.vscode-server"
for l in "bin/$C" "code-$C" "cli/servers/Stable-$C" "vscode-cli-$C.tar.gz" \
         "vscode-cli-$C.tar.gz.done" "versions.json"; do
  [ -L "$DEST/$l" ] || fail "shared prune: $l is not a symlink in the user's home"
  [ -e "$DEST/$l" ] || fail "shared prune: the symlink $DEST/$l no longer resolves"
done
# Links left behind for a pruned commit dangle rather than point somewhere
# wrong, and Remote-SSH's presence test treats that exactly like absent.
[ -e "$DEST/bin/$A" ] && fail "a link to a pruned commit still resolves"

echo "OK"
