import SwiftUI

extension EmbeddingStatus {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct SetupBanner: View {
    @EnvironmentObject private var appState: AppState

    private var checking: Bool {
        switch appState.embeddingStatus {
        case .unknown, .checking:
            return true
        case .ready, .unavailable:
            return false
        }
    }

    private var unavailableReason: String? {
        if case .unavailable(let reason) = appState.embeddingStatus {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    var body: some View {
        if !appState.embeddingStatus.isReady {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: checking ? "arrow.triangle.2.circlepath" : "server.rack")
                        .foregroundStyle(OneSpaceStyle.accent)
                    Text(checking ? "Checking the embedding server" : "Local embeddings are off")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Button("Recheck") {
                        appState.recheckEmbeddings()
                    }
                    .controlSize(.small)
                }

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text("127.0.0.1:8081")
                    Text("·")
                    Text("Scripts/start-embeddings.sh")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

                if let unavailableReason {
                    Text(unavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OneSpaceStyle.accent.opacity(0.08))
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private var message: String {
        if checking {
            return "Looking for EmbeddingGemma on this Mac. Exact words work in the meantime."
        }
        return "Exact words work right now. Meaning search needs EmbeddingGemma on this Mac. In Terminal, run Scripts/setup-embeddings.sh once, then Scripts/start-embeddings.sh, and leave that window open. Click Recheck when the server is up."
    }
}
