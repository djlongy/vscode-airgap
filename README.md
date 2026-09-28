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
