#!/usr/bin/env bash
set -u

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
RUN="$ROOT/run/cn5g-k3"
LOG="$ROOT/logs/cn5g-k3"

if systemctl is-active --quiet mysql \
  && sudo -n mysqladmin ping --silent >/dev/null 2>&1 \
  && sudo -n mysql -N -e "SELECT 1 FROM oai_db.users LIMIT 1" >/dev/null 2>&1; then
  echo "mysql: healthy ($(mysql --version | sed 's/^mysql  *//'), oai_db.users)"
else
  echo "mysql: NOT READY"
fi

for name in upf smf amf; do
  file="$RUN/$name.pid"
  pid=""
  if [[ -s "$file" ]] && kill -0 "$(cat "$file")" 2>/dev/null; then
    pid="$(cat "$file")"
  else
    pid="$(pgrep -xo "$name" 2>/dev/null || true)"
    [[ -n "$pid" ]] && echo "$pid" >"$file"
  fi
  if [[ -n "$pid" ]]; then
    echo "$name: running (PID $pid)"
  else
    echo "$name: stopped"
  fi
done

if pgrep -x smf >/dev/null \
  && grep -q "N4 ASSOCIATION SETUP RESPONSE" "$LOG/smf.log" 2>/dev/null; then
  echo "N4: associated"
else
  echo "N4: not confirmed"
fi

ss -lntup 2>/dev/null | grep -E ':(8080|8081|8805|2152|38412)\b' || true
