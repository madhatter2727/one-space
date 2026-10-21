#!/usr/bin/env bash
# Serve embeddings for One Space on http://127.0.0.1:8081.
#
#   ./Scripts/start-embeddings.sh               run in this window (Control-C stops it)
#   ./Scripts/start-embeddings.sh --background  run in the background (log: logs/embeddings-server.log)
#
# Primary model: EmbeddingGemma 2 (alias "embeddinggemma2").
# FALLBACK ONLY: EmbeddingGemma 300m (alias "embeddinggemma-300m") if EmbeddingGemma 2 fails to load.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-}"
HOST=127.0.0.1
PORT=8081
BASE="http://$HOST:$PORT"
LOG="$ROOT/logs/embeddings-server.log"
PIDFILE="$ROOT/logs/embeddings-server.pid"
mkdir -p "$ROOT/logs"

EG2="$ROOT/models/embeddinggemma-2-UD-Q4_K_XL.gguf"
FALLBACK="$ROOT/models/embeddinggemma-300m-Q4_0.gguf"
BACKGROUND=0
[[ "${1:-}" == "--background" ]] && BACKGROUND=1

SERVER_BIN="${LLAMA_SERVER:-$ROOT/vendor/llama.cpp/build/bin/llama-server}"
if [[ ! -x "$SERVER_BIN" ]]; then
  echo "llama-server (with EmbeddingGemma 2 support) is not built yet." >&2
  echo "Run: ./Scripts/setup-embeddings.sh" >&2
  exit 1
fi

# Already running?
current="$(curl -fsS -m 2 "$BASE/v1/models" 2>/dev/null || true)"
if printf '%s' "$current" | grep -q '"id":"embeddinggemma2"'; then
  echo "EmbeddingGemma 2 is already running at $BASE"
  exit 0
fi
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -qF "$HOST:$PORT"; then
  echo "Something else is using $HOST:$PORT:" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -F "$HOST:$PORT" >&2 || true
  echo "Stop it first with ./Scripts/stop-embeddings.sh (or quit that app), then run this again." >&2
  exit 1
fi

FLAGS=(--embeddings --pooling mean --ctx-size 2048 --batch-size 2048 --ubatch-size 2048
       --parallel 1 --host "$HOST" --port "$PORT")

launch() {  # $1 model path, $2 alias
  echo "[$(date '+%F %T')] starting $2 ($1)" >>"$LOG"
  # Detach into its own session so closing the launching shell/Terminal doesn't kill it.
  # perl ships with macOS; setsid() keeps the same PID because exec replaces perl.
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' \
    "$SERVER_BIN" -m "$1" --alias "$2" "${FLAGS[@]}" </dev/null >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
}

wait_ready() {  # returns 0 when /health is ok
  local pid; pid="$(cat "$PIDFILE")"
  for _ in $(seq 1 90); do
    kill -0 "$pid" 2>/dev/null || return 1
    curl -fsS -m 1 "$BASE/health" 2>/dev/null | grep -q '"ok"' && return 0
    sleep 1
  done
  return 1
}

: >"$LOG"
MODEL_NAME="EmbeddingGemma 2"
if [[ -s "$EG2" ]]; then
  launch "$EG2" embeddinggemma2
  if ! wait_ready; then
    echo "EmbeddingGemma 2 failed to load (details in $LOG)." >&2
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    sleep 1
    MODEL_NAME=""
  fi
else
  MODEL_NAME=""
fi

if [[ -z "$MODEL_NAME" ]]; then
  if [[ ! -s "$FALLBACK" ]]; then
    echo "No usable model. Run ./Scripts/setup-embeddings.sh" >&2
    exit 1
  fi
  echo "*** FALLBACK: starting EmbeddingGemma 300m instead. Search works, but this is the older model. ***" >&2
  launch "$FALLBACK" embeddinggemma-300m
  wait_ready || { echo "Fallback model also failed. See $LOG" >&2; exit 1; }
  MODEL_NAME="EmbeddingGemma 300m (fallback)"
fi

PID="$(cat "$PIDFILE")"
echo "$MODEL_NAME is running at $BASE (PID $PID). Log: $LOG"
echo "In One Space, click Recheck."

if (( BACKGROUND )); then
  exit 0
fi
echo "Leave this window open. Control-C stops the server."
trap 'kill "$PID" 2>/dev/null; rm -f "$PIDFILE"; exit 0' INT TERM
while kill -0 "$PID" 2>/dev/null; do sleep 2; done
echo "The embedding server stopped. See $LOG" >&2
exit 1
