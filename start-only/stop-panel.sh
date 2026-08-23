#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/logs"
for name in api web; do
  file="$LOG_DIR/panel-$name.pid"
  if [ -s "$file" ]; then
    pid="$(cat "$file" 2>/dev/null || true)"
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$file"
    echo "[Panel] Đã dừng $name PID $pid"
  fi
done
printf '%s\n' '[Panel] Đã dừng web panel; game server và MariaDB không bị tác động.'
