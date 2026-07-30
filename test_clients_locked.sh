#!/usr/bin/env bash
# Verify that pgdog_clients_locked reacts to a held session-scoped advisory lock.
#
# Uses one long-lived psql session driven via a FIFO so we can:
#   1. Acquire the advisory lock
#   2. Poll the metric while the session is still connected
#   3. Explicitly release the lock (not just kill the session)
#   4. Poll the metric again on the same connection
#
# Assumes docker/pgdog.toml enables `openmetrics_port = 9090` and
# docker-compose.yml maps `9090:9090` on the pgdog service.

set -euo pipefail

: "${METRICS_PORT:=9090}"
: "${PGDOG_PORT:=6432}"
: "${LOCK_ID:=42}"

METRICS_URL="http://127.0.0.1:${METRICS_PORT}/metrics"
export PGPASSWORD=postgres
PSQL=(psql -h 127.0.0.1 -p "${PGDOG_PORT}" -U postgres -d postgres -qXA)

fetch() {
  curl -sf "$METRICS_URL" | awk -v n="$1" '$1 == n { print $2 }'
}

wait_for_metric() {
  local name=$1 expected=$2 v=""
  for _ in $(seq 1 5); do
    v=$(fetch "$name")
    if [[ "$v" == "$expected" ]]; then
      echo "$v"
      return 0
    fi
    sleep 1
  done
  echo "$v"
  return 1
}

FIFO=""
PSQL_PID=""
cleanup() {
  # Close writer fd and let psql exit cleanly if still around
  exec 3>&- 2>/dev/null || true
  [[ -n "$PSQL_PID" ]] && kill "$PSQL_PID" 2>/dev/null || true
  [[ -n "$FIFO" && -e "$FIFO" ]] && rm -f "$FIFO"
}
trap cleanup EXIT

echo "== docker compose up =="
docker compose up -d # --build

echo "== waiting for pgdog on :${PGDOG_PORT} =="
until "${PSQL[@]}" -c 'SELECT 1' >/dev/null 2>&1; do sleep 1; done

echo "== waiting for /metrics on :${METRICS_PORT} =="
until curl -sf "$METRICS_URL" >/dev/null; do sleep 1; done

echo "== baseline =="
baseline=$(fetch clients_locked)
echo "  clients_locked = ${baseline}"
[[ "$baseline" == "0" ]] || { echo "FAIL: expected baseline 0"; exit 1; }

echo "== opening persistent psql session via FIFO =="
FIFO=$(mktemp -u -t pgdog_test.XXXXXX).fifo
mkfifo "$FIFO"
"${PSQL[@]}" < "$FIFO" > /dev/null &
PSQL_PID=$!
# Hold the fifo open for write so psql doesn't hit EOF prematurely
exec 3>"$FIFO"

send() { printf '%s\n' "$1" >&3; }

echo "== acquiring advisory lock =="
send "SELECT pg_advisory_lock(${LOCK_ID});"

echo "== polling for clients_locked = 1 =="
if during=$(wait_for_metric clients_locked 1); then
  echo "  clients_locked = ${during}"
else
  echo "FAIL: expected 1 while lock held, last saw '${during}'"
  exit 1
fi

echo "== releasing advisory lock on same connection =="
send "SELECT pg_advisory_unlock(${LOCK_ID});"

echo "== polling for clients_locked = 0 =="
if after=$(wait_for_metric clients_locked 0); then
  echo "  clients_locked = ${after}"
else
  echo "FAIL: expected 0 after unlock (session still connected), last saw '${after}'"
  exit 1
fi

echo "== closing psql session =="
send "\\q"
exec 3>&-
wait "$PSQL_PID" 2>/dev/null || true
PSQL_PID=""

echo "PASS"
