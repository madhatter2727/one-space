#!/usr/bin/env bash
# Stop One Space's embedding server on 127.0.0.1:8081.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="$ROOT/logs/embeddings-server.pid"
stopped=0
if [[ -s "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")" && stopped=1
fi
# Also stop any llama-server embeddings process holding 127.0.0.1:8081.
for pid in $(lsof -nP -iTCP:8081 -sTCP:LISTEN 2>/dev/null | awk '/127\.0\.0\.1:8081/ && /llama/ {print $2}'); do
  if ps -p "$pid" -o command= | grep -q -- '--embedding'; then kill "$pid" && stopped=1; fi
done
rm -f "$PIDFILE"
sleep 1
(( stopped )) && echo "Embedding server stopped." || echo "No embedding server was running."
