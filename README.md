# NgocRong Termux Bootstrap

This repository contains only a public bootstrap script and public runtime patch assets. It does not contain private source code, SQL dumps, credentials, or account data. The private repository is accessed only after GitHub authentication when a full setup is required.

## One-command setup or start

Paste this command into Termux:

```bash
curl -fsSL https://raw.githubusercontent.com/anhduc2003/NgocRongTermux-bootstrap/main/bootstrap.sh | bash -s -- --setup-or-start
```

The command checks `~/nro-server/cc2.jar`, `Config.properties`, and non-empty `data/`. If any required runtime asset is missing, it authenticates GitHub when necessary, resumes the existing download workflow, runs the full private installer, preserves an existing non-empty `ngocrong` database by the installer's import guard, then synchronizes the public launcher and DragonBoy250 patches before starting the game server and panel. If the runtime is complete, it skips the full setup and starts the existing server directly.

## Start-only mode

Use this mode when you intentionally want no full setup or archive extraction:

```bash
curl -fsSL https://raw.githubusercontent.com/anhduc2003/NgocRongTermux-bootstrap/main/bootstrap.sh | bash -s -- --start-only
```

Start-only remains fail-closed when `cc2.jar`, `Config.properties`, or `data/` is missing. It never imports SQL, deletes the `ngocrong` database, or downloads the private source archive.
