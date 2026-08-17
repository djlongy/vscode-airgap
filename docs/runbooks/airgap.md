# Runbook: air-gap mode (bundle on an online host, install offline)

Primary path: **Remote-SSH**, not `serve-web`/tunnels. This stages the
exact VS Code Server commit + matching client installers so Remote-SSH
connects over the port that's already open (22) without ever trying to
download anything. See `docs/runbooks/remote-ssh-realm-otp.md` for the
SSH/VS Code settings side once the bits are staged.

## 0. Matching an already-running remote server (don't always grab latest)

If you're re-testing against a remote that's already staged with an older
build, re-resolving "latest" every run just churns downloads for nothing
and can leave the client ahead of what's actually running. Pin instead:

```bash
# On the remote (works even fully offline — no network involved):
./bin/vscode-airgap.sh --status
# or directly:
cat ~/.vscode-server/bin/*/product.json | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d["commit"], d["version"])'

# On a connected host: see what's pinnable, then pin it explicitly
./bin/vscode-airgap.sh --list-versions | head -20
./bin/vscode-airgap.sh --mode bundle --version 1.96.2 --bundle-path ./v1.96.2.tar.gz
```

`--version` accepts an exact `X.Y.Z` (a leading `v` is fine —
`v1.96.2` also works) and resolves it through `microsoft/vscode`'s git
tags, then confirms live that the artifact is still on Microsoft's CDN
before using it — Microsoft prunes old builds, so an old-but-real tag can
still fail with a clear error rather than silently substituting latest.
See `docs/reference/download-urls.md` for exactly how this resolves and
what "1.32.0 doesn't work" actually means (that specific version was the
worked example during development — its tag is real, its CDN artifact is
gone). `--list-versions` prints the 10 newest resolvable versions by
default (newest first, with a CDN-availability column; `--limit N` or
`--all` for more, `--refresh` to force a fresh check) — `--version`
still accepts any cached tag, not only a printed row.

## 1. On a host WITH internet: build the bundle

```bash
./bin/vscode-airgap.sh --mode bundle \
  --commit a5b500951314efd502d07465bd138dfbd714a960 \
  --bundle-path ./vscode-bundle.tar.gz \
  --extensions-file team-extensions.txt

# or, equivalently and more readably, pin by version instead of commit:
./bin/vscode-airgap.sh --mode bundle --version 1.96.2 \
  --bundle-path ./vscode-bundle.tar.gz --extensions-file team-extensions.txt
```

Pinning `--commit` (or `--version`, which resolves to a commit before
anything else happens) makes the bundle reproducible — rerunning later
with the same commit produces the same downloads (self-computed sha256
for anything but the current latest, since Microsoft's checksum endpoint
only serves that — see `docs/reference/download-urls.md`). `--commit`
wins if both are set; `--version` is ignored entirely in that case, not
just for resolution — it never leaks into a filename or the manifest.

Output tarball contains:

```
versions.json
server-linux-x64.tar.gz          # Remote-SSH classic server for the Linux host
cli-alpine-x64.tar.gz            # handshake + exec-server CLI (not cli.tar.gz)
vscode-linux-x64.tar.gz          # client, user-space, Linux laptops
VSCodeUserSetup-x64-<ver>.exe    # client, Windows user setup
extensions/*.vsix
```

Move it across the air gap by whatever sneakernet path your policy
allows — out of scope for this script.

## 2. On the air-gapped host: install with network blocked

Run this **logged in as the exact user account Remote-SSH will connect
as** — the install path (`~/.vscode-server`) is per-user, and that's
the whole point: it has to be the account the SSH session lands in.
Offline install writes both layouts (classic `bin/<commit>/` and
exec-server `code-<commit>` + `cli/servers/Stable-<commit>/server/`)
plus the handshake tarball.

The script never calls `curl` in `--mode offline` — there's nothing to
disable. To *prove* that during testing, run with network genuinely cut:

```bash
# Option A: no network namespace access at all (e.g. --network none)
# Option B (defence in depth): point every proxy var at a black hole
export HTTPS_PROXY=http://127.0.0.1:1 HTTP_PROXY=http://127.0.0.1:1

./bin/vscode-airgap.sh --mode offline --bundle-path ./vscode-bundle.tar.gz
```

Expected: sha256 verification against `versions.json` for every artifact
(Microsoft-published where the bundle used "latest", self-computed for a
pinned commit — both distinguished, not conflated), extraction straight
into both Remote-SSH layouts under `~/.vscode-server`, client installers + extension
VSIX files staged, then the script prints next steps. If the bundle is
corrupt or was tampered with in transit, the sha256 check fails loudly
and nothing is installed.

## 3. Install the matching client on your laptop

```bash
# Linux laptop
tar -xzf vscode-linux-x64.tar.gz && ./VSCode-linux-x64/bin/code

# Windows laptop
VSCodeUserSetup-x64-<ver>.exe   # per-user, no admin rights
```

Confirm the commit matches: Help → About in the client should show the
same commit as `./bin/vscode-airgap.sh --status`'s `commit` field. A
mismatched client commit is exactly what makes Remote-SSH try to
reconcile by downloading a server over the wire — the one failure mode
all of this exists to prevent.

## 4. Connect

See `docs/runbooks/remote-ssh-realm-otp.md` for the full `~/.ssh/config`
+ JSONC `settings.json` + remote-host walkthrough (realm/GSSAPI + OTP,
port 22 only, ControlMaster on Unix / `useLocalServer` on Windows).
Quick start:

```bash
./bin/vscode-airgap.sh --emit-ssh-config
# writes templates AND prints the destination path for each file
```

Then in VS Code: **Remote-SSH: Connect to Host...** → the `Host` alias
from your `ssh_config`.

## 5. Extensions

Bundled `.vsix` files land at
`~/.vscode-server/extensions-to-install/`. `code --install-extension`
does not reliably target this layout (verified live — see
`docs/reference/download-urls.md`), so once connected: Extensions view →
**"Install from VSIX..."** for each file.

## 6. Optional secondary path: `serve-web` (browser, no VS Code Desktop)

```bash
./bin/vscode-airgap.sh --mode offline --bundle-path ./vscode-bundle.tar.gz \
  --serve-web --bind 0.0.0.0 --port 8000
```

Only if you specifically want browser access in addition to (or instead
of) Remote-SSH — see the LIMITATIONS section of `--help` for why this is
now secondary. Client reaches it directly on the LAN or via
`ssh -L 8000:localhost:8000 user@airgapped-host` (recommended — keeps
serve-web bound to `127.0.0.1` and avoids exposing it network-wide).

## 7. What "offline" actually guarantees

- No DNS lookups, no HTTP(S) calls, no marketplace calls during
  `--mode offline` — this script never invokes `curl`/`python3 urllib`
  on that path. Verified under `docker run --network none` with no
  `curl`, no `python3`, no `openssl` in the container at all.
- Every artifact is checksum-verified against the bundle's own manifest
  before extraction.
- `--tunnel` is hard-refused in offline mode with an explanation, not
  silently ignored.
- **Not covered by this script:** if you also pass `--serve-web`, the
  `code serve-web` binary itself makes one best-effort update-check call
  on startup (fails silently offline, server still starts) — see
  `docs/reference/download-urls.md`. That call comes from Microsoft's
  own binary, not from anything this script does.
- `./bin/vscode-airgap.sh --list-versions --bundle-path <bundle>` works
  fully offline too — reads the single version/commit already staged in
  that bundle's `versions.json`, no network attempted. `--list-versions`
  without `--bundle-path` genuinely needs network (git + CDN checks) and
  refuses honestly rather than hanging when there isn't any.
