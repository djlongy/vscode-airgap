# Design: VS Code Server for air-gapped networks

## Problem

"Set up VS Code Server for Remote Tunnels so a client can connect in an
air-gapped network" is, taken literally, close to a contradiction.
Microsoft's Remote Tunnels feature (`code tunnel`) is built to punch through
NAT using Microsoft's own hosted relay — it authenticates against
GitHub/Microsoft and keeps a persistent outbound connection to
`*.rel.tunnels.api.visualstudio.com`. There is no self-hosted relay mode and
no offline mode. An air-gapped host, by definition, cannot reach that relay.

## Decision (v2 — Remote-SSH is primary, revised 2026-08-17)

**v1 of this tool made `code serve-web` the primary answer.** Operator
feedback after testing v1 corrected that: the actual, already-open door
into an air-gapped host is SSH port 22, already authenticated with realm
(GSSAPI/Kerberos) + OTP — `serve-web` is a *second* listener on a *second*
port that has to be separately opened, authenticated, and trusted, when
Remote-SSH gets there over infrastructure that already exists. v2 makes
Remote-SSH the primary path and keeps tunnels/serve-web as explicit,
secondary, opt-in options:

1. **Remote-SSH (default, both `online` and `offline` modes)** — download
   the exact commit's classic server (`server-linux-x64`) **and** the
   alpine CLI (`cli-alpine-x64`) plus matching Linux/Windows **desktop
   client installers** (same commit). Install both layouts the client
   may pick — classic `~/.vscode-server/bin/<commit>/` and exec-server
   `~/.vscode-server/code-<commit>` plus
   `cli/servers/Stable-<commit>/server/` — and write the handshake
   tarball (`vscode-cli-<commit>.tar.gz` + `.done` last). Stage the
   client installers + any extension VSIX for the operator. Zero new
   ports, zero new listeners; connects over the SSH session that's
   already there.
2. **`--serve-web` (opt-in, either mode)** — the v1 path, kept because
   some operators do want browser access without a VS Code Desktop
   install. Fetches CLI + server-web matching the arch of the machine
   *running this script*, starts `code serve-web`.
3. **`--tunnel` (opt-in, online mode only)** — real Remote Tunnels, for
   hosts that genuinely have internet and just want the convenience.
   Refused outright in `--mode offline` with an explanation, not
   silently degraded.

## Why the client installers are mandatory, not optional

Remote-SSH negotiates a commit between client and server. If the VS Code
Desktop client's own commit doesn't match what's staged on the remote, it
tries to reconcile the mismatch itself — typically by downloading a
server matching *its own* commit, which is exactly the network call
air-gapping exists to prevent. Bundling the Linux x64 tarball and Windows
x64 User Setup (both **user-space/per-user**, not a system package —
no admin rights, no package manager dependency, no root needed to
install) at the *same* commit as the staged server means at least one
operator platform's Help → About matches on first connect, without a
side-channel "please install exactly version X" instruction that's easy
to get wrong by hand.

## Alternatives considered

- **`code-server` (coder.com fork)**: a different project with its own
  release channel; explicitly out of scope — the ask was Microsoft's own
  VS Code Server / Remote-SSH / Remote Tunnels stack.
- **Building our own SSH client or auth layer**: rejected outright, both
  in v1 and v2. Realm auth, OTP, and the port-22-only constraint are
  entirely standard `ssh_config`/`sshd_config`/VS Code settings — see
  `docs/runbooks/remote-ssh-realm-otp.md`. This tool's job stops at
  getting the right bytes onto disk in the right place before the first
  connection; it does not touch credentials, tickets, or OTP seeds.
- **Building our own relay** (to make tunnels air-gap-capable): rejected.
  Reimplementing tunnel relay semantics is a large, security-sensitive
  undertaking for a small standalone script, and the actual requirement (a client
  reaches an isolated VS Code instance) is already solved by
  Remote-SSH over an already-open, already-authenticated port.

## Chain of custody for integrity (corrected 2026-08-17)

**v1's docs claimed Microsoft publishes no checksum for the CLI/server
artifact family — that was wrong**, found and corrected during v2's
research: `GET /api/update/<platform-segment>/<channel>/latest` returns a
Microsoft-issued `sha256hash` for every platform segment this tool uses,
not just the desktop build (see `docs/reference/download-urls.md`). This
tool now uses that as the **primary** checksum source when resolving
"latest," and only falls back to self-computing sha256 at download time
when an explicit `--commit` pin is given (Microsoft's endpoint only
serves checksums for the *current* latest per platform — confirmed live,
an older commit 204s). `versions.json` records which kind of checksum
backs each artifact (`"microsoft"` vs `"self"`) rather than presenting
both as equivalent, and `--mode offline` verifies every artifact against
that manifest before extracting anything either way.

## Non-goals

- TLS termination for `serve-web` (secondary path) — the script binds
  plain HTTP by design and documents SSH port-forwarding (or a reverse
  proxy the operator already runs) as the encrypted-hop option; adding a
  TLS implementation to this script would duplicate infrastructure most
  networks already have and get the crypto wrong in a way that's hard to
  review from a single script. Moot for the primary Remote-SSH path,
  which is already encrypted end-to-end by SSH itself.
- Multi-user auth beyond the SSH session (primary) or the connection
  token (secondary `serve-web`) — this tool does not layer its own auth,
  store credentials, or handle OTP seeds/Kerberos tickets. It writes
  *example* `ssh_config` / JSONC `settings.json` / remote-host
  templates (`--emit-ssh-config`); the operator's existing realm/OTP
  infrastructure does the actual authenticating.
- A custom SSH client or SSH protocol extension — explicitly out of
  scope per the operator's own instruction; realm+OTP+port-22 is entirely
  standard OpenSSH client/server configuration.
