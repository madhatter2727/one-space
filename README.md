# One Space (Mac)

A native Mac app that turns **folders you pick** into one searchable meaning-space.

You choose photo folders and note folders. One Space quietly indexes them on your Mac with a local EmbeddingGemma 2 server (~176 MB model). Then you type something like “cats on the couch” or “sourdough” and open the right file in Finder.

This is the real Mac app. The browser playground lives next door at `../embeddinggemma2-one-space/`.

## What it indexes (v1)

- **Photos:** `.jpg` `.jpeg` `.png` `.heic` `.webp` — described by a local vision model when one is running, otherwise by filename
- **Notes:** `.txt` `.md` `.rtf`
- Skips junk like `.DS_Store`, `node_modules`, `.git`, `__MACOSX`
- **Voice memos:** coming soon

It never invents search scores. If the local embedding server isn’t running, exact-word matches still come back, with a note that meaning search waits for the model.

## What it can search

One Space reads the words in PDFs that have a real text layer, Word files (`.docx` and `.doc`), RTF, OpenDocument text, web pages, plain text, Markdown, CSV, JSON, and code files. Photos are described by the local vision model when it is running, and by filename when it is not. A PDF with no real text layer is described from a picture of page 1 the same way. Apple Pages files are not read.

Adding a folder starts indexing automatically. Exact words always surface files that contain them. Meaning-based matches fill in the rest.

`Scripts/install-app.sh` builds a release, copies it to `~/Applications/One Space.app`, signs it, and relaunches.

## On your Air (Command Line Tools — no full Xcode needed)

Proven path on Tara’s Air:

```bash
cd ~/Projects/one-space-mac
swift build
swift run
# or:
.build/debug/OneSpace
```

- **Swift:** 6.3.2 (Apple)
- **Tools:** `/Library/Developer/CommandLineTools` only — `xcodebuild` is not required for this SPM build
- **Project copy:** `~/Projects/one-space-mac`

Sample files for a first try: `Fixtures/sample-library/` (a few notes + tiny PNGs). In the app: **Add Folder** → pick that folder → start the embedding server → **Index**.

### Later (full Xcode)

When Xcode.app is installed you can open `Package.swift` in Xcode, add App Sandbox entitlements from `Sources/OneSpace/Resources/OneSpace.entitlements`, and ship a signed `.app`. Not required to play today.

## Local EmbeddingGemma 2 (required for search)

One Space talks to a local server at **http://127.0.0.1:8081** running **EmbeddingGemma 2** (Unsloth `embeddinggemma-2-UD-Q4_K_XL.gguf`, ~176 MB, 768-number vectors) through llama.cpp. No cloud. No API key.

```bash
cd ~/Projects/one-space-mac
./Scripts/setup-embeddings.sh               # once: builds latest llama.cpp (Metal) into vendor/, downloads models, checks EG2 loads
./Scripts/start-embeddings.sh --background  # start it and leave it running
./Scripts/stop-embeddings.sh                # stop it
./Scripts/setup-embeddings.sh --update      # later: pull + rebuild llama.cpp
```

- Homebrew's llama.cpp can't load EmbeddingGemma 2 yet (`unknown model architecture: gemma-embedding2`), so setup builds llama.cpp from source into `vendor/llama.cpp`.
- Server flags (Unsloth's): `--embeddings --pooling mean --ctx-size 2048 --batch-size 2048 --ubatch-size 2048 --parallel 1`, alias `embeddinggemma2`.
- **Fallback only:** if EmbeddingGemma 2 fails to load, the start script says so loudly and serves EmbeddingGemma 300m (alias `embeddinggemma-300m`).
- Log: `logs/embeddings-server.log` · PID: `logs/embeddings-server.pid`
- Prompts: queries use `task: search result | query: …`, documents use `title: <file name> | text: …`.
- **Model switches are safe:** the index records which model made its vectors. If the server's model changes, One Space deletes the old vectors and re-indexes automatically — vectors from two models are never mixed.

Headless check (no window): `.build/debug/OneSpace --headless-check Fixtures/sample-library "turtle swimming"`

To rank an existing index without walking the folder again, pass a database path and `--search-only`: `.build/debug/OneSpace --headless-check Fixtures/sample-library "turtle swimming" /tmp/onespace.sqlite --search-only`

Re-index every saved folder, or search the saved library: `.build/debug/OneSpace --reindex-all` and `.build/debug/OneSpace --search "cats on the couch"`

Sources:

- https://unsloth.ai/docs/models/embeddinggemma-2
- https://huggingface.co/unsloth/embeddinggemma-2-GGUF
- https://ai.google.dev/gemma/docs/embeddinggemma

## Photo descriptions

When a vision model is serving `http://127.0.0.1:8093` (OpenAI-compatible llama-server, model name `local`), One Space describes each photo in a couple of sentences and copies any text in the picture. That description is embedded and stored for exact-word search, so a query like "orange cat on a blue couch" can find the photo.

The vision server is optional, and the embedding scripts do not start it. If it is down, photos are indexed by filename as before. Those filename-only photos are described on a later index once the server is up. Unchanged photos that already have a description are skipped.

Descriptions are cached in `~/Library/Application Support/OneSpace/vision-cache.json`, keyed by path and modification time, so a second index does not call the model again.

While a photo is being described, the progress banner reads `Reading photos 3/20`. A PDF whose extracted text is empty or under 40 characters is described from page 1 the same way.

If `~/Applications/Photo Reader.app` is installed, photo and PDF results include **Open in Photo Reader**.

## Plain map of the app

1. Sidebar → Add Folder (Mac asks permission; it remembers with a security-scoped bookmark)
2. Setup banner → start embeddings if needed → Recheck
3. Index → progress with Pause / Resume / Cancel
4. Search bar → ranked results → Reveal in Finder / Open / Open in Photo Reader

Index data lives under `~/Library/Application Support/OneSpace/`.
