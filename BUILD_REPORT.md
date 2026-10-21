# Build report · One Space (Mac)

Native SwiftUI macOS app built under `/workspace/tech-demos/apps/one-space-mac/` with Grok Build (grok-4.7, xhigh, chunked BATCH1–3). Proven with `swift build` on Tara’s Air.

## Layout

| Path | Role |
| --- | --- |
| `Package.swift` | SPM executable, macOS 14+, links `sqlite3` |
| `Sources/OneSpace/OneSpaceApp.swift` | `@main` SwiftUI entry |
| `Sources/OneSpace/ContentView.swift` | NavigationSplitView shell |
| `Sources/OneSpace/AppState.swift` | folders, index, search, health |
| `Sources/OneSpace/Models/` | IndexedItem, FolderBookmark, SearchResult |
| `Sources/OneSpace/Services/` | BookmarkStore, FolderIndexer, EmbeddingClient, IndexStore, SearchEngine, ThumbnailCache |
| `Sources/OneSpace/Views/` | sidebar, setup, progress, search, results, empties |
| `Sources/OneSpace/Resources/` | Info.plist + entitlements (for later Xcode packaging) |
| `Scripts/` | setup + start local llama-server embeddings |
| `Fixtures/sample-library/` | tiny notes + PNGs for prove |

## Embeddings wiring

- `EmbeddingClient` → `http://127.0.0.1:8081`
- Tries OpenAI-style `/v1/embeddings` then llama.cpp `/embeddings`
- Query prefix: `task: search result | query: …`
- Document prefix: `title: … | text: …`
- **Never fakes vectors.** Health check failure → Setup banner; search disabled until Ready
- Photos v1: embed filename + relative path text (multimodal image encoder = next)

Persist: SQLite + float32 blobs at `~/Library/Application Support/OneSpace/index.sqlite`

## Grok Build notes

- BATCH1: models + EmbeddingClient + IndexStore + SearchEngine
- BATCH2: BookmarkStore + FolderIndexer + ThumbnailCache + AppState
- BATCH3: Views + `@main` + Resources + Scripts + README
- xhigh sessions needed chunked prompts + `--no-plan`; long pre-write reasoning is normal
- Post-BATCH API alignment fixed on box (AppState ↔ services; Swift 6 lock/enumerator/`IndexStore` class)

## Air prove (2026-10-07 ET)

- machineId `724c7d21-c9e2-4969-b232-bafbc54c8dbe` · MacBook-Air.local · arm64 · macOS 26.x
- User home `/Users/madhatter2727` · project at **`~/Projects/one-space-mac`**
- Swift 6.3.2 · Command Line Tools only (no Xcode.app)
- **`swift build` → Build complete** (~28s)
- Binary: `.build/debug/OneSpace` (Mach-O arm64) — launched successfully (pid stayed up)
- Embedding server **not** installed in this prove — app is expected to show Setup UI until `./Scripts/start-embeddings.sh` runs

## Still for Tara / parent

1. Run `./Scripts/setup-embeddings.sh` then `./Scripts/start-embeddings.sh` on the Air
2. Open app → Add Folder → Fixtures or real photo/notes folders → Index → Search
3. Optional later: install full Xcode for signed `.app` + sandbox entitlements packaging
4. No GitHub push, no Vercel (per task)

## How to open

```bash
cd ~/Projects/one-space-mac
swift run
# or
.open .build/debug/OneSpace   # from Terminal: .build/debug/OneSpace
```
