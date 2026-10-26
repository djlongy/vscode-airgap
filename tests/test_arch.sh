#!/usr/bin/env bash
# Alpine is not offered by default; it still works when named.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# The page's host picker starts on linux-x64 and offers no Alpine host.
SELECT="$(sed -n '/<select id="arch">/,/<\/select>/p' "$ROOT/docs/index.html")"
sed -n 2p <<<"$SELECT" | grep -q 'value="linux-x64"' \
  || fail "page host picker does not start on linux-x64"
if grep -qi 'alpine' <<<"$SELECT"; then
  fail "page host picker still offers Alpine"
fi

# The scripts default to linux-x64 and still accept alpine-x64 when named.
grep -q "\[string\]\$Arch = 'linux-x64'" "$ROOT/bin/vscode-airgap.ps1" \
  || fail "vscode-airgap.ps1 -Arch default is not linux-x64"
grep -q "ValidateSet([^)]*'alpine-x64'" "$ROOT/bin/vscode-airgap.ps1" \
  || fail "vscode-airgap.ps1 no longer accepts -Arch alpine-x64"
grep -q '^readonly DEFAULT_SERVER_ARCH="linux-x64"' "$ROOT/bin/vscode-airgap.sh" \
  || fail "vscode-airgap.sh default arch is not linux-x64"
grep -q 'alpine-x64) echo "server-linux-alpine"' "$ROOT/bin/vscode-airgap.sh" \
  || fail "vscode-airgap.sh no longer maps --arch alpine-x64"

echo "test_arch: ok"
