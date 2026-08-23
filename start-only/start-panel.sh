#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL="$ROOT/panel"
LOG_DIR="$ROOT/logs"
API_DIR="$PANEL/api"
WEB_DIR="$PANEL/web"
API_PID_FILE="$LOG_DIR/panel-api.pid"
WEB_PID_FILE="$LOG_DIR/panel-web.pid"
API_LOG="$LOG_DIR/panel-api.log"
WEB_LOG="$LOG_DIR/panel-web.log"
API_URL="http://127.0.0.1:${NRO_PANEL_API_PORT:-3001}"
WEB_URL="http://127.0.0.1:${NRO_PANEL_WEB_PORT:-5173}"
LOCK_DIR="$ROOT/.panel-start.lock"

say() { printf '[Panel] %s\n' "$*"; }
fail() { printf '[Panel][ERROR] %s\n' "$*" >&2; exit 1; }

[ -d "$API_DIR" ] && [ -f "$API_DIR/package.json" ] || {
  say "Không tìm thấy panel trong $PANEL; game server vẫn hoạt động bình thường."
  exit 0
}
ensure_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    return 0
  fi
  command -v pkg >/dev/null 2>&1 || fail "Thiếu Node.js/npm và không tìm thấy package manager Termux."
  say "Termux chưa có Node.js; đang tự cài nodejs-lts..."
  pkg install -y nodejs-lts >/dev/null 2>&1 || pkg install -y nodejs >/dev/null 2>&1 \
    || fail "Không cài được Node.js bằng pkg."
  command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 \
    || fail "Đã cài package nhưng chưa tìm thấy node/npm."
}
ensure_node
command -v curl >/dev/null 2>&1 || fail "Thiếu curl trong Termux."
mkdir -p "$LOG_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -s "$LOCK_DIR/pid" ] && kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
    say "Một tiến trình start-panel khác đang chạy; bỏ qua lần gọi trùng."
    exit 0
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

install_deps() {
  local dir="$1"
  local marker="$dir/node_modules/.nro-deps-ready"
  local ready=1
  if [ ! -f "$marker" ] || [ ! -d "$dir/node_modules" ]; then
    ready=0
  elif [ "$(basename "$dir")" = "api" ] && [ ! -s "$dir/node_modules/mysql2/lib/constants/charset_encodings.js" ]; then
    ready=0
  elif [ "$(basename "$dir")" = "web" ] && [ ! -s "$dir/node_modules/vite/bin/vite.js" ]; then
    ready=0
  fi
  [ "$ready" -eq 1 ] && return 0
  say "Cài/sửa dependency panel tại $(basename "$dir")..."
  rm -rf "$dir/node_modules"
  (cd "$dir" && npm ci --no-audit --no-fund)
  touch "$marker"
}

pid_running() {
  local file="$1"
  [ -s "$file" ] && kill -0 "$(cat "$file" 2>/dev/null)" 2>/dev/null
}

install_deps "$API_DIR"

sync_panel_config() {
  say "Đồng bộ schema và cấu hình panel từ Config.properties..."
  local attempt
  for attempt in 1 2 3; do
    if (cd "$API_DIR" && npm run db:sync); then
      return 0
    fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  return 1
}

if ! sync_panel_config; then
  if [ -f "$API_DIR/.env" ]; then
    say "Cảnh báo: db-sync chưa thành công; tiếp tục dùng cấu hình panel hiện có."
  else
    fail "Không khởi tạo được cấu hình panel và chưa có .env dự phòng."
  fi
fi
if ! pid_running "$API_PID_FILE"; then
  rm -f "$API_PID_FILE"
  say "Khởi động Panel API tại $API_URL..."
  (
    cd "$API_DIR"
    HOST=127.0.0.1 PORT="${NRO_PANEL_API_PORT:-3001}" nohup npm start >>"$API_LOG" 2>&1 &
    echo $! >"$API_PID_FILE"
  )
fi

api_ready=0
for _ in $(seq 1 30); do
  if ! pid_running "$API_PID_FILE"; then break; fi
  if curl -fsS --max-time 2 "$API_URL/api/v1/system/health" >/dev/null 2>&1; then api_ready=1; break; fi
  sleep 1
done
[ "$api_ready" -eq 1 ] || { tail -80 "$API_LOG" >&2 || true; fail "Panel API chưa sẵn sàng."; }

if [ -d "$WEB_DIR" ] && [ -f "$WEB_DIR/package.json" ]; then
  install_deps "$WEB_DIR"
  if ! pid_running "$WEB_PID_FILE"; then
    rm -f "$WEB_PID_FILE"
    say "Khởi động Panel Web tại $WEB_URL..."
    (
      cd "$WEB_DIR"
      nohup node node_modules/vite/bin/vite.js --host 127.0.0.1 --port "${NRO_PANEL_WEB_PORT:-5173}" >>"$WEB_LOG" 2>&1 &
      echo $! >"$WEB_PID_FILE"
    )
  fi
  web_ready=0
  for _ in $(seq 1 30); do
    if ! pid_running "$WEB_PID_FILE"; then break; fi
    if curl -fsS --max-time 2 "$WEB_URL/" >/dev/null 2>&1; then web_ready=1; break; fi
    sleep 1
  done
  [ "$web_ready" -eq 1 ] || { tail -80 "$WEB_LOG" >&2 || true; fail "Panel Web chưa sẵn sàng."; }
else
  say "Thiếu frontend panel; API vẫn đang hoạt động."
fi

say "Panel đã hoạt động: $WEB_URL"
say "API nội bộ: $API_URL"
say "Log API: $API_LOG"
say "Log Web: $WEB_LOG"
