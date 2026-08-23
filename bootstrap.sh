#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

REPO="${GH_REPO:-anhduc2003/NgocRong-Termux}"
CHECKOUT="${HOME}/ngocrong-github"
PROJECT="${HOME}/nro-server"

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

command -v pkg >/dev/null 2>&1 || fail "Hãy chạy lệnh này trong Termux."
pkg update -y
pkg install -y gh git

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  printf '\nGitHub cần xác thực một lần bằng trình duyệt. Không nhập mật khẩu vào Git.\n'
  gh auth login --hostname github.com --git-protocol https --web
  gh auth status --hostname github.com >/dev/null 2>&1 || fail "GitHub chưa xác thực thành công."
fi

if [ -d "$CHECKOUT/.git" ]; then
  git -C "$CHECKOUT" pull --ff-only
else
  rm -rf "$CHECKOUT"
  gh repo clone "$REPO" "$CHECKOUT"
fi

[ -f "$CHECKOUT/termux/ngocrong-oneclick.sh" ] || fail "Repository chưa có installer server."
chmod +x "$CHECKOUT/termux/ngocrong-oneclick.sh"
NRO_PROJECT_DIR="$PROJECT" bash "$CHECKOUT/termux/ngocrong-oneclick.sh"
