# vscode-airgap

## TL;DR

Pre-installs the VS Code Remote-SSH server on an air-gapped Linux host so the client never downloads it.
Steps for a first run: [QUICKSTART.md](QUICKSTART.md).

## Requirements

- Air-gapped host: bash, tar, sha256sum, root through sudo. Linux x64 or arm64 (`--arch`).
- Online side: curl, python3, and git for `--version`.
- Script installed at `/usr/local/bin/vscode-airgap.sh`. EL sudo drops `/usr/local/bin`
  from `PATH`, so call it by full path.

## Flags

Full set: `vscode-airgap.sh --help`.

| Req | Name | Default | Purpose |
|---|---|---|---|
| **Required** | `--mode` | none | `bundle` online, `offline` on the air-gapped host, `online` for a host with internet |
| Optional | `--version` | latest stable | VS Code release to stage, e.g. `1.139.1` |
| When offline | `--bundle-path` | `vscode-bundle-v<version>.tar.gz` in bundle mode | Bundle to write or read |
| Optional | `--install-dir` | `/opt/vscode-server` as root | Shared server tree |
| Optional | `--link-home` | off | Links `~/.vscode-server` presence tests to the install dir |
| Optional | `--user` | `$SUDO_USER` | Comma list of accounts to link or emit for |
| Optional | `--all-users` | off | Links every account that already has a `~/.vscode-server` |
| When fapolicyd | `--install-fapolicyd` | off | Writes and loads an allow rule for the install dir |

## Usage

```sh
VSA=/usr/local/bin/vscode-airgap.sh
VSCODE_VER=1.139.1

# Online side
sudo $VSA --mode bundle --version $VSCODE_VER

# Air-gapped host, every update
sudo $VSA --mode offline --bundle-path vscode-bundle-v$VSCODE_VER.tar.gz --all-users
```

## Browser online side

`docs/index.html` does the online side in a browser, for a Windows host that cannot run
PowerShell. Live at <https://djlongy.github.io/vscode-airgap/>, or open the file locally.

1. Pick the version and remote arch.
2. Paste extension IDs, or drop `extensions.txt` on the page.
3. Click Download all. It saves the four VS Code files and `vscode-extras-v<version>.tar`,
   which holds `versions.json` with Microsoft's sha256 values and the engine-matched
   `.vsix` files.
4. Copy all five files into one folder on the air-gapped host and install from it:

```sh
sudo /usr/local/bin/vscode-airgap.sh --mode offline --bundle-path /path/to/folder --all-users
```

`--bundle-path` with a folder finds each binary by sha256, so browser file names do not
matter, then installs as from a bundle. The page links the binaries because Microsoft's
binary CDN sends no CORS header, so page scripts cannot fetch them. The update API,
Marketplace and `.vsix` CDN allow it.

For deployment scripts (MECM, SCCM, Intune), the page lists Microsoft's pinned-version
URLs, such as `https://update.code.visualstudio.com/<version>/win32-x64/stable`. Each
redirects to that exact release. Pages is static, so the page cannot answer scripts
itself.

## Windows online side

`bin/vscode-airgap.ps1` builds the same bundle on Windows 10 1803 or later (PowerShell 5.1
and the built-in `tar.exe`). `-Mode install` copies a bundle or a browser-page folder to
each host over ssh and installs it there, so nothing is copied by hand. It needs the
built-in OpenSSH client (Windows 10 1809 or later) and sudo on the host. Full help:
`Get-Help .\vscode-airgap.ps1 -Detailed`.

```powershell
.\vscode-airgap.ps1 -Mode bundle
.\vscode-airgap.ps1 -Mode bundle -Version 1.143.0 -BundlePath C:\bundles\vscode-bundle-v1.143.0.tar.gz
.\vscode-airgap.ps1 -Mode bundle -Version 1.143.0 -Extensions extensions.txt,ms-python.python
.\vscode-airgap.ps1 -ListVersions -Limit 5
.\vscode-airgap.ps1 -Mode install -BundlePath C:\Downloads\vscode -RemoteHost admin@host1,admin@host2
.\vscode-airgap.ps1 -Mode bundle -Version 1.143.0 -RemoteHost admin@host1
```

