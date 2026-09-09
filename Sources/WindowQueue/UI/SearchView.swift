import AppKit
import SwiftUI

/// What the search panel is showing: the query, the ranked results and the highlighted row.
final class SearchState: ObservableObject {
    @Published var query = "" {
        didSet { highlighted = 0 }
    }
    @Published var highlighted = 0

    private let model: WindowQueueModel

    init(model: WindowQueueModel) {
        self.model = model
    }

    /// Search deliberately ignores the "current workspace only" scope: a finder that hides most of
    /// the windows is not worth opening.
    var results: [ManagedWindow] {
        let windows = model.windows
        guard !query.isEmpty else { return windows }

        return windows
            .compactMap { window -> (ManagedWindow, Int)? in
                let haystack = "\(window.appName) \(window.title)"
                guard let score = FuzzyMatch.score(query, in: haystack) else { return nil }
                return (window, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var highlightedWindow: ManagedWindow? {
        let results = results
        guard results.indices.contains(highlighted) else { return results.first }
        return results[highlighted]
    }

    func moveHighlight(by delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlighted = ((highlighted + delta) % count + count) % count
    }

    func workspace(of window: ManagedWindow) -> Int? {
        model.workspaceNumber(of: window)
    }

}

struct SearchView: View {
    @ObservedObject var state: SearchState
    var onAccept: (ManagedWindow) -> Void

    static let width: CGFloat = 560
    static let fieldHeight: CGFloat = 52
    static let rowHeight: CGFloat = 44
    static let dividerHeight: CGFloat = 1
    static let visibleRows = 8

    /// The size the panel should be for a given number of results.
    ///
    /// Derived from the counts rather than measured from the view: `fittingSize` reports the layout
    /// as it stands, which during a keystroke is still the previous query's, leaving the panel one
    /// character behind — too tall and showing stale rows, or too short and hiding real ones.
    static func size(forResultCount count: Int) -> NSSize {
        let rows = min(count, visibleRows)
        let list = rows == 0 ? 0 : dividerHeight + CGFloat(rows) * rowHeight
        return NSSize(width: width, height: fieldHeight + list)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if !state.results.isEmpty {
                Divider()
                results
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .frame(width: Self.width)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // Plain text rather than a TextField: the panel already routes keys through a monitor,
            // and a focused control would fight it for the arrows and Return.
            Text(state.query.isEmpty ? "Search windows" : state.query)
                .font(.system(size: 19))
                .foregroundStyle(state.query.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.fieldHeight)
    }

    private var results: some View {
        // Read once per render: `results` is computed, and evaluating it separately for the rows,
        // the highlight and the height invites the three to disagree.
        let windows = state.results

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(windows.indices, id: \.self) { index in
                        row(for: windows[index], isHighlighted: index == state.highlighted)
                            .id(index)
                            .onTapGesture { onAccept(windows[index]) }
                    }
                }
            }
            .frame(height: min(CGFloat(windows.count), CGFloat(Self.visibleRows)) * Self.rowHeight)
            .onChange(of: state.highlighted) { _, highlighted in
                proxy.scrollTo(highlighted, anchor: .center)
            }
        }
    }

    private func row(for window: ManagedWindow, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(window.displayTitle)
                    .lineLimit(1)
                Text(window.appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let workspace = state.workspace(of: window) {
                Text("\(workspace)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.rowHeight)
        .background(isHighlighted ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
    }
}
