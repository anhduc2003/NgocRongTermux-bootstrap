# NgocRong Termux Bootstrap

This repository contains only a public bootstrap script and public runtime patch assets. It does not contain private source code, SQL dumps, credentials, or account data. The private repository is accessed only after GitHub authentication when a full setup is required.

## One-command setup or start

For a new Termux installation, or whenever the server runtime may be incomplete, paste **this command only** into Termux:

```bash
curl -fsSL https://raw.githubusercontent.com/anhduc2003/NgocRongTermux-bootstrap/main/bootstrap.sh | bash -s -- --setup-or-start
```

The command checks `~/nro-server/cc2.jar`, `Config.properties`, and non-empty `data/`. If any required runtime asset is missing, it authenticates GitHub when necessary, resumes the existing download workflow, runs the full private installer, preserves an existing non-empty `ngocrong` database by the installer's import guard, then synchronizes the public launcher and DragonBoy250 patches before starting the game server and panel. If the runtime is complete, it skips the full setup and starts the existing server directly.

The first full setup can take time because the private runtime archive may be large. If Termux asks for GitHub authorization, complete the normal browser-based authorization flow; do not enter a GitHub password into a script or command.

## Important: do not use start-only for first setup

`--start-only` is an advanced, deliberately fail-closed mode. It only starts an already-installed runtime and does **not** download or reconstruct missing `cc2.jar`, `Config.properties`, or `data/`. Therefore, it is expected to stop with a “runtime chưa được cài hoàn chỉnh” message when those files are absent.

For normal use, always use `--setup-or-start` above. The full setup keeps the database schema name `ngocrong`; it does not perform a destructive SQL import when that database already contains tables. As part of a full setup, the runtime project directory may be rebuilt when required, while the established database is protected by the installer's import guard.
