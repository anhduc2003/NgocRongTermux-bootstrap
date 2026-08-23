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

run_start_only_launcher() {
  local launcher="$1" launcher_log launcher_rc required_path
  mkdir -p "$PROJECT/logs"
  launcher_log="$PROJECT/logs/bootstrap-launcher.log"
  printf '%s\n' '[StartOnly] Bắt đầu gọi launcher server.'
  set +e
  trap - ERR
  env NRO_PROJECT_DIR="$PROJECT" bash "$launcher" 2>&1 | tee "$launcher_log"
  launcher_rc=${PIPESTATUS[0]}
  trap on_error ERR
  set -e
  if [ "$launcher_rc" -ne 0 ]; then
    printf '\n[ERROR] Launcher trả về mã %s.\n' "$launcher_rc" >&2
    printf '[ERROR] Kiểm tra tự động:\n' >&2
    for required_path in "$PROJECT/cc2.jar" "$PROJECT/Config.properties" "$PROJECT/data" "$PROJECT/logs"; do
      if [ -e "$required_path" ]; then
        printf '  OK: %s\n' "$required_path" >&2
      else
        printf '  THIẾU: %s\n' "$required_path" >&2
      fi
    done
    printf '[ERROR] Log launcher: %s\n' "$launcher_log" >&2
    tail -100 "$launcher_log" >&2 || true
    return "$launcher_rc"
  fi
  return 0
}

prepare_local_jdbc_assets() {
  local target source_url
  mkdir -p "$PROJECT/termux/lib"
  for asset in compat-mysql-driver.jar mysql-connector-j-8.4.0.jar; do
    target="$PROJECT/termux/lib/$asset"
    [ -s "$target" ] && continue
    if [ -s "$CHECKOUT/termux/lib/$asset" ]; then
      cp -f "$CHECKOUT/termux/lib/$asset" "$target"
      continue
    fi
    source_url="${NRO_PUBLIC_PAYLOAD_BASE:-https://raw.githubusercontent.com/anhduc2003/NgocRongTermux-bootstrap/main/start-only}/$asset"
    printf '[StartOnly] Đang bổ sung JAR JDBC: %s\n' "$asset"
    curl -fsSL "$source_url" -o "$target" || return 1
    [ -s "$target" ] || return 1
  done
}

prepare_local_protocol_assets() {
  local target source_url asset
  local assets=(
    nro/models/network/KeyHandler.class
    nro/models/network/Collector.class
    nro/models/network/MessageSendCollect.class
    nro/models/network/ClientVerifier.class
    nro/models/services/Service.class
    nro/models/data/DataGame.class
    nro/models/server/Controller.class
  )
  for asset in "${assets[@]}"; do
    target="$PROJECT/termux/runtime-patches/$asset"
    mkdir -p "$(dirname "$target")"
    if [ -s "$CHECKOUT/termux/runtime-patches/$asset" ]; then
      cp -f "$CHECKOUT/termux/runtime-patches/$asset" "$target"
      continue
    fi
    source_url="${NRO_PUBLIC_PAYLOAD_BASE:-https://raw.githubusercontent.com/anhduc2003/NgocRongTermux-bootstrap/main/start-only}/runtime-patches/$asset"
    printf '[StartOnly] Đang bổ sung patch DragonBoy250: %s\n' "$asset"
    curl -fsSL "$source_url" -o "$target" || return 1
    [ -s "$target" ] || return 1
  done
}

prepare_local_panel_scripts() {
  local target source_url asset
  for asset in start-panel.sh stop-panel.sh; do
    target="$PROJECT/termux/$asset"
    if [ -s "$CHECKOUT/start-only/$asset" ]; then
      cp -f "$CHECKOUT/start-only/$asset" "$target"
    else
      source_url="${NRO_PUBLIC_PAYLOAD_BASE:-https://raw.githubusercontent.com/anhduc2003/NgocRongTermux-bootstrap/main/start-only}/$asset"
      printf '[StartOnly] Đang bổ sung launcher web panel: %s\n' "$asset"
      curl -fsSL "$source_url" -o "$target" || return 1
    fi
    [ -s "$target" ] || return 1
    chmod +x "$target"
  done
}

prepare_private_panel_source() {
  [ -d "$PROJECT/panel" ] && return 0
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status --hostname github.com >/dev/null 2>&1; then
    printf '%s\n' '[StartOnly] Không có quyền GitHub private; giữ nguyên game server và bỏ qua panel.' >&2
    return 0
  fi
  local cache="${HOME}/.cache/ngocrong-panel-source"
  mkdir -p "$(dirname "$cache")"
  if [ ! -d "$cache/.git" ]; then
    rm -rf "$cache"
    printf '%s\n' '[StartOnly] Đang lấy riêng thư mục panel từ repository private (sparse checkout).'
    gh repo clone "$REPO" "$cache" -- --depth=1 --filter=blob:none --sparse \
      || { printf '%s\n' '[StartOnly] Không lấy được panel private; bỏ qua panel.' >&2; return 0; }
    git -C "$cache" sparse-checkout set panel \
      || { printf '%s\n' '[StartOnly] Không chuẩn bị được panel private; bỏ qua panel.' >&2; return 0; }
  else
    git -C "$cache" pull --ff-only --quiet || true
    git -C "$cache" sparse-checkout set panel || true
  fi
  [ -d "$cache/panel" ] || return 0
  cp -a "$cache/panel" "$PROJECT/panel"
  rm -f "$PROJECT/panel/api/.env" "$PROJECT/panel/web/.env"
  rm -rf "$PROJECT/panel/api/node_modules" "$PROJECT/panel/web/node_modules"
  printf '%s\n' '[StartOnly] Đã bổ sung panel private mà không thay đổi runtime game/database.'
}

