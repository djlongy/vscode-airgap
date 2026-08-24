# vscode-airgap-tunnels

Stage a **VS Code Remote-SSH** connection to an air-gapped Linux host —
pre-install **both** server layouts (classic
`INSTALL_DIR/bin/<commit>/` and exec-server `code-<commit>` +
`cli/servers/Stable-<commit>/server/`) so the client never tries to
download anything, plus matching Linux/Windows client installers so
Help → About reports the same commit. Default `INSTALL_DIR` is
`~/.vscode-server`. A shared path such as `/opt/vscode-server` is
the fapolicyd-allowable shape where a host gives you one (a single
directory, every user); a home install stays fully supported. `--link-home`
puts the presence-test files in each user's `~/.vscode-server` as
symlinks so Remote-SSH still finds them. Connects over plain SSH port
22 with **pubkey first** (skips repeated OTP) and realm/OTP as the
fallback. `code serve-web` and Microsoft's Remote Tunnels are
secondary, opt-in paths.

```bash
# Online host: fetch latest stable, install Remote-SSH server + both
# client installers into ~/.vscode-server
./bin/vscode-airgap.sh --mode online

# Shared install (as root) on the air-gapped host. Everything created in
# youruser's home is chowned to youruser — see "Ownership under sudo".
sudo ./bin/vscode-airgap.sh --mode offline --bundle-path ./vscode-bundle.tar.gz \
  --install-dir /opt/vscode-server --link-home --user youruser \
  --install-fapolicyd

# Print ssh_config + JSONC settings.json + fapolicyd rule + one
# Match-scoped sshd drop-in per user (global hardening untouched).
# /opt/vscode-server is root-owned, so writing templates there needs sudo
# — or point --install-dir at a directory you own.
sudo ./bin/vscode-airgap.sh --emit-ssh-config --install-dir /opt/vscode-server \
  --user alice --user bob

# Match an already-running remote instead of always grabbing latest:
./bin/vscode-airgap.sh --list-versions | head -20
./bin/vscode-airgap.sh --mode bundle --version 1.96.2 --bundle-path ./v1.96.2.tar.gz
```

## Why this exists

"Set up VS Code Server for Remote Tunnels on an air-gapped network" is a
contradiction if taken literally — tunnels require a persistent outbound
connection to Microsoft's relay service, which an air-gapped host by
definition can't reach. This tool is honest about that split, and (as of
2026-08-17) makes the actually-air-gap-friendly path the default:

- **Remote-SSH (default)** — the door that's already open (port 22),
  already authenticated (realm + OTP). This tool's job is limited to
  getting both matching server layouts onto disk *before* the first
  connection, so whichever bootstrap script arrives, its presence test
  passes and the download branch is never entered.
- **`--serve-web` (opt-in)** — Microsoft's own local web-UI server, no
  relay involved, works air-gapped too — kept as a second option for
  operators who specifically want browser access without installing a
  VS Code Desktop client.
- **`--tunnel` (opt-in, online mode only)** — real Remote Tunnels, for
  hosts that genuinely have internet. Refused outright in offline mode
  with an explanation rather than silently degraded.

Full reasoning: [`docs/designs/vscode-airgap-tunnels.md`](docs/designs/vscode-airgap-tunnels.md).

## Ownership under sudo

Root is the normal way to run the shared install, and Remote-SSH then
connects as an ordinary user who has to write `data/`, logs and a
per-commit `.token` under `~/.vscode-server`. Everything this script
creates inside a user's home is therefore chowned back to that user:
`--link-home --user NAME` hands `~NAME/.vscode-server`, `bin/`, `cli/`,
`cli/servers/` and every symlink it makes to NAME — and repairs those
directories when an earlier root run left them root-owned. An install
whose `INSTALL_DIR` sits inside a home hands over the paths root
actually owns there. Paths the user already owns are never touched.

`/opt/vscode-server` and root's own `/root/.vscode-server` stay
root-owned, which is what `--shared` and the fapolicyd allow-list want.
`sudo` resets `HOME` to `/root` on most distributions, so a bare `sudo
vscode-airgap.sh --mode offline …` installs into `/root/.vscode-server`
— pass `--install-dir` explicitly, or install as the connecting user.

## Requirements

