## What this is

`bin/vscode-airgap.sh` builds a VS Code Remote-SSH bundle on a connected machine and
installs it on an air-gapped Linux host in `/opt/vscode-server`. It links each user's
`~/.vscode-server` to that shared tree. It does not change sshd or the client for you.

## How to use it

1. On a connected machine, set the release: `VSCODE_VER=1.139.1`
2. Build the bundle: `sudo ./bin/vscode-airgap.sh --mode bundle --version $VSCODE_VER`
3. Copy `vscode-bundle-v1.139.1.tar.gz` and `bin/vscode-airgap.sh` to the air-gapped host.
4. Install the script: `sudo install -m 0755 vscode-airgap.sh /usr/local/bin/`
5. First install, naming the users:
   `sudo /usr/local/bin/vscode-airgap.sh --mode offline --bundle-path vscode-bundle-v$VSCODE_VER.tar.gz --link-home --user alice,bob`
6. Every later update, one command for everyone:
   `sudo /usr/local/bin/vscode-airgap.sh --mode offline --bundle-path vscode-bundle-v$VSCODE_VER.tar.gz --all-users`
7. Onboard a new user: `sudo /usr/local/bin/vscode-airgap.sh --link-home --user carol`

You know it works when `sudo -u alice /home/alice/.vscode-server/bin/*/bin/code-server --version` prints `1.139.1`.

If it fails:
- `sudo: vscode-airgap.sh: command not found`: call it by full path, `/usr/local/bin/vscode-airgap.sh`.
- `Permission denied` on a fapolicyd host: `sudo bash /usr/local/bin/vscode-airgap.sh ...`
