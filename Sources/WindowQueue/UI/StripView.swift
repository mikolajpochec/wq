import AppKit
import SwiftUI

/// The always-on-top vertical strip: workspace badge on top, then window icons in queue order.
struct StripView: View {
    @ObservedObject var model: WindowQueueModel
    @ObservedObject var store: PreferencesStore
    var onSelect: (ManagedWindow) -> Void

    private var prefs: Preferences { store.prefs }

    var body: some View {
        // The panel keeps a fixed, full-height frame so nothing resizes while the queue changes;
        // the spacers centre the strip and stay transparent to clicks.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            strip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var strip: some View {
        VStack(spacing: StripMetrics.spacing) {
            if prefs.showSpaceBadge {
                spaceBadge
            }
            ForEach(model.visibleWindows) { window in
                row(for: window)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.4).combined(with: .opacity),
                        removal: .scale(scale: 0.6).combined(with: .opacity)
                    ))
            }
        }
        .animation(StripMetrics.layoutAnimation, value: model.visibleWindows.map(\.id))
        .animation(.easeOut(duration: 0.16), value: model.selectedID)
        .padding(StripMetrics.padding)
        .frame(width: prefs.stripWidth)
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.corner, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(prefs.stripOpacity)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var spaceBadge: some View {
        Text(model.currentSpaceIndex.map(String.init) ?? "–")
            .font(.system(size: prefs.iconSize * 0.55, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .frame(width: prefs.iconSize, height: prefs.iconSize)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            )
            .help("Current workspace")
    }

    private func row(for window: ManagedWindow) -> some View {
        let isSelected = window.id == model.selectedID
        return ZStack(alignment: .bottomTrailing) {
            icon(for: window)
                .frame(width: prefs.iconSize, height: prefs.iconSize)
                .opacity(window.isMinimized ? 0.45 : 1)

            if prefs.showWorkspaceNumbers, let workspace = model.workspaceNumber(of: window) {
                Text("\(workspace)")
                    .font(.system(size: max(8, prefs.iconSize * 0.32), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .offset(x: 4, y: 3)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(window) }
        .help(window.displayTitle)
    }

    @ViewBuilder
    private func icon(for window: ManagedWindow) -> some View {
        if let image = window.icon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.3))
        }
    }
}

enum StripMetrics {
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 6
    static let corner: CGFloat = 12
    /// Gap between the strip and the screen edge.
    static let screenMargin: CGFloat = 8
    /// Shared timing so the panel resize and the SwiftUI content move together.
    static let layoutAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.82)
    static let layoutDuration: TimeInterval = 0.32

    /// Height the strip needs for the given content, mirroring `StripView`'s layout.
    static func height(itemCount: Int, prefs: Preferences) -> CGFloat {
        let rows = itemCount + (prefs.showSpaceBadge ? 1 : 0)
        guard rows > 0 else { return padding * 2 }
        let rowHeight = prefs.iconSize + 8 // icon plus the row's own padding
        let badgeHeight = prefs.iconSize
        let itemsHeight = CGFloat(itemCount) * rowHeight + (prefs.showSpaceBadge ? badgeHeight : 0)
        return itemsHeight + CGFloat(rows - 1) * spacing + padding * 2
    }
}
