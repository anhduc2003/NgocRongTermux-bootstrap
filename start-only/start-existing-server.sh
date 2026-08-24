#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${NRO_PROJECT_DIR:-$HOME/nro-server}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LOG_DIR="$PROJECT/logs"
DB_DATA="${PREFIX}/var/lib/mysql"
SOCKET="$LOG_DIR/mysqld.sock"
PID_FILE="$LOG_DIR/game-server.pid"
LOG_FILE="$LOG_DIR/game-server.log"
INPUT_FIFO="$LOG_DIR/game-input"
INPUT_PID_FILE="$LOG_DIR/game-input.pid"

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
on_error() {
  local code=$?
  printf '\n[ERROR] Launcher dừng tại dòng %s: %s (mã %s)\n' "$LINENO" "$BASH_COMMAND" "$code" >&2
  exit "$code"
}
info() { printf '[StartOnly] %s\n' "$*"; }
trap on_error ERR

info "Kiểm tra runtime: $PROJECT"
info "MariaDB data directory: $DB_DATA"
[ -d "$PROJECT" ] || fail "Chưa có $PROJECT. Hãy chạy cài đặt đầy đủ một lần."
[ -s "$PROJECT/cc2.jar" ] || fail "Thiếu $PROJECT/cc2.jar. Runtime chưa được cài hoàn chỉnh."
[ -d "$PROJECT/data" ] || fail "Thiếu $PROJECT/data. Runtime chưa được cài hoàn chỉnh."
[ -f "$PROJECT/Config.properties" ] || fail "Thiếu $PROJECT/Config.properties. Chưa hoàn tất cấu hình."
[ -d "$DB_DATA/mysql" ] || fail "Chưa có dữ liệu MariaDB tại $DB_DATA. Start-only không tự tạo hoặc import database."
command -v java >/dev/null 2>&1 || fail "Không tìm thấy Java trong Termux."
command -v mariadb-admin >/dev/null 2>&1 || fail "Không tìm thấy MariaDB client trong Termux."
command -v mariadb >/dev/null 2>&1 || fail "Không tìm thấy lệnh mariadb trong Termux."
mkdir -p "$LOG_DIR" "$PROJECT/lib"

cfg() {
  local key="$1" default="$2" value
  value="$(awk -F= -v k="$key" '$1 == k {sub(/^[[:space:]]+/,"",$2); sub(/[[:space:]]+$/, "", $2); print $2; exit}' "$PROJECT/Config.properties")"
  printf '%s' "${value:-$default}"
}

DB_HOST="$(cfg database.host 127.0.0.1)"
DB_PORT="${NRO_DB_PORT:-$(cfg database.port 3306)}"
DB_NAME="$(cfg database.name ngocrong)"
DB_USER="${NRO_DB_USER:-$(cfg database.user ngocrong_game)}"
DB_PASS="${NRO_DB_PASS:-$(cfg database.pass '')}"

# Existing installs may have been created before the metrics agent was enabled.
# Normalize only the local agent switches; do not touch game tables or credentials.
if grep -q '^panel\.agent\.enabled=' "$PROJECT/Config.properties"; then
  sed -i -E 's/^panel[.]agent[.]enabled=.*/panel.agent.enabled=true/' "$PROJECT/Config.properties"
else
  printf '\npanel.agent.enabled=true\n' >> "$PROJECT/Config.properties"
fi
if ! grep -q '^panel\.agent\.host=' "$PROJECT/Config.properties"; then
  printf 'panel.agent.host=127.0.0.1\n' >> "$PROJECT/Config.properties"
fi
if ! grep -q '^panel\.agent\.port=' "$PROJECT/Config.properties"; then
  printf 'panel.agent.port=14446\n' >> "$PROJECT/Config.properties"
fi
if ! grep -q '^panel\.agent\.key=' "$PROJECT/Config.properties"; then
  printf 'panel.agent.key=local-only\n' >> "$PROJECT/Config.properties"
fi

CONFIG_SERVER_IP="$(cfg server.ip 127.0.0.1)"
SERVER_IP="${NRO_SERVER_IP:-$CONFIG_SERVER_IP}"
CONFIG_GAME_PORT="$(cfg server.port 14445)"
# The delivered DragonBoy250 redirector forces every socket URL to
# 127.0.0.1:14445. Keep the existing runtime aligned with that client endpoint.
GAME_PORT="${NRO_GAME_PORT:-14445}"

