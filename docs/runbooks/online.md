# Runbook: online mode (internet-connected host)

Use this on a machine with outbound HTTPS to prepare an air-gapped
Remote-SSH connection, or optionally to run the secondary serve-web/tunnel
paths.

## 1. Straight install (latest stable, primary Remote-SSH path)

```bash
./bin/vscode-airgap.sh --mode online
```

- Resolves the latest `stable` release for `server-linux-x64`
  (Remote-SSH's classic server — mandatory), `cli-alpine-x64` (handshake
  + exec-server CLI), the Linux x64 desktop tarball, and the Windows
  x64 User Setup (both mandatory client installers, commit-matched to
  the server).
- Installs both layouts Remote-SSH may look for:
  `~/.vscode-server/bin/<commit>/` (classic) and
  `~/.vscode-server/code-<commit>` plus
  `cli/servers/Stable-<commit>/server/` (exec-server).
- Stages the client installers at `~/.vscode-server/client-installers/`
  and prints install instructions for the operator's laptop.

This is meant to run **on the air-gapped host itself**, as the same user
Remote-SSH will connect as — see `docs/runbooks/airgap.md` for the actual
air-gap flow (bundle here, install there with zero network). Running it
directly online-mode-on-the-target only makes sense if that host
genuinely has (or temporarily has) internet access.

## 2. Behind an egress proxy

The script does nothing special for proxies — curl and Python's urllib
(used for extension queries) both read the standard environment variables
natively:

```bash
export HTTPS_PROXY=http://proxy.example:3128
export NO_PROXY=localhost,127.0.0.1,.internal.example
./bin/vscode-airgap.sh --mode online
```

## 3. Pin an exact commit (or semver) + bundle a set of extensions

```bash
./bin/vscode-airgap.sh --mode online \
  --commit a5b500951314efd502d07465bd138dfbd714a960 \
  --extensions-file team-extensions.txt \
  --extensions ms-python.python

# or pin by semver instead — resolved through microsoft/vscode's git tags
# and confirmed live against the CDN before use (see --list-versions below)
./bin/vscode-airgap.sh --mode online --version 1.96.2 \
  --extensions-file team-extensions.txt
```

`--extensions-file` is a newline-delimited list of `publisher.name` IDs
(`#` comments and blank lines ignored); unioned with `--extensions`
(comma list), duplicates deduped. Each is resolved to the newest version
whose declared VS Code engine range accepts the bundled version — not a
stale pin. See `docs/reference/download-urls.md` for exactly how.

## 3b. List pinnable versions

```bash
./bin/vscode-airgap.sh --list-versions
./bin/vscode-airgap.sh --list-versions --format json
./bin/vscode-airgap.sh --list-versions --refresh   # force a fresh git fetch + CDN re-check
```

Standalone — no `--mode` needed. Newest first, with a CDN-availability
column derived from a cached boundary (Microsoft prunes old builds off
the CDN; `--refresh` re-derives the boundary live). The column is
informational — `--version <ver>` always does its own fresh,
authoritative check before ever using a resolved commit. Requires `git`,
`curl`, and `python3`; fails fast and clearly with no network rather than
hanging (verified live under `docker run --network none`).

## 4. Real Remote Tunnels (needs internet + a Microsoft/GitHub account)

```bash
./bin/vscode-airgap.sh --mode online --tunnel
```

Fetches a CLI matching **this machine's** architecture and runs
`code tunnel` after install. Interactive on first run (device-code
login) — not suitable for unattended automation. This is the feature
most people mean by "VS Code Remote Tunnels"; it needs live internet on
this host for the lifetime of the tunnel and is not what makes this tool
useful for an actually air-gapped host — see
`docs/runbooks/remote-ssh-realm-otp.md` for that.

## 5. Optional: `serve-web` instead of / alongside Remote-SSH

```bash
./bin/vscode-airgap.sh --mode online --serve-web
```

Also fetches CLI + server-web (matching **this machine's** architecture,
not `--arch`) and starts `code serve-web` bound to `BIND_ADDR:PORT`
(default `127.0.0.1:8000`) after install. Still stages the Remote-SSH
server too — the two paths aren't mutually exclusive, `--serve-web` is
additive.

## 6. Download only, install/start later

```bash
./bin/vscode-airgap.sh --mode online --download-only
```

## 7. Print the SSH/VS Code config templates

```bash
./bin/vscode-airgap.sh --emit-ssh-config
```

Standalone — no `--mode` or network needed. Writes
`ssh-config.example`, JSONC `settings.json.example` (`//` comments, not
fake `"// key"` pairs), and `remote-host.example`. See
`docs/runbooks/remote-ssh-realm-otp.md`.

## 8. Check what's installed

```bash
./bin/vscode-airgap.sh --status --install-dir ~/.vscode-server
```
