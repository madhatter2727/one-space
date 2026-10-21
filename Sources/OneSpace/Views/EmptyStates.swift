import SwiftUI

struct EmptyFoldersState: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ContentUnavailableView {
            Label("Add a folder", systemImage: "folder")
        } description: {
            Text("Choose a folder on this Mac. One Space indexes the files in it and searches them on this machine.")
        } actions: {
            Button {
                appState.addFolder()
            } label: {
                Text("Add Folder")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct EmptyQueryState: View {
    var searchEnabled: Bool

    var body: some View {
        ContentUnavailableView(
            "Search your files",
            systemImage: "magnifyingglass",
            description: Text(
                searchEnabled
                    ? "Type something you remember from a file, then press Return."
                    : "Type words you remember from a file, then press Return. Exact matches work before the local model is running."
            )
        )
    }
}

struct EmptyMatchesState: View {
    var body: some View {
        ContentUnavailableView(
            "No matches",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Nothing in the index was close to that search. Try different words, or index again after adding files.")
        )
    }
}
