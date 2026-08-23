#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

REPO="${GH_REPO:-anhduc2003/NgocRong-Termux}"
CHECKOUT="${HOME}/ngocrong-github"
PROJECT="${HOME}/nro-server"

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

command -v pkg >/dev/null 2>&1 || fail "Hãy chạy lệnh này trong Termux."
pkg update -y
pkg install -y gh git curl coreutils aria2

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  printf '\nGitHub cần xác thực một lần bằng trình duyệt. Không nhập mật khẩu vào Git.\n'
  gh auth login --hostname github.com --git-protocol https --web
  gh auth status --hostname github.com >/dev/null 2>&1 || fail "GitHub chưa xác thực thành công."
fi

# gh can know the token while plain git still lacks its credential helper.
# Configure that bridge explicitly, then make any auth failure fail instead
# of opening the confusing `Username for https://github.com` prompt.
gh auth setup-git --hostname github.com >/dev/null
gh api "/repos/$REPO" >/dev/null 2>&1 || fail "Tài khoản GitHub hiện tại không có quyền đọc repository riêng tư $REPO. Hãy đăng nhập đúng tài khoản bằng gh auth login."
export GIT_TERMINAL_PROMPT=0

if [ -d "$CHECKOUT/.git" ]; then
  git -C "$CHECKOUT" pull --ff-only || fail "Không thể pull repository $REPO. Phiên GitHub chưa cấp quyền cho Git hoặc mạng bị ngắt."
else
  rm -rf "$CHECKOUT"
  gh repo clone "$REPO" "$CHECKOUT" || fail "Không thể clone repository $REPO. Phiên GitHub chưa cấp quyền hoặc repository không tồn tại."
fi

MODE="${1:-install}"
[ -f "$CHECKOUT/termux/ngocrong-oneclick.sh" ] || fail "Repository chưa có installer server."
[ -f "$CHECKOUT/termux/download-watchdog.sh" ] || fail "Repository chưa có download watchdog."
[ -f "$CHECKOUT/termux/auto-install-server.sh" ] || fail "Repository chưa có supervisor auto-install."
chmod +x "$CHECKOUT/termux/ngocrong-oneclick.sh" "$CHECKOUT/termux/download-watchdog.sh" "$CHECKOUT/termux/auto-install-server.sh"
# Never let an old watchdog or supervisor compete with the server commands.
bash "$CHECKOUT/termux/download-watchdog.sh" --stop >/dev/null 2>&1 || true
bash "$CHECKOUT/termux/auto-install-server.sh" --stop >/dev/null 2>&1 || true

if [ "$MODE" = "--start-only" ] || [ "$MODE" = "--start" ]; then
  [ -f "$CHECKOUT/termux/start-existing-server.sh" ] || fail "Repository chưa có launcher start-only."
  chmod +x "$CHECKOUT/termux/start-existing-server.sh"
  NRO_PROJECT_DIR="$PROJECT" bash "$CHECKOUT/termux/start-existing-server.sh"
  exit 0
fi

if [ "$MODE" = "--background" ]; then
  bash "$CHECKOUT/termux/auto-install-server.sh" --daemon
  printf '%s\n' 'Auto-install đang chạy nền; tải xong sẽ tự import database và khởi động game server.'
  exit 0
fi

[ "$MODE" = "--watch-download" ] || [ "$MODE" = "--install" ] || [ "$MODE" = "install" ] || fail "Dùng --install để cài/chạy server hoặc --background để chạy tự động nền."
# Foreground by default: the command does not return until download, database,
# Java startup and port health check have all completed.
NRO_PROJECT_DIR="$PROJECT" bash "$CHECKOUT/termux/auto-install-server.sh" --worker
