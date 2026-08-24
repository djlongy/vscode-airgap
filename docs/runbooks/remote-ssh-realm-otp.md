# Runbook: Remote-SSH with realm auth + OTP, port 22 only

This is the primary connection path — Remote-SSH over the port that's
already open, not a new listener and not Microsoft's tunnel relay. It's
SSH client / VS Code Remote-SSH extension configuration, not a new
protocol. This script's job is getting the right server bits onto the
remote host *before* the first connection so nothing tries to download
anything mid-session.

`--emit-ssh-config` writes these **templates** (also under `contrib/`),
one sshd drop-in per `--user`. They are not live until you copy them.
Write them somewhere you own — a root-owned `--install-dir` such as
`/opt/vscode-server` needs `sudo`, and the tool stops with that advice
rather than writing half the set:

| Template | Who | Put it here |
|---|---|---|
| `ssh-config.example` | operator laptop | Unix/macOS: `~/.ssh/config` · Windows: `C:\Users\youruser\.ssh\config` |
| `settings.json.example` | operator laptop | Windows: `%APPDATA%\Code\User\settings.json` · macOS: `~/Library/Application Support/Code/User/settings.json` · Linux: `~/.config/Code/User/settings.json` |
| `50-vscode-<user>.conf` (one per `--user`; `contrib/remote-host.example` is the browsable copy) | air-gapped host (root) | `/etc/ssh/sshd_config.d/50-vscode-<user>.conf` |
| `fapolicyd-vscode.rules` | air-gapped host (root) | `/etc/fapolicyd/rules.d/25-vscode-server.rules` (or `$SELF --install-fapolicyd`) |

`settings.json.example` is **JSONC**: comments are `//` lines. Do **not**
comment with fake keys such as `"// useLocalServer": "…"`. Those are
real JSON properties, not comments.

## 1. Pre-stage the server (this script's job)

```bash
./bin/vscode-airgap.sh --mode offline --bundle-path ./vscode-bundle.tar.gz
```

Per-user: run as the Remote-SSH account, `--install-dir` default
(`~/.vscode-server`). Shared: run as root with
`--install-dir /opt/vscode-server --link-home --user <ssh-user>`.
The bootstrap script the client runs is chosen by a staged rollout, not
by extension version, so the install puts **both** layouts on disk:

```
INSTALL_DIR/bin/<commit>/                 # classic
INSTALL_DIR/code-<commit>                 # exec-server CLI binary
INSTALL_DIR/cli/servers/Stable-<commit>/server/
INSTALL_DIR/vscode-cli-<commit>.tar.gz    # handshake archive
INSTALL_DIR/vscode-cli-<commit>.tar.gz.done   # written LAST
```

`--link-home` then points the same paths under `~/.vscode-server` at
INSTALL_DIR (symlinks). Per-user `data/`, `extensions/`, and `.token`
stay in home.

Classic contents: `node`, `bin/code-server`,
`bin/helpers/check-requirements.sh` (executable), `out/server-main.js`,
a `product.json` whose `commit` field matches the client Help → About
commit exactly. Either presence test passing means the download branch
is never entered.

**There is no VS Code setting that means "never attempt a server
download, ever."** `remote.SSH.allowLocalServerDownload` sounds like it
but isn't — see §4. Pre-staging the exact commit *is* the fail-closed
mechanism. Still set `remote.SSH.localServerDownload` to `"off"` so a
staging miss fails fast instead of `wget -O` truncating the CLI tarball
to zero bytes and polling forever.

## 2. Match the client commit (this script's job, operator's install)

`--mode online`/`bundle` also fetch a Linux x64 desktop tarball and a
Windows x64 User Setup — both pinned to the exact same commit as the
staged server. Install **one of these** on the operator's laptop:

```bash
# Linux laptop
tar -xzf vscode-linux-x64.tar.gz
./VSCode-linux-x64/bin/code

# Windows laptop
VSCodeUserSetup-x64-<version>.exe   # per-user, no admin rights needed
```

Remote-SSH's client and server negotiate a commit. If the client's own
commit doesn't match what's staged on the remote, it tries to reconcile
by downloading a server matching *its own* commit. On an air-gapped
host that download fails. Matching commits on both ends is what makes
pre-staging pay off.

