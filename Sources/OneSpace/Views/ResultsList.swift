import SwiftUI

struct ResultsList: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Count sits outside the scroll area so nothing floats over the first result.
            Text(headerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(appState.searchResults.enumerated()), id: \.element.id) { index, result in
                        ResultRow(result: result)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                        Divider().padding(.leading, 12)
                    }
                }
                .padding(.bottom, 12)
            }
            .modifier(NoTopEdgeEffect())
        }
    }

    private var headerText: String {
        let count = appState.searchResults.count
        if count == 1 { return "1 result" }
        return "\(count) results"
    }
}

/// macOS 26 draws a soft white "scroll edge" fade at the top of scroll views,
/// which covered the first result. Turn it off there.
private struct NoTopEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}
