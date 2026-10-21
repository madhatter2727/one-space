import SwiftUI

struct SearchBar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var submittedQuery: String?
    @FocusState private var focused: Bool

    private var ready: Bool {
        appState.embeddingStatus.isReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(
                    "Search files",
                    text: $appState.searchQuery,
                    prompt: Text("Words you remember from a file")
                )
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit(submit)

                if !appState.searchQuery.isEmpty {
                    Button {
                        appState.searchQuery = ""
                        submittedQuery = nil
                        appState.search()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                }

                Button("Search", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedQuery.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )

            if !ready {
                Text("Exact words work now. Meaning search starts when the local model is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .onAppear {
            focused = true
        }
        .onChange(of: ready) { _, isReady in
            if isReady { focused = true }
        }
    }

    private var trimmedQuery: String {
        appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else { return }
        submittedQuery = trimmed
        appState.search()
    }
}