## 3. `~/.ssh/config` — realm + OTP, port 22 only

See [`contrib/ssh-config.example`](../../contrib/ssh-config.example).
Unix client (ControlMaster) and Windows client (no ControlMaster) are
separate `Host` blocks in that file.

Unix / macOS:

```
PreferredAuthentications publickey,gssapi-with-mic,keyboard-interactive,password
PubkeyAuthentication yes
# IdentityFile ~/.ssh/id_ed25519
GSSAPIAuthentication yes
GSSAPIDelegateCredentials yes
ControlMaster auto
ControlPath ~/.ssh/sockets/%r@%h-%p
ControlPersist 600
```

Windows (native OpenSSH optional feature):

```
PreferredAuthentications publickey,keyboard-interactive
PubkeyAuthentication yes
GSSAPIAuthentication no
NumberOfPasswordPrompts 3
```

- **Pubkey first, so extra Remote-SSH channels skip the OTP prompt.**
  Put the matching public key in `~/.ssh/authorized_keys` on the host
  (or the realm SSH pubkey store). `keyboard-interactive` stays as the
  fallback for first-time / OTP login. Uncomment `IdentityFile` and
  point it at the private key. Auth method selection lives in
  `ssh_config`/`sshd_config` — Remote-SSH just shells out to a normal
  SSH client.
- **Session reuse is required.** Remote-SSH opens more than one SSH
  channel. Realm TOTP is anti-replay inside the current 30s window, so
  a second unauthenticated channel is denied.
  - Unix / macOS: `ControlMaster auto` (`mkdir -p ~/.ssh/sockets`).
  - Windows: Win32-OpenSSH **ignores** ControlMaster. Reuse is
    `remote.SSH.useLocalServer: true` in `settings.json`, not this file.
- **No `ProxyJump`, no extra ports.** Only port 22 is open on the
  target. The example comments out where a `ProxyJump` would go.

An `ssh_config` file is optional if you only ever connect by
`user@host`. Use one when you need the Host alias, auth-method order,
or ControlMaster. If you set `remote.SSH.configFile`, that file must
contain the same Host alias as `remote.SSH.remotePlatform`.

## 4. VS Code `settings.json` (client laptop only)

See [`contrib/settings.json.example`](../../contrib/settings.json.example).
These keys do nothing on the remote host. After connect, the Remote-SSH
log must dump the same values.

The file is JSONC. Comments are `//` lines above each key.

| Setting | Value | Why |
|---|---|---|
| `remote.SSH.showLoginTerminal` | `true` | Reveals the SSH login terminal. Without this, the keyboard-interactive OTP prompt can run in a background process with no place to type. |
| `remote.SSH.useLocalServer` | `true` | One shared SSH connection for Remote-SSH's extra channels. Required for OTP. This is the Windows mux (Win32-OpenSSH has no ControlMaster). Pair with `remoteServerListenOnSocket: false` or it is silently undone. First connect still needs `showLoginTerminal`. |
| `remote.SSH.useExecServer` | `false` | Defaults to `true`. A staged rollout (not an extension version) can still pick the exec-server bootstrap. Confirm the connect log dumps `remote.SSH.useExecServer = false`. This tool stages both layouts so either script's presence test passes. |
| `remote.SSH.localServerDownload` | `"off"` | A staging miss otherwise `wget -O` truncates `vscode-cli-<commit>.tar.gz` to zero bytes and the install script polls forever. `off` fails fast. |
| `remote.SSH.remoteServerListenOnSocket` | `false` | `true` silently forces `useLocalServer` off. Put it in `settings.json` — Windows ignores the UI toggle. OTP mux depends on `useLocalServer` staying on. |
| `remote.SSH.lockfilesInTmp` | `true` | Lockfiles in `/tmp` (or `%TEMP%`) instead of the server install folder. Matters if home is NFS/distributed. Harmless otherwise. |
| `remote.SSH.connectTimeout` | `60` | Default is 15s. A realm+OTP login (ticket check + typing a code) routinely takes longer than a key-based connect. |
| `remote.SSH.path` | `C:\Windows\System32\OpenSSH\ssh.exe` | Windows only. Force the native OpenSSH optional feature, not a third-party `ssh.exe` on `PATH`. Omit this key on Unix. |
| `remote.SSH.configFile` | optional | If set, that file must contain the Host alias below. Commented out in the example. |
| `remote.SSH.remotePlatform` | `{"<host>": "linux"}` | Skips a remote OS-detection round trip. The key must match the Host alias. |

