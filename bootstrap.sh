#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-install}"
REPO="${GH_REPO:-anhduc2003/NgocRong-Termux}"
CHECKOUT="${HOME}/ngocrong-github"
PROJECT="${HOME}/nro-server"

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
on_error() {
  local code=$?
  printf '\n[ERROR] Bootstrap dừng tại dòng %s: %s\n' "$LINENO" "$BASH_COMMAND" >&2
  exit "$code"
}
trap on_error ERR

case "$MODE" in
  --start-only|--start)
    command -v pkg >/dev/null 2>&1 || fail "Hãy chạy lệnh này trong Termux."
    missing=()
    for command_name in gh git curl aria2c; do
      command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
      printf '[StartOnly] Đang cài gói còn thiếu: %s\n' "${missing[*]}"
      pkg install -y gh git curl coreutils aria2 || fail "Không cài được các gói phụ trợ còn thiếu."
    else
      printf '%s\n' '[StartOnly] Bỏ qua pkg update/install; các gói phụ trợ đã có.'
    fi
    ;;
  --install|install|--background|--watch-download)
    command -v pkg >/dev/null 2>&1 || fail "Hãy chạy lệnh này trong Termux."
    pkg update -y || fail "pkg update thất bại."
    pkg install -y gh git curl coreutils aria2 || fail "pkg install thất bại."
    ;;
  *)
    fail "Dùng --start-only để chỉ khởi động server đã cài, hoặc --install để cài mới."
    ;;
esac

# If the launcher was already copied into the installed project, start locally
# without contacting GitHub. This is the true no-setup path.
if { [ "$MODE" = "--start-only" ] || [ "$MODE" = "--start" ]; } \
   && [ -f "$PROJECT/termux/start-existing-server.sh" ]; then
  chmod +x "$PROJECT/termux/start-existing-server.sh"
  printf '%s\n' '[StartOnly] Đã tìm thấy launcher cục bộ; bỏ qua GitHub và chạy trực tiếp.'
  exec env NRO_PROJECT_DIR="$PROJECT" bash "$PROJECT/termux/start-existing-server.sh"
fi

# Public start-only payload contains only the launcher and JDBC compatibility
# JARs; it contains no private source, SQL, accounts, or credentials. This
# fallback makes a previously installed runtime start even when gh is not
# authenticated in Termux.
if [ "$MODE" = "--start-only" ] || [ "$MODE" = "--start" ]; then
  PUBLIC_PAYLOAD_BASE="${NRO_PUBLIC_PAYLOAD_BASE:-https://raw.githubusercontent.com/anhduc2003/NgocRongTermux-bootstrap/main/start-only}"
  mkdir -p "$PROJECT/termux/lib"
  printf '%s\n' '[StartOnly] Không có launcher cục bộ; tải payload start-only công khai.'
  if curl -fsSL "$PUBLIC_PAYLOAD_BASE/start-existing-server.sh" -o "$PROJECT/termux/start-existing-server.sh" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/compat-mysql-driver.jar" -o "$PROJECT/termux/lib/compat-mysql-driver.jar" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/mysql-connector-j-8.4.0.jar" -o "$PROJECT/termux/lib/mysql-connector-j-8.4.0.jar"; then
    chmod +x "$PROJECT/termux/start-existing-server.sh"
    printf '%s\n' '[StartOnly] Đã tải payload; bắt đầu gọi launcher server.'
    if ! env NRO_PROJECT_DIR="$PROJECT" bash "$PROJECT/termux/start-existing-server.sh"; then
      fail "Launcher start-only đã thất bại; xem log trong $PROJECT/logs/."
    fi
    exit 0
  fi
  printf '%s\n' '[StartOnly] Không tải được payload công khai; chuyển sang repository private.' >&2
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  if [ "$MODE" = "--start-only" ] || [ "$MODE" = "--start" ]; then
    fail "GitHub chưa đăng nhập. Hãy đăng nhập một lần bằng: gh auth login --hostname github.com --git-protocol https --web"
  fi
  printf '%s\n' 'GitHub cần xác thực một lần bằng trình duyệt. Không nhập mật khẩu vào Git.'
  gh auth login --hostname github.com --git-protocol https --web \
    || fail "Không hoàn tất được đăng nhập GitHub."
  gh auth status --hostname github.com >/dev/null 2>&1 \
    || fail "GitHub chưa xác thực thành công."