# IP discovery is intentionally not attempted here. On some Termux devices
# `ip route get` returns status 1 when there is no default route, and that must
# never prevent MariaDB/Java from starting. Set NRO_SERVER_IP explicitly when
# the client is on another device; otherwise the configured server.ip is used.
if [ -n "${NRO_SERVER_IP:-}" ]; then
  info "Dùng IP server được chỉ định: $SERVER_IP"
elif [ "$SERVER_IP" = "127.0.0.1" ] || [ "$SERVER_IP" = "localhost" ]; then
  info "Dùng server.ip=$SERVER_IP trong Config.properties; không tự dò route."
fi

# Keep the address sent by DataGame.sendLinkIP synchronized with the address
# printed by this launcher. This changes only endpoint properties, never SQL
# or MariaDB data.
if [ "$SERVER_IP" != "$CONFIG_SERVER_IP" ] || [ "$GAME_PORT" != "$CONFIG_GAME_PORT" ] || [ -n "${NRO_SERVER_IP:-}" ] || [ -n "${NRO_GAME_PORT:-}" ]; then
  sed -i -E "s|^server[.]ip=.*$|server.ip=$SERVER_IP|" "$PROJECT/Config.properties"
  sed -i -E "s|^server[.]port=.*$|server.port=$GAME_PORT|" "$PROJECT/Config.properties"
  sed -i -E "s|^server[.]sv1=.*$|server.sv1=NRO 2024:$SERVER_IP:$GAME_PORT:0|" "$PROJECT/Config.properties"
  info "Đã đồng bộ địa chỉ quảng bá trong Config.properties: ${SERVER_IP}:${GAME_PORT}"
fi

# DragonBoy250 expects comma-separated server entries followed by exactly two
# priority bytes. Legacy installs stored `server.sv1=...:0,0,0`; Manager and
# DataGame append their own fields, so those commas become orphan entries.
# Normalize every legacy server.svN value before Java starts.
if sed -i -E '/^server[.]sv[0-9]+=/{s/(,0)+[[:space:]]*$//;}' "$PROJECT/Config.properties"; then
  info "Đã chuẩn hóa server-list cho DragonBoy250."
else
  fail "Không thể chuẩn hóa server-list trong $PROJECT/Config.properties."
fi

# A previously installed cc2.jar may contain the obsolete shaded Connector/J 5.1
# driver. Put the tested bridge and Connector/J 8.4.0 before cc2.jar on the
# classpath, so old embedded classes cannot win class loading.
JDBC_BRIDGE="$SCRIPT_DIR/lib/compat-mysql-driver.jar"
JDBC_MODERN="$SCRIPT_DIR/lib/mysql-connector-j-8.4.0.jar"
if [ -f "$JDBC_BRIDGE" ] && [ -f "$JDBC_MODERN" ]; then
  if [ ! -s "$PROJECT/lib/compat-mysql-driver.jar" ] || ! cmp -s "$JDBC_BRIDGE" "$PROJECT/lib/compat-mysql-driver.jar"; then
    cp -f "$JDBC_BRIDGE" "$PROJECT/lib/compat-mysql-driver.jar"
    info "Đã cập nhật bridge JDBC tương thích."
  fi
  if [ ! -s "$PROJECT/lib/mysql-connector-j-8.4.0.jar" ] || ! cmp -s "$JDBC_MODERN" "$PROJECT/lib/mysql-connector-j-8.4.0.jar"; then
    cp -f "$JDBC_MODERN" "$PROJECT/lib/mysql-connector-j-8.4.0.jar"
    info "Đã cập nhật Connector/J hiện đại."
  fi
  for legacy in "$PROJECT"/lib/mysql-connector*.jar; do
    [ -f "$legacy" ] || continue
    case "$(basename "$legacy")" in
      mysql-connector-j-8.4.0.jar) ;;
      *)
        mv -f "$legacy" "$legacy.disabled-by-start-only"
        info "Đã tạm vô hiệu hóa driver cũ: $(basename "$legacy")"
        ;;
    esac
  done
else
  fail "Thiếu gói JDBC sửa lỗi trong launcher. Hãy chạy lại lệnh start-only mới từ GitHub."
fi

