import AppKit
import SwiftUI

struct ResultRow: View {
    @EnvironmentObject private var appState: AppState
    let result: SearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(result.item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(scoreLabel)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(OneSpaceStyle.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(OneSpaceStyle.accent.opacity(0.12), in: Capsule())
                        .help("Cosine similarity from the local embedding")
                }

                Text(result.item.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(result.item.visionDescribed == true ? 4 : 3)
                    .textSelection(.enabled)

                Text(result.item.relativePath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 12) {
                    Button {
                        appState.revealInFinder(result.item)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    Button {
                        appState.openItem(result.item)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                    if appState.canOpenInPhotoReader(result.item) {
                        Button {
                            appState.openInPhotoReader(result.item)
                        } label: {
                            Label("Open in Photo Reader", systemImage: "photo")
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(OneSpaceStyle.accent)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Reveal in Finder") { appState.revealInFinder(result.item) }
            Button("Open") { appState.openItem(result.item) }
            if appState.canOpenInPhotoReader(result.item) {
                Button("Open in Photo Reader") { appState.openInPhotoReader(result.item) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            if let image = thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var iconName: String {
        switch result.item.kind {
        case .image:
            return "photo"
        case .note:
            return "doc.text"
        case .document:
            return "doc.richtext"
        }
    }

    /// Live thumbnail for images. Falls back to a thumbnail blob on the hit when the cache has none.
    private var thumbnailImage: NSImage? {
        if let image = appState.thumbnail(for: result.item) {
            return image
        }
        if let data = result.thumbnail, let image = NSImage(data: data) {
            return image
        }
        return nil
    }

    private var scoreLabel: String {
        let value = Double(result.score)
        if value >= 0 && value <= 1 {
            return "\(Int((value * 100).rounded()))% match"
        }
        return String(format: "%+.2f", value)
    }
}
