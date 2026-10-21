import SwiftUI

struct IndexSnapshot {
    var fraction: Double
    var completed: Int
    var total: Int
    var discovered: Int
    var skipped: Int
    var failed: Int
    var currentPath: String?
    var phase: IndexProgress.Phase
    var message: String?
    var activity: String?

    var unitFraction: Double {
        min(max(fraction, 0), 1)
    }

    var isPaused: Bool { phase == .paused }

    /// Scan, embed, or a pause between them. Index Now stays quiet during this.
    var isRunning: Bool {
        switch phase {
        case .scanning, .indexing, .paused:
            return true
        case .idle, .finished, .cancelled, .failed:
            return false
        }
    }

    var showsBanner: Bool {
        switch phase {
        case .idle, .finished:
            return false
        case .scanning, .indexing, .paused, .cancelled, .failed:
            return true
        }
    }
}

@MainActor
func readIndexSnapshot(_ appState: AppState) -> IndexSnapshot {
    let progress = appState.indexProgress
    let currentPath: String?
    if let relative = progress.currentRelativePath, !relative.isEmpty {
        if let folder = progress.folderName, !folder.isEmpty {
            currentPath = "\(folder)/\(relative)"
        } else {
            currentPath = relative
        }
    } else {
        currentPath = nil
    }
    return IndexSnapshot(
        fraction: progress.fraction,
        completed: progress.filesCompleted,
        total: progress.filesTotal,
        discovered: progress.filesDiscovered,
        skipped: progress.filesSkipped,
        failed: progress.filesFailed,
        currentPath: currentPath,
        phase: progress.phase,
        message: progress.message,
        activity: progress.activity
    )
}

struct IndexProgressView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let snapshot = readIndexSnapshot(appState)
        if snapshot.showsBanner {
            banner(snapshot)
                .padding(.horizontal, 20)
                .padding(.top, 12)
        }
    }

    private func banner(_ snapshot: IndexSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(snapshot))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if snapshot.phase != .scanning {
                    Text(percentText(snapshot))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if snapshot.phase == .scanning {
                ProgressView()
                    .controlSize(.small)
            } else {
                ProgressView(value: snapshot.unitFraction)
                    .tint(OneSpaceStyle.accent)
            }

            Text(countText(snapshot))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let path = snapshot.currentPath, !path.isEmpty {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if snapshot.isRunning {
                HStack(spacing: 8) {
                    Button("Pause") { appState.pauseIndexing() }
                        .disabled(snapshot.isPaused)
                    Button("Resume") { appState.resumeIndexing() }
                        .disabled(!snapshot.isPaused)
                    Button("Cancel") { appState.cancelIndexing() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .accessibilityElement(children: .contain)
    }

    private func title(_ snapshot: IndexSnapshot) -> String {
        switch snapshot.phase {
        case .scanning: return "Scanning"
        case .paused: return "Indexing paused"
        case .failed: return "Indexing failed"
        case .cancelled: return "Indexing cancelled"
        case .indexing:
            if let activity = snapshot.activity, !activity.isEmpty {
                return activity
            }
            return "Indexing"
        case .idle, .finished: return "Indexing"
        }
    }

    private func percentText(_ snapshot: IndexSnapshot) -> String {
        "\(Int((snapshot.unitFraction * 100).rounded()))%"
    }

    private func countText(_ snapshot: IndexSnapshot) -> String {
        switch snapshot.phase {
        case .scanning:
            if snapshot.discovered == 0 {
                return snapshot.message ?? "Scanning folders"
            }
            return "Found \(snapshot.discovered) files"
        case .failed, .cancelled:
            return snapshot.message ?? "Indexing stopped"
        case .idle, .indexing, .paused, .finished:
            var parts = ["\(snapshot.completed) of \(snapshot.total) files"]
            if snapshot.skipped > 0 {
                parts.append("\(snapshot.skipped) unchanged")
            }
            if snapshot.failed > 0 {
                parts.append("\(snapshot.failed) failed")
            }
            if let message = snapshot.message, !message.isEmpty {
                parts.append(message)
            }
            return parts.joined(separator: " · ")
        }
    }
}