refresh_local_launcher() {
  local launcher_url temp_launcher
  launcher_url="${NRO_PUBLIC_LAUNCHER_URL:-https://raw.githubusercontent.com/anhduc2003/NgocRongTermux-bootstrap/main/start-only/start-existing-server.sh}"
  temp_launcher="$PROJECT/termux/start-existing-server.sh.download"
  if curl -fsSL "$launcher_url" -o "$temp_launcher" \
     && [ -s "$temp_launcher" ] \
     && grep -q 'ServerManager' "$temp_launcher" 2>/dev/null; then
    mv -f "$temp_launcher" "$PROJECT/termux/start-existing-server.sh"
    chmod +x "$PROJECT/termux/start-existing-server.sh"
    printf '%s\n' '[StartOnly] Đã đồng bộ launcher mới từ GitHub.'
    return 0
  fi
  rm -f "$temp_launcher"
  printf '%s\n' '[StartOnly] Không đồng bộ được launcher mới; sẽ thử launcher cục bộ hiện có.' >&2
  return 1
}

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
   && [ -s "$PROJECT/termux/start-existing-server.sh" ] \
   && grep -q 'ServerManager' "$PROJECT/termux/start-existing-server.sh" 2>/dev/null; then
  chmod +x "$PROJECT/termux/start-existing-server.sh"
  printf '%s\n' '[StartOnly] Đã tìm thấy launcher cục bộ hợp lệ.'
  refresh_local_launcher || true
  prepare_private_panel_source
  if ! prepare_local_jdbc_assets || ! prepare_local_protocol_assets || ! prepare_local_panel_scripts; then
    fail "Không bổ sung được asset JDBC/protocol/panel cho launcher cục bộ."
  fi
  if ! run_start_only_launcher "$PROJECT/termux/start-existing-server.sh"; then
    fail "Launcher start-only thất bại; nguyên nhân đã được in ở trên."
  fi
  exit 0
fi
if { [ "$MODE" = "--start-only" ] || [ "$MODE" = "--start" ]; } \
   && [ -e "$PROJECT/termux/start-existing-server.sh" ]; then
  printf '%s\n' '[StartOnly] Launcher cục bộ không hợp lệ; sẽ tải lại payload start-only.'
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
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/mysql-connector-j-8.4.0.jar" -o "$PROJECT/termux/lib/mysql-connector-j-8.4.0.jar" \
     && mkdir -p "$PROJECT/termux/runtime-patches" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/runtime-patches/nro/models/network/KeyHandler.class" -o "$PROJECT/termux/runtime-patches/nro/models/network/KeyHandler.class" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/runtime-patches/nro/models/network/Collector.class" -o "$PROJECT/termux/runtime-patches/nro/models/network/Collector.class" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/runtime-patches/nro/models/network/MessageSendCollect.class" -o "$PROJECT/termux/runtime-patches/nro/models/network/MessageSendCollect.class" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/runtime-patches/nro/models/network/ClientVerifier.class" -o "$PROJECT/termux/runtime-patches/nro/models/network/ClientVerifier.class" \
     && mkdir -p "$PROJECT/termux/runtime-patches/nro/models/services" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/runtime-patches/nro/models/services/Service.class" -o "$PROJECT/termux/runtime-patches/nro/models/services/Service.class" \
     && mkdir -p "$PROJECT/termux/runtime-patches/nro/models/data" "$PROJECT/termux/runtime-patches/nro/models/server" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/runtime-patches/nro/models/data/DataGame.class" -o "$PROJECT/termux/runtime-patches/nro/models/data/DataGame.class" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/runtime-patches/nro/models/server/Controller.class" -o "$PROJECT/termux/runtime-patches/nro/models/server/Controller.class" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/start-panel.sh" -o "$PROJECT/termux/start-panel.sh" \
     && curl -fsSL "$PUBLIC_PAYLOAD_BASE/stop-panel.sh" -o "$PROJECT/termux/stop-panel.sh"; then
    chmod +x "$PROJECT/termux/start-existing-server.sh"
    printf '%s\n' '[StartOnly] Đã tải payload.'
    if ! run_start_only_launcher "$PROJECT/termux/start-existing-server.sh"; then
      fail "Launcher start-only thất bại; nguyên nhân đã được in ở trên."
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
  prepare_private_panel_source
  if ! prepare_local_protocol_assets; then
    fail "Không bổ sung được patch protocol DragonBoy250 từ repository."
  fi
  if [ -d "$CHECKOUT/panel" ] && [ ! -d "$PROJECT/panel" ]; then
    cp -a "$CHECKOUT/panel" "$PROJECT/panel"
    rm -f "$PROJECT/panel/api/.env" "$PROJECT/panel/web/.env"
    rm -rf "$PROJECT/panel/api/node_modules" "$PROJECT/panel/web/node_modules"
  fi
  chmod +x "$PROJECT/termux/start-existing-server.sh"
  if ! run_start_only_launcher "$PROJECT/termux/start-existing-server.sh"; then
    fail "Launcher start-only thất bại; nguyên nhân đã được in ở trên."
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
