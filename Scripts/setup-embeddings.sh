#!/usr/bin/env bash
# One-time setup for One Space's local embedding server.
#
# Primary:  EmbeddingGemma 2 (unsloth/embeddinggemma-2-GGUF, UD-Q4_K_XL, ~176 MB)
#           served by llama.cpp built from latest source (needs gemma-embedding2 support).
# Fallback: EmbeddingGemma 300m (unsloth/embeddinggemma-300m-GGUF, Q4_0, ~265 MB),
#           used ONLY if EmbeddingGemma 2 fails to load.
#
# Safe to re-run: skips work that is already done. Pass --update to pull and rebuild llama.cpp.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT/models"
VENDOR="$ROOT/vendor/llama.cpp"
SERVER_BIN="$VENDOR/build/bin/llama-server"
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-}"
mkdir -p "$MODEL_DIR" "$ROOT/vendor" "$ROOT/logs"

UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

EG2_REPO="unsloth/embeddinggemma-2-GGUF"
EG2_FILE="embeddinggemma-2-UD-Q4_K_XL.gguf"
FALLBACK_REPO="unsloth/embeddinggemma-300m-GGUF"
FALLBACK_FILE="embeddinggemma-300m-Q4_0.gguf"

say() { printf '\n==> %s\n' "$*"; }

ensure_tools() {
  local missing=()
  command -v git   >/dev/null 2>&1 || missing+=(git)
  command -v cmake >/dev/null 2>&1 || missing+=(cmake)
  if (( ${#missing[@]} )); then
    if ! command -v brew >/dev/null 2>&1; then
      echo "Missing ${missing[*]} and Homebrew is not installed. Install Homebrew from https://brew.sh first." >&2
      exit 1
    fi
    say "Installing build tools with Homebrew: ${missing[*]}"
    brew install "${missing[@]}"
  fi
  if ! xcrun --find clang++ >/dev/null 2>&1; then
    echo "Apple's command line tools are missing. Run: xcode-select --install" >&2
    exit 1
  fi
}

build_llama() {
  if [[ ! -d "$VENDOR/.git" ]]; then
    say "Downloading latest llama.cpp source"
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$VENDOR"
  elif (( UPDATE )); then
    say "Updating llama.cpp source"
    git -C "$VENDOR" pull --ff-only || echo "(could not fast-forward; keeping current source)"
  fi

  if [[ -x "$SERVER_BIN" && $UPDATE -eq 0 ]]; then
    echo "llama-server already built: $SERVER_BIN"
    return
  fi

  say "Building llama-server with Metal (Release). This takes about a minute."
  cmake -S "$VENDOR" -B "$VENDOR/build" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON \
    -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
  cmake --build "$VENDOR/build" --config Release --target llama-server -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  [[ -x "$SERVER_BIN" ]] || { echo "Build finished but $SERVER_BIN is missing." >&2; exit 1; }
}

# expected sha256 for a file from the Hugging Face tree API (empty if unavailable)
expected_sha() {
  local repo="$1" file="$2"
  curl -fsSL --connect-timeout 20 "https://huggingface.co/api/models/${repo}/tree/main" 2>/dev/null \
    | python3 -c "import sys,json
try:
  for f in json.load(sys.stdin):
    if f.get('path')=='$file': print((f.get('lfs') or {}).get('oid',''))
except Exception: pass" 2>/dev/null || true
}

download() {
  local repo="$1" file="$2" dest="$MODEL_DIR/$2" want have
  want="$(expected_sha "$repo" "$file")"
  if [[ -s "$dest" && "$(head -c 4 "$dest")" == "GGUF" ]]; then
    if [[ -z "$want" ]]; then echo "Already have $file"; return 0; fi
    have="$(shasum -a 256 "$dest" | awk '{print $1}')"
    if [[ "$have" == "$want" ]]; then echo "Already have $file (checksum OK)"; return 0; fi
    echo "Checksum mismatch for $file, downloading again."
  fi
  say "Downloading $repo/$file"
  rm -f "$dest.partial"
  curl -fL --connect-timeout 20 --retry 3 --retry-delay 2 -o "$dest.partial" \
    "https://huggingface.co/${repo}/resolve/main/${file}"
  [[ "$(head -c 4 "$dest.partial")" == "GGUF" ]] || { rm -f "$dest.partial"; echo "Not a GGUF: $file" >&2; return 1; }
  if [[ -n "$want" ]]; then
    have="$(shasum -a 256 "$dest.partial" | awk '{print $1}')"
    [[ "$have" == "$want" ]] || { rm -f "$dest.partial"; echo "Checksum mismatch for $file" >&2; return 1; }
  fi
  mv "$dest.partial" "$dest"
  echo "Saved $dest ($(du -h "$dest" | awk '{print $1}'))"
}

# Load a model on a spare port and confirm it returns a real 768-number vector.
probe_model() {
  local model="$1" port=8095 log="$ROOT/logs/setup-probe.log" pid ok=1
  "$SERVER_BIN" -m "$model" --embeddings --pooling mean --ctx-size 2048 --batch-size 2048 \
    --ubatch-size 2048 --parallel 1 --host 127.0.0.1 --port "$port" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || break
    if curl -fsS -m 1 "http://127.0.0.1:$port/health" 2>/dev/null | grep -q ok; then ok=0; break; fi
    sleep 1
  done
  if (( ok == 0 )); then
    curl -fsS -m 30 "http://127.0.0.1:$port/v1/embeddings" -H 'Content-Type: application/json' \
      -d '{"input":"task: search result | query: hello","encoding_format":"float"}' \
      | python3 -c 'import sys,json,math
v=json.load(sys.stdin)["data"][0]["embedding"]
assert len(v)==768 and all(math.isfinite(x) for x in v) and any(abs(x)>1e-9 for x in v)
print("  real vector: %d numbers" % len(v))' || ok=1
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return $ok
}

ensure_tools
build_llama
download "$EG2_REPO" "$EG2_FILE" || echo "EmbeddingGemma 2 download failed; will try the fallback."
download "$FALLBACK_REPO" "$FALLBACK_FILE" || true

say "Checking that EmbeddingGemma 2 loads"
if [[ -s "$MODEL_DIR/$EG2_FILE" ]] && probe_model "$MODEL_DIR/$EG2_FILE"; then
  printf '%s\n' "$MODEL_DIR/$EG2_FILE" > "$MODEL_DIR/selected-model.path"
  echo "Using EmbeddingGemma 2."
else
  echo "EmbeddingGemma 2 did not load (see logs/setup-probe.log)." >&2
  echo "FALLBACK: using EmbeddingGemma 300m instead. One Space will re-index automatically if you switch later." >&2
  printf '%s\n' "$MODEL_DIR/$FALLBACK_FILE" > "$MODEL_DIR/selected-model.path"
fi

chmod +x "$ROOT"/Scripts/*.sh || true
echo ""
echo "Setup complete. Start the server with:"
echo "  ./Scripts/start-embeddings.sh            (stays in this window)"
echo "  ./Scripts/start-embeddings.sh --background"