Each host gets two connections: `scp` for the upload, then `ssh -t` so sudo can ask for a
password. The host's `/usr/local/bin/vscode-airgap.sh` is replaced with the copy next to
the ps1, and the upload is removed afterwards. One failed host does not stop the rest,
and the run exits 1 listing the failures.

Where the execution policy blocks scripts, `bin\vscode-airgap.bat` runs the ps1 with
`-ExecutionPolicy Bypass` and takes the same arguments, from `cmd.exe` or PowerShell:

```bat
vscode-airgap.bat -Mode bundle -Version 1.143.0
```

| Name | Default | Purpose |
|---|---|---|
| `-Mode bundle` | none | Build the bundle |
| `-Mode install` | none | Copy `-BundlePath` to each `-RemoteHost` over ssh and install it |
| `-RemoteHost` | none | `user@host` list. With `-Mode bundle`, installs the new bundle |
| `-RemoteArgs` | `--all-users` | Arguments for `vscode-airgap.sh --mode offline` on the host |
| `-RemoteTemp` | `/tmp` | Upload folder on the host, removed afterwards |
| `-Version` | latest stable | Release to stage, `X.Y.Z` or `X.Y` |
| `-Commit` | none | 40-char commit, wins over `-Version` |
| `-Arch` | `linux-x64` | Remote host: `linux-x64`, `linux-arm64`, `linux-armhf`, `alpine-x64` |
| `-BundlePath` | `vscode-bundle-v<version>.tar.gz` | Bundle to write |
| `-Extensions` | none | Comma list of `publisher.name` or files with one per line |
| `-ExtensionsFile` | none | File with one `publisher.name` per line |
| `-ListVersions` | off | Stable releases with commits, newest first |
| `-Limit N` / `-All` | 10 | Rows for `-ListVersions` |
| `-Format text\|json` | text | Output for `-ListVersions` |

`HTTPS_PROXY` is honoured, otherwise the system proxy. The bundle holds the same files as
one built by `vscode-airgap.sh --mode bundle`, byte for byte, and `versions.json` differs
only in `built_at_utc`.

## Preconditions

- Each user's home exists. Nothing here creates a home.
- The client runs the same commit. Its installers are staged in `/opt/vscode-server/client-installers`.
- The client sets `remote.SSH.localServerDownload` to `off`. `--emit-ssh-config` writes it.
- On a fapolicyd host, fapolicyd is installed before `--install-fapolicyd`.

## Behaviour

- An install removes every other commit from the install dir. `--keep-old` stops that.
- `--link-home` links the installed commit only. Relink after every install, which
  `--all-users` does in the same run.
- Relinking removes links whose commit was pruned, and replaces a real file where a link belongs.
- Everything created in a home is owned by that user, including directories an earlier
  root run left root-owned. `data/` and `extensions/` are never touched.
- `--all-users` skips a home it cannot link, such as NFS with `root_squash`, and links the rest.
- `--mode offline` makes no network calls and verifies every sha256 before extracting.

## Out of scope

- sshd: `--emit-ssh-config` writes one drop-in per user for you to copy. It does not apply it.
- SELinux booleans and host hardening baselines.
- Remote Tunnels on an air-gapped host. They need Microsoft's relay.

## Expected result

- `/opt/vscode-server` holds `bin/<commit>`, `code-<commit>` and `cli/servers/Stable-<commit>`.
- Each linked user's `~/.vscode-server` holds symlinks to those paths, owned by that user.
- Verify as a linked user: `sudo -u alice /home/alice/.vscode-server/bin/*/bin/code-server --version`
  prints the version and commit.
