# Task — One Space native Mac folder-search app (REAL Grok Build)

Build a complete, compile-ready **SwiftUI macOS** app in THIS directory named **One Space**. Tara (vibe coder) picks folders of photos and notes; the app indexes them locally with EmbeddingGemma 2 into one shared meaning-space; she types a search and opens the right file in Finder.

Sibling taste: `../embeddinggemma2-one-space/` (browser playground — this is the REAL Mac app), `../webbrain-osaurus-local/`. Clean Mac-native UI: SF Pro / system fonts, restrained blues/grays, not toy purple AI sludge.

## CRITICAL process rules
1. FIRST tool calls must CREATE real app source files (Xcode project or Package.swift + Sources, SwiftUI views, indexing, embeddings client, SQLite). Do **not** sit in planning-only mode. No empty TODO shells.
2. Dense, real-feeling product — not a stub. Every screen must work in code (folder picker, index progress, search, results, setup).
3. **No fake vectors.** If the local embedding model / server is missing, show a calm setup screen with install/download steps. Never invent random embeddings labeled as real.
4. No GitHub push, no Vercel deploy. Stay in this folder.
5. README in plain language — Tara is a vibe coder; no unexplained jargon.

## Product (plain language)
- User picks folders (photos, notes; voice memos can be “coming soon” only if photos+notes truly work).
- App quietly walks those folders for images (`.jpg/.jpeg/.png/.heic/.webp`) and text notes (`.txt/.md/.rtf`).
- Skip huge files and system junk (`.DS_Store`, `__MACOSX`, `node_modules`, `.git`, etc.).
- Index with EmbeddingGemma 2 (~0.5 GB local embedder) into one shared meaning-space.
- Persist index under Application Support (SQLite + embedding blobs / vector table).
- Search bar → cosine similarity → ranked results with thumbnails/snippets → Reveal in Finder / Open.
- Security-scoped bookmarks so folder access survives relaunch.
- Progress UI with pause/cancel during indexing.

## Tech requirements
- Native **SwiftUI macOS** app target, **macOS 14+**.
- Prefer an Xcode project that opens cleanly (`OneSpace.xcodeproj`) OR a `Package.swift` that can be opened in Xcode as a macOS app. Prefer a real `.xcodeproj` / multi-file Sources layout that `xcodebuild -scheme OneSpace` can build on a Mac.
- Folder picker + security-scoped bookmarks persisted.
- Index pipeline with progress, pause, cancel.
- EmbeddingGemma 2 local path — pragmatic for 16 GB M-series Air, no cloud:
  - **Best:** local embedding sidecar: `llama-server --embeddings` (llama.cpp) with Unsloth EmbeddingGemma 2 GGUF, OR MLX/Python sidecar using mlx-community / Unsloth EmbeddingGemma 2.
  - **Acceptable v1:** text embeddings via local `llama-server --embeddings` for notes + for photos embed filename + optional caption/EXIF/OCR-lite text (document clearly that full multimodal image/audio encoders are next once the model stack is on the machine).
  - Wire a real HTTP client to `http://127.0.0.1:<port>/v1/embeddings` (OpenAI-style) or llama.cpp embeddings endpoint. Health-check on launch. Setup screen if unreachable / model missing.
  - Must NOT fake vectors.
- Persist under `~/Library/Application Support/OneSpace/` (SQLite).
- Search: embed query with same model + prefixes if required by model card (`task: search result | query: …` for queries; `title: … | text: …` for documents), cosine rank, show scores.
- App icon can be SF Symbol placeholder / simple asset; Info.plist with document/folder usage description strings where needed.
- Entitlements: App Sandbox ON with user-selected file read (security-scoped bookmarks), outgoing network to localhost for embeddings sidecar (or disable sandbox network restriction for 127.0.0.1). Document the entitlement choices in README.