# DragonBoy250 protocol compatibility is shipped as compiled per-class patches.
# Applying these classes in place refreshes only the existing runtime JAR; it does
# not download/extract an archive and never touches MariaDB or SQL data.
PROTOCOL_PATCH_DIR="$SCRIPT_DIR/runtime-patches"
PROTOCOL_PATCHES=(
  "nro/models/network/KeyHandler.class"
  "nro/models/network/Collector.class"
  "nro/models/network/MessageSendCollect.class"
  "nro/models/network/Network.class"
  "nro/models/network/Sender.class"
  "nro/models/network/Session.class"
  "nro/models/network/QueueHandler.class"
  "nro/models/network/Message.class"
  "nro/models/network/MySession.class"
  "nro/models/database/AmodsubVN.class"
  "nro/models/data/DataGame.class"
  "nro/models/network/ClientVerifier.class"
  "nro/models/services/Service.class"
  "nro/models/services_func/Trade.class"
  "nro/models/services_func/TransactionService.class"
  "nro/models/services_func/LuckyRound.class"
  "nro/models/services/TaskService.class"
  "nro/models/services/SkillService.class"
  "nro/models/services_func/UseItem.class"
  "nro/models/server/Controller.class"
  "nro/models/npc/DuaHauEgg.class"
  "nro/models/server/ServerManager.class"
  "nro/models/database/ClanDAO.class"
  "nro/models/database/ShopDAO.class"
  "nro/models/database/HistoryTransactionDAO.class"
  "nro/models/database/SuperRankDAO.class"
  "nro/models/shop/TabShop.class"
  "nro/models/shop/Shop.class"
  "nro/models/shop/TabShopSanta.class"
  "nro/models/shop/TabShopUron.class"
  "nro/models/shop/TabShopMuaAvatar.class"
  "nro/models/shop/TabShopHangDoc.class"
  "nro/models/shop/TabShopHocKynang.class"
  "nro/models/shop/TabShopDanhHieu.class"
  "nro/models/shop/TabShopSoHuu.class"
  "nro/models/shop/ItemShop.class"
  "nro/models/server/ServerExpRate.class"
  "nro/models/server/PanelCommandService.class"
  "nro/models/server/Manager.class"
  "nro/models/server/panel/PanelActionQueue.class"
  "nro/models/server/panel/PanelActions.class"
  "nro/models/server/panel/PanelAgent\$Handler.class"
  "nro/models/server/panel/PanelAgent.class"
  "nro/models/server/panel/PanelAuditService.class"
  "nro/models/server/panel/PanelAuthService\$Session.class"
  "nro/models/server/panel/PanelAuthService\$User.class"
  "nro/models/server/panel/PanelAuthService.class"
  "nro/models/server/panel/PanelBootstrap.class"
  "nro/models/server/panel/PanelBossCatalog.class"
  "nro/models/server/panel/PanelBossConfigService.class"
  "nro/models/server/panel/PanelBossRewardService.class"
  "nro/models/server/panel/PanelBossRuntime.class"
  "nro/models/server/panel/PanelBossSpawnRegistry.class"
  "nro/models/server/panel/PanelClanBridge.class"
  "nro/models/server/panel/PanelClanSidecar.class"
  "nro/models/server/panel/PanelConfig.class"
  "nro/models/server/panel/PanelMetricsCollector.class"
  "nro/models/server/panel/PanelNpcShopCatalog\$NpcShopRules.class"
  "nro/models/server/panel/PanelNpcShopCatalog.class"
  "nro/models/server/panel/PanelReadService.class"
  "nro/models/server/panel/PanelShopSpawnService.class"
  "nro/models/server/panel/PanelUtil.class"
  "nro/models/server/panel/PanelWriteService.class"
)
command -v jar >/dev/null 2>&1 || fail "Không tìm thấy lệnh jar trong Java runtime."
for patch in "${PROTOCOL_PATCHES[@]}"; do
  [ -s "$PROTOCOL_PATCH_DIR/$patch" ] || fail "Thiếu patch protocol DragonBoy250: $patch"
done
jar_args=()
for patch in "${PROTOCOL_PATCHES[@]}"; do
  jar_args+=( -C "$PROTOCOL_PATCH_DIR" "$patch" )
done
jar uf "$PROJECT/cc2.jar" "${jar_args[@]}" \
  || fail "Không thể cập nhật patch protocol DragonBoy250 vào cc2.jar."