fi

gh auth setup-git --hostname github.com \
  || fail "Không thiết lập được quyền GitHub cho Git."
gh api "/repos/$REPO" >/dev/null 2>&1 \
  || fail "Tài khoản GitHub hiện tại không có quyền đọc repository riêng tư $REPO."
export GIT_TERMINAL_PROMPT=0

if [ -d "$CHECKOUT/.git" ]; then
  printf '%s\n' '[StartOnly] Đang kiểm tra bản launcher mới trên GitHub.'
  git -C "$CHECKOUT" pull --ff-only --quiet \
    || fail "Không thể cập nhật repository $REPO."
else
  rm -rf "$CHECKOUT"
  gh repo clone "$REPO" "$CHECKOUT" \
    || fail "Không thể clone repository $REPO."
fi

if [ "$MODE" = "--start-only" ] || [ "$MODE" = "--start" ]; then
  [ -f "$CHECKOUT/termux/start-existing-server.sh" ] \
    || fail "Repository chưa có launcher start-only."
  printf '%s\n' '[StartOnly] Đã cập nhật repository; chuẩn bị launcher khởi động server.'
  mkdir -p "$PROJECT/termux/lib"
  cp -f "$CHECKOUT/termux/start-existing-server.sh" "$PROJECT/termux/start-existing-server.sh"
  if [ -f "$CHECKOUT/termux/lib/compat-mysql-driver.jar" ]; then
    cp -f "$CHECKOUT/termux/lib/compat-mysql-driver.jar" "$PROJECT/termux/lib/compat-mysql-driver.jar"
  fi
  if [ -f "$CHECKOUT/termux/lib/mysql-connector-j-8.4.0.jar" ]; then
    cp -f "$CHECKOUT/termux/lib/mysql-connector-j-8.4.0.jar" "$PROJECT/termux/lib/mysql-connector-j-8.4.0.jar"
  fi
  chmod +x "$PROJECT/termux/start-existing-server.sh"
  printf '%s\n' '[StartOnly] Bắt đầu gọi launcher server.'
  if ! env NRO_PROJECT_DIR="$PROJECT" bash "$PROJECT/termux/start-existing-server.sh"; then
    fail "Launcher start-only đã thất bại; xem log trong $PROJECT/logs/."
  fi
  exit 0
fi

[ -f "$CHECKOUT/termux/ngocrong-oneclick.sh" ] \
  || fail "Repository chưa có installer server."
[ -f "$CHECKOUT/termux/download-watchdog.sh" ] \
  || fail "Repository chưa có download watchdog."
[ -f "$CHECKOUT/termux/auto-install-server.sh" ] \
  || fail "Repository chưa có supervisor auto-install."
chmod +x "$CHECKOUT/termux/ngocrong-oneclick.sh" \
  "$CHECKOUT/termux/download-watchdog.sh" \
  "$CHECKOUT/termux/auto-install-server.sh"
bash "$CHECKOUT/termux/download-watchdog.sh" --stop >/dev/null 2>&1 || true
bash "$CHECKOUT/termux/auto-install-server.sh" --stop >/dev/null 2>&1 || true

if [ "$MODE" = "--background" ]; then
  exec bash "$CHECKOUT/termux/auto-install-server.sh" --daemon
fi

NRO_PROJECT_DIR="$PROJECT" bash "$CHECKOUT/termux/auto-install-server.sh" --worker