## Suggested layout (adapt as needed, but ship complete code)
```
one-space-mac/
  PROMPT.md          (already here)
  README.md          (plain language)
  BUILD_REPORT.md
  OneSpace.xcodeproj/  OR Package.swift + project.yml
  OneSpace/
    OneSpaceApp.swift
    ContentView.swift
    Views/   (LibraryView, SearchView, IndexProgressView, SetupView, ResultRow…)
    Models/  (IndexedItem, FolderBookmark, SearchResult…)
    Services/(BookmarkStore, FolderIndexer, EmbeddingClient, IndexStore, SearchEngine…)
    Resources/(Assets.xcassets, Info.plist, OneSpace.entitlements)
  Scripts/
    setup-embeddings.sh   # download GGUF + start llama-server --embeddings
    start-embeddings.sh
  Fixtures/sample-library/  # tiny notes + placeholder images for later prove
```

## Scripts
Include shell scripts Tara can run on the Air:
1. Download Unsloth EmbeddingGemma 2 GGUF (prefer a small Q4/Q8 quant that fits ~0.5 GB RAM story).
2. Start `llama-server` (or documented MLX alternative) with `--embeddings` on a fixed local port (e.g. 8080).
3. README explains: install llama.cpp / brew formula if needed, run script, then open the app.

Sources to cite in README:
- https://unsloth.ai/docs/models/embeddinggemma-2
- https://huggingface.co/unsloth/embeddinggemma-2-GGUF
- https://ai.google.dev/gemma/docs/embeddinggemma
- Sibling browser demo: `../embeddinggemma2-one-space/`

## UI (must ship, not stubs)
1. **Toolbar / sidebar:** app name “One Space”, status chip (Ready / Indexing / Setup needed), Folders list with Add Folder / Remove.
2. **Setup screen** when embeddings server missing: calm copy, “Install & start local EmbeddingGemma” steps, Copy command / Open Terminal hint, Recheck button. Never fake search.
3. **Index progress:** file count, current path, percent, Pause / Resume / Cancel.
4. **Search:** prominent search field; results list with thumbnail (images) or snippet (notes), score, Reveal in Finder, Open.
5. **Empty states:** no folders yet; indexed but no query; no matches — all calm and useful.
6. Voice memos: optional “Coming soon” row in UI only if photos+notes paths are fully implemented.

## Fixtures
Create `Fixtures/sample-library/` with:
- 2–3 short `.md` / `.txt` notes (cats, sea turtle, sourdough or similar — match sibling demo themes).
- 2 tiny placeholder PNGs (can be minimal valid PNGs generated by script).
These are for the later Air prove step; app should be able to index this folder when she picks it.

## Deliverables
- Complete SwiftUI project that opens in Xcode / builds with `xcodebuild` on macOS.
- `README.md`: what it does, how to run on Air (Xcode or xcodebuild), EmbeddingGemma setup scripts, what still needs her click (folder permission, model download).
- `BUILD_REPORT.md`: what was built, how embeddings are wired, what needs the Air connected (compile, model download, folder permission).
- Keep this `PROMPT.md`.

## Done when
- Real SwiftUI sources on disk with picker, index progress, search, results, setup — not empty TODOs.
- Clear compile path documented for Mac (`open OneSpace.xcodeproj` or `xcodebuild -scheme OneSpace -configuration Debug`).
- Embeddings path is real (HTTP to local server) with setup UI when missing — no fake vectors.
- Fixtures present.
- README plain language for Tara.

Write files NOW. Iterate until polished. This box is Linux — you cannot run `xcodebuild` here; still ship a complete Mac project that will compile on her Air.

## UPDATE — Air connected (macOS 26.5.2 arm64 CLT only)
Tara’s MacBook Air Local Execution is ON. Homebrew + Swift 6.3.2 are present. **Full Xcode.app is NOT installed** — only Command Line Tools at `/Library/Developer/CommandLineTools`. `xcodebuild` fails without Xcode.

Therefore:
1. Prefer a **Swift Package Manager** layout (`Package.swift`) that builds a **macOS SwiftUI app executable** with `swift build` / `swift run` under CLT when possible.
2. Also keep (or generate) an Xcode-openable project path for when full Xcode is installed later — e.g. `Package.swift` that Xcode can open, or a checked-in `.xcodeproj`.
3. Do NOT block on Xcode. Ship complete source + README that documents:
   - What we can prove now with `swift build` on the Air (CLT)
   - What needs full Xcode (`xcodebuild`, signing, App Sandbox entitlements packaging)
4. Embeddings sidecar scripts should use Homebrew (`brew install llama.cpp` or build from source) on Apple Silicon.

