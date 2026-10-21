import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var submittedQuery: String?

    var body: some View {
        NavigationSplitView {
            LibrarySidebar()
        } detail: {
            VStack(spacing: 0) {
                SetupBanner()
                IndexProgressView()
                SearchBar(submittedQuery: $submittedQuery)
                errorLine
                Divider()
                    .padding(.top, 12)
                resultsArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("One Space")
            .modifier(NoToolbarPocket())
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var trimmedQuery: String {
        appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showingSubmittedSearch: Bool {
        guard let submittedQuery else { return false }
        return !submittedQuery.isEmpty && submittedQuery == trimmedQuery
    }

    @ViewBuilder
    private var resultsArea: some View {
        if appState.folders.isEmpty {
            EmptyFoldersState()
        } else if showingSubmittedSearch && !appState.searchResults.isEmpty {
            ResultsList()
        } else if showingSubmittedSearch {
            EmptyMatchesState()
        } else {
            EmptyQueryState(searchEnabled: appState.embeddingStatus.isReady)
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let message = appState.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            Text(message)
                .font(.caption)
                .foregroundStyle(Color(red: 0.55, green: 0.22, blue: 0.18))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.top, 8)
        }
    }
}

/// macOS 26 extends the toolbar's frosted band over the first scroll view in the
/// detail column, which hid the top search result. Hide that band and its edge fade.
private struct NoToolbarPocket: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}