- `bash`, `curl` (online/bundle only), `tar`, `sha256sum`/`shasum`.
  `python3` is required on the online/bundle side when resolving
  extensions or a `--version` pin; `git` is additionally required for
  `--version`/`--list-versions` (semver→commit resolution via
  `microsoft/vscode`'s tags). `openssl` is used if present for the
  optional serve-web token, with a pure-shell fallback. The offline
  install path was tested with **none** of curl/python3/openssl/git
  present, under `docker run --network none`.
- Air-gapped target: Linux x86_64 (mandatory support) — arm64/armhf/Alpine
  also supported via `--arch`.
- Client installers bundled by default: Linux x64 (portable tarball) and
  Windows x64 (User Setup, per-user — no admin rights needed), both
  commit-matched to the staged server.

## Connecting from Windows

The client side is plain Win32-OpenSSH plus the Remote-SSH extension.
Nothing Windows-specific runs on the air-gapped host.

**1. ssh config — `%USERPROFILE%\.ssh\config`**
(`C:\Users\youruser\.ssh\config`). Take the *Windows* Host block from
[`contrib/ssh-config.example`](contrib/ssh-config.example) and keep only
that one: both blocks in the file share an alias, and OpenSSH uses the
first value it reads for each keyword.

```
Host airgapped-host
    HostName airgapped-host.example.realm
    User youruser
    Port 22
    PreferredAuthentications publickey,keyboard-interactive
    PubkeyAuthentication yes
    # IdentityFile ~/.ssh/id_ed25519
    GSSAPIAuthentication no
    NumberOfPasswordPrompts 3
```

`publickey` **first** is the point of the whole block. Remote-SSH opens
more than one SSH channel, and a realm TOTP is anti-replay inside its
30-second window, so every channel after the first is denied unless a
key can authenticate it. `keyboard-interactive` stays behind it for the
first login. Win32-OpenSSH expands `~` to `%USERPROFILE%`; the absolute
`C:\Users\youruser\.ssh\id_ed25519` works as well.

**2. Get the key onto the host** (PowerShell, once):

```powershell
ssh-keygen -t ed25519            # writes %USERPROFILE%\.ssh\id_ed25519
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub |
  ssh youruser@airgapped-host "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

On an SELinux host follow that with `restorecon -Rv ~/.ssh`, or sshd
ignores the file. If the realm has its own SSH pubkey store, publish the
key there and skip `authorized_keys` entirely.

**3. `ssh-agent` is a Windows service**, disabled by default. Only
needed for a passphrase-protected key:

```powershell
Set-Service ssh-agent -StartupType Automatic   # needs admin
Start-Service ssh-agent
ssh-add $env:USERPROFILE\.ssh\id_ed25519
```

**4. VS Code settings** — `%APPDATA%\Code\User\settings.json`, merged
from [`contrib/settings.json.example`](contrib/settings.json.example).
`remote.SSH.path` pins the native `ssh.exe` rather than a third-party
one on `PATH`; `remote.SSH.useLocalServer: true` together with
`remote.SSH.remoteServerListenOnSocket: false` is the channel reuse
(Win32-OpenSSH ignores `ControlMaster`); `remote.SSH.remotePlatform`
must name the same Host alias as the ssh config. Set
`remote.SSH.configFile` only when the config is somewhere other than
the default path, and point it at a file defining that same alias.

**5. Host side** — an admin installs *your* sshd drop-in, which turns
pubkey on for your account only:

```bash
# Emit somewhere you can write. The recommended /opt/vscode-server is
# root-owned, so emitting there needs sudo — the tool says so and stops
# rather than half-writing the set.
./bin/vscode-airgap.sh --emit-ssh-config --user youruser --install-dir ~/vscode-templates
sudo cp ~/vscode-templates/50-vscode-youruser.conf /etc/ssh/sshd_config.d/
sudo sshd -t && sudo systemctl reload sshd
sudo sshd -T -C user=youruser | grep -E 'pubkeyauth|authenticationmethods'
```

Nobody else's login changes. See "Multiple users on one host" below.

## Multiple users on one host

Two colleagues on the same air-gapped box, onboarded weeks apart, must
not disturb each other or anyone who never touches VS Code. Every piece
of this is additive per user.

**sshd is per-user, never global.** `--emit-ssh-config --user NAME`
writes `50-vscode-NAME.conf`
([`contrib/remote-host.example`](contrib/remote-host.example) is the
browsable copy) and every directive in it sits inside `Match User NAME`.
The host's hardened baseline — pubkey off globally, OTP through PAM —
still governs every other account, which is exactly what a CIS or
FreeIPA build wants. A colleague gets a second file; the first is never
edited. Re-running for the same user rewrites only that user's file.

Proof is `sshd -T`, which resolves the whole config for one user:

```bash
sudo sshd -T -C user=alice | grep -E 'pubkeyauth|authenticationmethods'
# pubkeyauthentication yes
# authenticationmethods publickey keyboard-interactive
sudo sshd -T -C user=someone-else | grep -E 'pubkeyauth|authenticationmethods'
# pubkeyauthentication no
# authenticationmethods keyboard-interactive      <- baseline, untouched
```

`AuthenticationMethods` entries separated by **spaces** are alternatives;
separated by **commas** they are all required. `publickey
keyboard-interactive` means a key alone is enough while the OTP path
still works for the first login. `publickey,keyboard-interactive` would
demand both and put the OTP prompt back on every channel, which is the
failure this exists to prevent. If the baseline demands more than
keyboard-interactive on its own, restate it as the second alternative.

Two things about `sshd_config.d` worth knowing before you trust it,
checked against OpenSSH 8.0p1 (EL8), 9.9p1 (EL9) and 10.0p2 (Debian 13):
a `Match` block in one drop-in does **not** scope the next file or the
rest of the parent config, so these files are independent; but within a
single file everything after `Match User NAME` belongs to that user,
which is why the emitted file ends with `Match all` — append below it
and you are global again. **EL8 ships no `Include` line at all**, so
`/etc/ssh/sshd_config.d/` is ignored there until an admin adds
`Include /etc/ssh/sshd_config.d/*.conf` at the *top* of
`/etc/ssh/sshd_config`. The `sshd -T` check above is how you find out.

Ordering decides the **global** baseline only, and the first global
value wins. A FreeIPA-enrolled host already ships `04-ipa.conf` with
`PubkeyAuthentication yes` set globally, so a hardening drop-in that
means to turn pubkey off for everyone has to sort *before* it — `01-`,
not `10-`. At `10-` that one line is silently a no-op and every account
keeps `pubkeyauthentication yes`. A global `AuthenticationMethods` in
the same hardening file does still apply (nothing earlier sets that
keyword), so key-only login is still refused; it is `PubkeyAuthentication`
alone that stays on. Either way this is a property of the host's
baseline, not of this tool — the per-user `Match` override wins for the
named user under both orderings, confirmed on a FreeIPA-enrolled EL9
host and reproduced against OpenSSH 9.9p1. Check the baseline with
`sshd -T -C user=someone-else`, never by reading the files.

**fapolicyd allow-lists `INSTALL_DIR`.** With a shared `/opt` tree that
is one rule for the whole host, and `--install-fapolicyd` re-run by the
second admin rewrites the same file and only reloads fapolicyd when the
content actually changed. With per-user home installs it is one rule per
home — see below.

**`--link-home` is already per user** and, with the ownership fix above,
each run only creates and chowns paths under that user's own
`~/.vscode-server`. Running it for a colleague leaves the first user's
symlinks and ownership exactly as they were.

**The server tree is shared where it can be.** One `/opt/vscode-server`,
world-readable, executed by everyone, allow-listed once. Nothing
user-specific in it.

## Pubkey fails but password/OTP works

Three unrelated faults look identical from the client: the key is
ignored and you get a password prompt. Take them in this order — the
first two steps identify which one you have, and guessing here is how
people lose an afternoon.

**1. `/var/log/secure` tells you the family, not the cause.**

```
Could not open user 'youruser' authorized keys /home/youruser/.ssh/authorized_keys: Permission denied
```

sshd could not *read* the file. This line is **identical** whether the
home is on NFS or the file is merely mislabelled on local disk — it does
not distinguish them, so do not stop here. A different line means a
different fault:

```
Authentication refused: bad ownership or modes for file /home/youruser/.ssh/authorized_keys
```

With **no AVC** in the audit log, that is `StrictModes`, not SELinux: the
key file, `~/.ssh`, or the home directory is group- or world-writable, or
owned by the wrong account. Fix the modes and stop reading.

**2. The audit log decides which SELinux case it is.**

```bash
ausearch --input /var/log/audit/audit.log -m avc -ts recent | grep sshd
```

Always pass `--input`. Bare `ausearch -m avc` reads only the current log
and answers `<no matches>` on a host whose audit log has rotated, while
the AVCs sit in the file it just skipped.

| `tcontext` | What it means |
|---|---|
| `nfs_t` | NFS home — go to step 4 |
| `default_t`, `tmp_t`, `var_t`, `admin_home_t`, `unlabeled_t`, `httpd_sys_content_t` | Local file with the wrong label, usually created elsewhere and moved in, or restored from a backup that carried no labels — go to step 3 |
| `user_home_t`, `user_tmp_t` | **Not** the problem. `sshd_t` reads both on EL9 targeted policy; keep looking |
| no AVC at all | Not SELinux — back to step 1 |

**3. Local mislabel: confirm, relabel, done.**

```bash
matchpathcon -V ~youruser/.ssh/authorized_keys
restorecon -Rv ~youruser/.ssh
```

Nothing in this tool is involved in that case.

**4. NFS home: `restorecon` is not a fix here.**

Run label checks **as the user**, not with `sudo`. Under `root_squash`
root becomes `nobody`, cannot traverse a `0700 ~/.ssh`, and fails with a
plain `Permission denied` before SELinux is ever consulted — which looks
like a third problem and is not one.

On an NFS mount:

- `restorecon` **exits 0 and changes nothing.** A silent no-op, and the
  most common false trail in this whole area.
- `chcon` fails outright with `Operation not supported`.
- Relabelling the file on the **server** does not help either: the client
  assigns `nfs_t` through `genfscon` regardless of the backing file.

Two real options, and you want exactly one of them.

**Option A — the boolean, if you own SELinux policy on that host.**

```bash
getsebool use_nfs_home_dirs
setsebool -P use_nfs_home_dirs on
```

Host-wide: it lets `sshd_t` read every NFS home rather than the one file
you need, and configuration management may revert it on its next run.
**This tool never sets an SELinux boolean** — that is the host owner's
decision, not a side effect of staging an editor.

**Option B — a central key directory, when you do not have that
authority.** Preferred: no SELinux authority needed, and nothing outside
this one user changes.

**Do not do both.** The boolean makes the home copy readable again,
which masks a central-dir install that is not actually working — you find
out the day someone turns the boolean off.

```bash
sudo ./bin/vscode-airgap.sh --install-authorized-key ~/.ssh/id_ed25519.pub --user youruser
sudo ./bin/vscode-airgap.sh --emit-ssh-config --central-keys --user youruser \
  --install-dir ~/vscode-templates
sudo cp ~/vscode-templates/50-vscode-youruser.conf /etc/ssh/sshd_config.d/
sudo sshd -t && sudo systemctl reload sshd
sudo sshd -T -C user=youruser | grep -i authorizedkeysfile
# authorizedkeysfile /etc/ssh/authorized_keys/%u .ssh/authorized_keys
sudo sshd -T -C user=someone-else | grep -i authorizedkeysfile
# authorizedkeysfile .ssh/authorized_keys        <- untouched
```

The key lands at `/etc/ssh/authorized_keys/youruser`, `0644 root:root`,
in a `0755 root:root` directory on local disk — `etc_t`, which `sshd_t`
may always read. The drop-in names that path **first** and
`.ssh/authorized_keys` second, inside `Match User youruser` as always.

Three details that are deliberate:

- **Central first, not second.** Every login that consults an unreadable
  NFS path writes three denied lines to `/var/log/secure` and three AVCs
  before falling through, and a hung hard NFS mount named first would
  stall authentication itself.
- **The home path stays second**, so the same file is still correct on a
  host with local homes — nothing to undo if the user or the mount moves.
- **`StrictModes` decides what sshd will accept**: the key file must be
  owned by root or by that user and must not be group- or world-writable.
  `0644 root:root` is the tight choice. `--install-authorized-key`
  refuses a directory or key file that is out of shape and tells you what
  is wrong rather than chowning a path somebody else set up.

`AuthorizedKeysCommand` (FreeIPA's `sss_ssh_authorizedkeys`) is a
separate mechanism and is untouched. Without `--central-keys` the
emitted drop-in contains no `AuthorizedKeysFile` line at all, so a host
that resolves keys through the realm keeps doing exactly that.

## When home is all you get

Plenty of hosts hand a user a home directory and nothing else. That path
is supported end to end — `--install-dir` defaults to `~/.vscode-server`,
and `--link-home` is unnecessary because Remote-SSH already looks there.
`--install-fapolicyd` writes the allow rule for that home tree and warns
while it does it, rather than refusing:

```
WARN:  this rule allow-lists a home directory: /home/youruser/.vscode-server
WARN:    everything under it becomes executable for that user, including
WARN:    anything they drop in it later, and each extra user needs their own rule
WARN:    prefer --install-dir /opt/vscode-server --link-home --user NAME
WARN:    if this host lets you write to a shared path
```

The emitted `fapolicyd-vscode.rules` carries the same tradeoff as
comments above the rule, so it travels with the file an admin installs.
The honest summary: a home rule stops fapolicyd checking the trust db
anywhere under that directory for that user, including files they add
later, and the rule count grows with the team. `/opt/vscode-server` is
preferable where a host allows it — one rule, one admin-controlled tree,
every user covered — but it is a preference, not a prerequisite.

## Docs

- [`docs/runbooks/remote-ssh-realm-otp.md`](docs/runbooks/remote-ssh-realm-otp.md)
  — the primary path: `ssh_config` + JSONC VS Code `settings.json` +
  remote-host notes for realm/GSSAPI + OTP auth through port 22 only.
  Settings include `useLocalServer`, `useExecServer: false`,
  `localServerDownload: "off"`, `remoteServerListenOnSocket: false`,
  and the native Windows `ssh.exe` path. Comments are `//` lines, not
  fake `"// key"` JSON pairs.
- [`docs/runbooks/online.md`](docs/runbooks/online.md) /
  [`airgap.md`](docs/runbooks/airgap.md) — build-side and install-side
  walkthroughs.
- [`docs/reference/download-urls.md`](docs/reference/download-urls.md) —
  every Microsoft/Marketplace endpoint this uses, verified live, plus a
  field-name gotcha that silently produced a wrong filename until caught,
  the corrected record on checksum availability, and how `--version`
  resolves semver to a commit via `microsoft/vscode`'s own git tags
  (Microsoft's APIs don't expose that map — checked four candidates
  live, including one that hangs server-side, before finding the one
  that actually works).
- [`docs/designs/vscode-airgap-tunnels.md`](docs/designs/vscode-airgap-tunnels.md)
  — why Remote-SSH is primary (v2) and `serve-web` isn't (was primary in
  v1 — operator feedback corrected that), alternatives considered.
- [`contrib/`](contrib/) — the exact `ssh-config.example`,
  `settings.json.example` (JSONC), and per-user sshd drop-in
  (`remote-host.example`, emitted as `50-vscode-<user>.conf`)
  `--emit-ssh-config` writes, kept in the repo for browsing without
  running the script.

## Full option reference

```
./bin/vscode-airgap.sh --help
```

## Tested

Built and tested end-to-end in Linux containers (`docker run
--network none` for the offline path — genuinely no route to the
internet) on linux/arm64, plus a live Windows-client / Linux-host
reconnect with inbound TCP/22 only. Live-verified: both Remote-SSH
layouts extract where the client looks
(`~/.vscode-server/bin/<commit>/` *and* `code-<commit>` +
`cli/servers/Stable-<commit>/server/`, `product.json` commit matches,
`bin/code-server` executable); Microsoft-published sha256 checksums
resolve correctly for every artifact family; extension engine-matching
picks the newest compatible version and rejects garbage IDs loudly;
`--status`/`--emit-ssh-config` work standalone with zero network;
`--version` resolves a real historical semver (e.g. `1.96.2`) to its
commit and downloads it end to end, a 2-component version (`1.33`)
resolves to its newest matching patch tag then loudly fails the CDN
check rather than silently substituting latest (`1.33.x` is below the
current `1.34.0` floor), rejects an unknown version outright, and
correctly loses to `--commit` when both are set (including in the
output filename — see lessons below); `--list-versions` works
standalone (text/json, live or from a bundle) and fails fast with no
network rather than hanging.
Several real bugs were found and fixed by actually running it rather
than by lint, including a JSON field-name mixup, an architecture-mismatch
bug that only showed up when `--serve-web` tried to exec a binary built
for the wrong CPU, and a stale `--version` string leaking into a filename
even after `--commit` had already "won."