**Do not set `remote.SSH.allowLocalServerDownload` expecting "never
download."** Its real meaning is: if the *remote* download fails, fall
back to downloading on the *client* and `scp` the bits over. It is not
a switch for "never attempt any download." The guarantee this tool
provides is pre-staging (§1) plus `localServerDownload: "off"` so a
miss fails fast.

Write the file as UTF-8 **without a BOM**. A UTF-8 BOM makes VS Code
reject the JSON.

## 5. Remote host (sshd only) — one drop-in per user

See [`contrib/remote-host.example`](../../contrib/remote-host.example).
`--emit-ssh-config --user NAME` writes `50-vscode-NAME.conf`; copy it to
`/etc/ssh/sshd_config.d/`, then `sshd -t && systemctl reload sshd`. None
of the `remote.SSH.*` keys go here.

Everything in that file is inside `Match User NAME`, so it turns on
**pubkey** (extra channels stop re-prompting for OTP) and the
TCP/stream forwards Remote-SSH needs **for that account only**. The
host's hardened baseline — pubkey off, OTP through PAM — still applies
to every other user, and a colleague gets their own
`50-vscode-<name>.conf` rather than an edit to this one.

`AuthenticationMethods publickey keyboard-interactive` reads as "either
one is enough". Do **not** write it comma-separated
(`publickey,keyboard-interactive`): that demands both and forces the
token prompt on every channel. If the site's baseline needs more than
keyboard-interactive on its own, restate it as the second alternative.

Verify with the resolved config rather than by reading files:

```bash
sshd -T -C user=NAME          | grep -E 'pubkeyauth|authenticationmethods'
sshd -T -C user=SOMEONE-ELSE  | grep -E 'pubkeyauth|authenticationmethods'
```

The second must still show the baseline. On EL8 add
`Include /etc/ssh/sshd_config.d/*.conf` at the top of
`/etc/ssh/sshd_config` first — the stock file has no `Include` line, so
the directory is ignored entirely (checked on OpenSSH 8.0p1).

`PerSourcePenaltyExemptList` (OpenSSH 9.9+ banning the laptop IP after a
hung OTP prompt) is global-only and cannot be scoped to a user, so it is
not in the emitted file. An admin adds it to the host's own hardening
file if operators get locked out.

First Factor = password. Second Factor = TOTP (not the password again).
After a pubkey is authorized, subsequent channels authenticate with
the key and skip both factors.

## 6. Why port 22 is enough

Remote-SSH listens on **localhost** on the remote host. The client
reaches it through the SSH session you already have. You do not open a
second "VS Code" port. Keep
`remote.SSH.remoteServerListenOnSocket` `false` or Windows loses
`useLocalServer` and the second OTP is denied.

## 7. Extensions

Bundled extensions land at `~/.vscode-server/extensions-to-install/` on
the remote (see `docs/reference/download-urls.md` for why they aren't
auto-installed). Once connected: Extensions view → **"Install from
VSIX..."** → pick each file in that directory.

## 8. Verifying the layout before a real connection

```bash
./bin/vscode-airgap.sh --status
```

Confirms `versions.json`'s commit matches both layouts: classic
`bin/<commit>/` (`product.json`, `bin/code-server`, `node`) and
exec-server `code-<commit>` plus `cli/servers/Stable-<commit>/server/`,
plus a non-empty handshake tarball. That is the inspectable proxy for
"Remote-SSH will find this and skip downloading," short of an actual
live connection through a real realm+OTP-gated sshd, which this repo's
test harness deliberately doesn't require (see
`docs/designs/vscode-airgap-tunnels.md`).
