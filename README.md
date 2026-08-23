# NgocRong Termux Bootstrap

This repository contains only a public bootstrap script. It installs GitHub CLI, authenticates the user once through the browser, clones the private `anhduc2003/NgocRong-Termux` repository, and runs its Termux server installer. It does not contain source code, SQL, credentials, or account data.

Run in Termux:

```bash
pkg update -y && pkg install -y curl && curl -fsSL https://raw.githubusercontent.com/anhduc2003/NgocRongTermux-bootstrap/main/bootstrap.sh | bash
```