info "Đã áp dụng patch handshake/server-list/resource DragonBoy250."

socket_ping() {
  mariadb-admin --no-defaults --socket="$SOCKET" -u root ping >/dev/null 2>&1 \
    || mariadb-admin --no-defaults --socket="$SOCKET" -u "${USER:-$(id -un)}" ping >/dev/null 2>&1
}
tcp_ping() {
  if [ -n "$DB_PASS" ]; then
    MYSQL_PWD="$DB_PASS" mariadb-admin --no-defaults --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" ping >/dev/null 2>&1
  else
    mariadb-admin --no-defaults --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" ping >/dev/null 2>&1
  fi
}
db_query() {
  if [ -n "$DB_PASS" ]; then
    MYSQL_PWD="$DB_PASS" mariadb --no-defaults --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" -Nse "$1"
  else
    mariadb --no-defaults --protocol=tcp -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" -Nse "$1"
  fi
}

if socket_ping || tcp_ping; then
  info "MariaDB đã chạy."
else
  info "Khởi động MariaDB hiện có..."
  rm -f "$SOCKET" "$DB_DATA"/*.pid 2>/dev/null || true
  if command -v mariadbd >/dev/null 2>&1; then
    nohup mariadbd --no-defaults --datadir="$DB_DATA" --socket="$SOCKET" \
      --port="$DB_PORT" --bind-address=127.0.0.1 --pid-file="$LOG_DIR/mariadbd.pid" \
      --log-error="$LOG_DIR/mariadb.log" >>"$LOG_DIR/mariadb.log" 2>&1 &
  elif command -v mysqld_safe >/dev/null 2>&1; then
    nohup mysqld_safe --no-defaults --datadir="$DB_DATA" --socket="$SOCKET" \
      --port="$DB_PORT" --bind-address=127.0.0.1 >"$LOG_DIR/mariadb.log" 2>&1 &
  else
    fail "Không tìm thấy mariadbd hoặc mysqld_safe."
  fi
  DB_PID=$!
  DB_READY=0
  for _ in $(seq 1 60); do
    if socket_ping || tcp_ping; then DB_READY=1; break; fi
    if ! kill -0 "$DB_PID" 2>/dev/null; then break; fi
    sleep 1
  done
  [ "$DB_READY" -eq 1 ] || { tail -100 "$LOG_DIR/mariadb.log" >&2 || true; fail "MariaDB không khởi động được; không thay đổi dữ liệu hiện có."; }
  info "MariaDB đã sẵn sàng."
fi

TABLE_COUNT="$(db_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || true)"
if ! [[ "$TABLE_COUNT" =~ ^[0-9]+$ ]] || [ "$TABLE_COUNT" -lt 1 ]; then
  fail "Không truy cập được database $DB_NAME bằng user $DB_USER; không import lại SQL trong start-only."
fi
info "Database $DB_NAME hoạt động, số bảng: $TABLE_COUNT"

if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    info "Game server đã chạy PID $OLD_PID."
    PANEL_START="$PROJECT/termux/start-panel.sh"
    if [ -x "$PANEL_START" ]; then
      if bash "$PANEL_START"; then
        info "Web panel đã được kiểm tra/kích hoạt cùng game server."
      else
        info "[WARN] Web panel chưa khởi động được; game server vẫn đang hoạt động."
      fi
    else
      info "Web panel chưa được cài trong runtime; bỏ qua kích hoạt panel."
    fi
    exit 0
  fi
  rm -f "$PID_FILE"
fi

# Keep old diagnostics separately so a later successful launch is not hidden
# below an earlier failed run in the same game-server.log file.
if [ -s "$LOG_FILE" ]; then
  mv -f "$LOG_FILE" "$LOG_FILE.previous" 2>/dev/null || true
fi
: >"$LOG_FILE"

if [ -f "$INPUT_PID_FILE" ]; then
  OLD_INPUT_PID="$(cat "$INPUT_PID_FILE" 2>/dev/null || true)"
  kill "$OLD_INPUT_PID" 2>/dev/null || true
  rm -f "$INPUT_PID_FILE"
fi
[ -p "$INPUT_FIFO" ] || { rm -f "$INPUT_FIFO"; mkfifo "$INPUT_FIFO"; }
# Keep one writer open forever. Unlike `tail -f /dev/null`, this does not
# exit immediately on Android and therefore prevents Scanner.hasNextLine()
# from seeing EOF after the server binds its port.
(
  while :; do sleep 3600; done
) >"$INPUT_FIFO" &
INPUT_PID=$!
printf '%s\n' "$INPUT_PID" >"$INPUT_PID_FILE"

if [ "${TERMUX_LOW_RAM:-1}" = "1" ]; then
  JVM_OPTS="-Xms64m -Xmx768m -XX:MaxMetaspaceSize=160m -Xss512k -XX:+UseSerialGC"
else
  JVM_OPTS="-Xms128m -Xmx1536m -XX:MaxMetaspaceSize=192m -Xss512k -XX:+UseG1GC"
fi
JVM_OPTS="${JVM_OPTS} ${NRO_JVM_OPTS:-}"

info "Khởi động Java game từ runtime hiện có..."
info "Địa chỉ server cấu hình: ${SERVER_IP}:${GAME_PORT}"
info "Địa chỉ lắng nghe: 0.0.0.0:${GAME_PORT}"
info "Database: ${DB_HOST}:${DB_PORT}/${DB_NAME}"
cd "$PROJECT"
CP="$PROJECT/lib/compat-mysql-driver.jar:$PROJECT/lib/mysql-connector-j-8.4.0.jar:$PROJECT/cc2.jar:$PROJECT/lib/*"
nohup java $JVM_OPTS -Dfile.encoding=UTF-8 -cp "$CP" \
  nro.models.server.ServerManager <"$INPUT_FIFO" >>"$LOG_FILE" 2>&1 &
JAVA_PID=$!
printf '%s\n' "$JAVA_PID" >"$PID_FILE"

# Show this launch's data-loading output live, just like foreground mode. The
# file was rotated above, so old JDBC errors are not mixed into this stream.
LOG_FOLLOW_PID=""
if command -v tail >/dev/null 2>&1; then
  tail -n 0 -f "$LOG_FILE" &
  LOG_FOLLOW_PID=$!
fi
stop_log_follow() {
  if [ -n "$LOG_FOLLOW_PID" ]; then
    kill "$LOG_FOLLOW_PID" 2>/dev/null || true
    wait "$LOG_FOLLOW_PID" 2>/dev/null || true
    LOG_FOLLOW_PID=""
  fi
}

port_is_listening() {
  # ServerManager prints this only after its bind() call succeeds. It is a
  # reliable fallback on Termux when ss/netstat briefly misses the socket.
  if grep -Fq "Server initialized and listening on port $GAME_PORT" "$LOG_FILE" 2>/dev/null; then
    return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -Eq ":${GAME_PORT}([[:space:]]|$)"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -Eq ":${GAME_PORT}([[:space:]]|$)"
  else
    return 0
  fi
}

# Loading all game data can take over 40 seconds on Android storage.
for _ in $(seq 1 120); do
  if ! kill -0 "$JAVA_PID" 2>/dev/null; then
    stop_log_follow
    rm -f "$PID_FILE" "$INPUT_PID_FILE"
    tail -120 "$LOG_FILE" >&2 || true
    fail "Java server đã thoát; xem $LOG_FILE."
  fi
  if port_is_listening; then
    stop_log_follow
    info "Server đã chạy PID $JAVA_PID, cổng $GAME_PORT đang LISTEN."
    info "Địa chỉ kết nối: ${SERVER_IP}:${GAME_PORT}"
    info "Địa chỉ lắng nghe: 0.0.0.0:${GAME_PORT}"
    info "Database: ${DB_HOST}:${DB_PORT}/${DB_NAME}"
    info "Log: $LOG_FILE"
    PANEL_START="$PROJECT/termux/start-panel.sh"
    if [ -x "$PANEL_START" ]; then
      if bash "$PANEL_START"; then
        info "Web panel đã được kích hoạt sau khi game server sẵn sàng."
      else
        info "[WARN] Web panel chưa khởi động được; game server vẫn đang hoạt động."
      fi
    else
      info "Web panel chưa được cài trong runtime; bỏ qua kích hoạt panel."
    fi
    exit 0
  fi
  sleep 1
done

stop_log_follow
tail -120 "$LOG_FILE" >&2 || true
fail "Java còn chạy nhưng chưa xác nhận cổng $GAME_PORT sau 120 giây."
