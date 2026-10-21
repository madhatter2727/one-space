import SwiftUI

struct LibrarySidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            folderList
            controls
        }
        .navigationTitle("Library")
        .navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 320)
    }

    private var snapshot: IndexSnapshot {
        readIndexSnapshot(appState)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OneSpaceStyle.accent)
                Text("One Space")
                    .font(.headline)
                Spacer()
            }
            statusChip
            Text("\(appState.items.count) files indexed")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !appState.embeddingStatus.isReady {
                Text("Embeddings at 127.0.0.1:8081")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var statusChip: some View {
        let title: String
        let color: Color
        if snapshot.isRunning {
            title = "Indexing"
            color = OneSpaceStyle.accent
        } else if appState.embeddingStatus.isReady {
            title = "Ready"
            color = OneSpaceStyle.ready
        } else {
            title = "Setup needed"
            color = Color.secondary
        }

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityLabel("Status: \(title)")
    }

    private var folderList: some View {
        List {
            Section("Folders") {
                if appState.folders.isEmpty {
                    Text("Folders you add show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.folders, id: \.id) { folder in
                        folderRow(folder)
                    }
                    .onDelete(perform: removeFolders)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func folderRow(_ folder: BookmarkedFolder) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(folder.name, systemImage: "folder")
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Remove", role: .destructive) {
                appState.removeFolder(id: folder.id)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Remove this folder")
        }
        .contextMenu {
            Button("Remove", role: .destructive) {
                appState.removeFolder(id: folder.id)
            }
        }
    }

    private func removeFolders(at offsets: IndexSet) {
        for index in offsets.sorted().reversed() {
            appState.removeFolder(id: appState.folders[index].id)
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 8) {
                Button {
                    appState.addFolder()
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appState.startIndexing()
                } label: {
                    Label("Index Now", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(appState.folders.isEmpty || snapshot.isRunning || !appState.embeddingStatus.isReady)
                .help(indexHelp)
            }
            .padding(12)
        }
        .background(.bar)
    }

    private var indexHelp: String {
        if appState.folders.isEmpty {
            return "Add a folder first."
        }
        if !appState.embeddingStatus.isReady {
            return "Start the embedding server, then click Recheck. Indexing stores real embeddings from that server."
        }
        if snapshot.isPaused {
            return "Indexing is paused. Resume it from the progress banner."
        }
        if snapshot.isRunning {
            return "Indexing is running. Pause or cancel it from the progress banner."
        }
        return "Index the files in your folders."
    }
}
