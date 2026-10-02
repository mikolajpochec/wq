import SwiftUI

/// The tour's pretend desktop: pictogram windows, a miniature strip on the edge the user chose,
/// and the keys just pressed shown as keycaps.
struct SimDesktopView: View {
    @ObservedObject var sim: TourSim
    let prefs: Preferences
    /// A click on a window or an icon; nil on a desktop that is only a preview.
    var onClick: ((Int) -> Void)?

    static let size = CGSize(width: 600, height: 400)
    private static let menuBar: CGFloat = 14
    private static let icon: CGFloat = 26
    private static let stripThickness: CGFloat = 40

    private var side: StripSide { prefs.stripSide }
    private var stripShown: Bool { !prefs.invisibleStrip || sim.aiming }

    /// What windows may cover: the screen less the menu bar and the strip's band.
    private var area: CGRect {
        var rect = CGRect(x: 0, y: Self.menuBar, width: Self.size.width, height: Self.size.height - Self.menuBar)
        if !prefs.invisibleStrip {
            switch side {
            case .left: rect.origin.x += Self.stripThickness; rect.size.width -= Self.stripThickness
            case .right: rect.size.width -= Self.stripThickness
            case .top: rect.origin.y += Self.stripThickness; rect.size.height -= Self.stripThickness
            case .bottom: rect.size.height -= Self.stripThickness
            }
        }
        return rect.insetBy(dx: 6, dy: 6)
    }

    var body: some View {
        let frames = sim.frames(in: area)
        let aimed = Set(sim.aiming ? sim.aimedIDs : [])
        let cursorIDs = sim.aiming && sim.aimEntries.indices.contains(sim.aimCursor)
            ? Set(sim.ids(of: sim.aimEntries[sim.aimCursor])) : []
        ZStack(alignment: .topLeading) {
            wallpaper
            menuBar
            ForEach(sim.zOrder, id: \.self) { id in
                if let window = sim.window(id), let frame = frames[id] {
                    SimWindowView(window: window, isFocused: !sim.aiming && sim.selected == id)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .onTapGesture { onClick?(id) }
                }
            }
            if sim.aiming {
                Color.black.opacity(prefs.aimingDimOpacity * 0.8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                // The aim outlines what it is on, above the dimming, as it does for real.
                ForEach(Array(aimed), id: \.self) { id in
                    if let frame = frames[id] {
                        RoundedRectangle(cornerRadius: sim.window(id)?.isPhone == true ? frame.width * 0.16 : 7)
                            .stroke(Color.orange, lineWidth: cursorIDs.contains(id) ? 3 : 2)
                            .frame(width: frame.width + 4, height: frame.height + 4)
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                    }
                }
            }
            if stripShown { strips.transition(.opacity) }
            flashes
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.15)))
    }

    private var wallpaper: some View {
        LinearGradient(colors: [Color(red: 0.32, green: 0.42, blue: 0.68), Color(red: 0.62, green: 0.45, blue: 0.62)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var menuBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.logo").font(.system(size: 8))
            ForEach(0..<4, id: \.self) { _ in Capsule().frame(width: 18, height: 4).opacity(0.5) }
            Spacer()
            Image(systemName: "rectangle.stack").font(.system(size: 8))
            Capsule().frame(width: 26, height: 4).opacity(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(width: Self.size.width, height: Self.menuBar)
        .background(.black.opacity(0.25))
    }

    // MARK: - Strip

    private var strips: some View {
        let stack = side.isVertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        let alignment: Alignment = {
            switch (side, prefs.stripAlignment) {
            case (.left, .start): return .topLeading
            case (.left, .center): return .leading
            case (.left, .end): return .bottomLeading
            case (.right, .start): return .topTrailing
            case (.right, .center): return .trailing
            case (.right, .end): return .bottomTrailing
            case (.top, .start): return .topLeading
            case (.top, .center): return .top
            case (.top, .end): return .topTrailing
            case (.bottom, .start): return .bottomLeading
            case (.bottom, .center): return .bottom
            case (.bottom, .end): return .bottomTrailing
            }
        }()
        let scaleAnchor: UnitPoint = {
            switch side {
            case .left: return .leading
            case .right: return .trailing
            case .top: return .top
            case .bottom: return .bottom
            }
        }()
        // The layout menu sits beside the strip, on the screen side, as it does for real.
        let beside = side.isVertical ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
        let menuFirst = side == .right || side == .bottom
        return beside {
            if menuFirst { layoutMenu }
            stack {
                if let group = sim.shownGroup { groupStrip(group) }
                mainStrip
            }
            .scaleEffect(sim.aiming ? 1.12 : 1, anchor: scaleAnchor)
            if !menuFirst { layoutMenu }
        }
        .padding(4)
        .frame(width: Self.size.width, height: Self.size.height - Self.menuBar, alignment: alignment)
        .offset(y: Self.menuBar)
    }

    private var mainStrip: some View {
        let stack = side.isVertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        let aimed = sim.aiming && sim.insideGroup == nil ? Set(sim.aimedEntries) : []
        return stack {
            Text("1")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: Self.icon, height: Self.icon * 0.8)
            ForEach(sim.entries, id: \.self) { entry in
                entryView(entry, aimed: aimed.contains(entry))
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }

    @ViewBuilder
    private func entryView(_ entry: TourSim.Entry, aimed: Bool) -> some View {
        switch entry {
        case .window(let id):
            if let window = sim.window(id) {
                SimIcon(window: window, size: Self.icon)
                    .padding(3)
                    .background(selection(isSelected: sim.selected == id && !sim.aiming, isAimed: aimed))
                    .onTapGesture { onClick?(id) }
            }
        case .group(let groupID):
            let members = sim.members(groupID).compactMap(sim.window)
            ZStack {
                ForEach(Array(members.prefix(3).enumerated()), id: \.element.id) { index, window in
                    SimIcon(window: window, size: Self.icon * 0.62)
                        .offset(x: CGFloat(index) * 5 - 5, y: CGFloat(index) * 5 - 5)
                }
            }
            .frame(width: Self.icon, height: Self.icon)
            .overlay(alignment: .bottomTrailing) {
                Text("\(members.count)")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(Color.secondary))
                    .foregroundStyle(.white)
            }
            .padding(3)
            .background(selection(isSelected: !sim.aiming && sim.selected.map { members.map(\.id).contains($0) } == true,
                                  isAimed: aimed))
        }
    }

    private func selection(isSelected: Bool, isAimed: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isAimed ? Color.orange.opacity(0.35) : isSelected ? Color.accentColor.opacity(0.4) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isAimed ? Color.orange : .clear, lineWidth: 2))
    }

    /// A group's own strip, in line before the main one, with the padlock when cycling is locked to it.
    private func groupStrip(_ groupID: Int) -> some View {
        let stack = side.isVertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        let aimed = sim.insideGroup == groupID ? Set(sim.aimedIDs) : []
        return stack {
            ForEach(sim.members(groupID), id: \.self) { id in
                if let window = sim.window(id) {
                    SimIcon(window: window, size: Self.icon * 0.85)
                        .padding(3)
                        .background(selection(isSelected: !sim.aiming && sim.selected == id, isAimed: aimed.contains(id)))
                        .onTapGesture { onClick?(id) }
                }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 10).fill(.thickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5))
        .overlay(alignment: .topTrailing) {
            if sim.lockedGroup == groupID {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .padding(3)
                    .background(Circle().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .offset(x: 6, y: -6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    // MARK: - Layout menu, keys and notes

    @ViewBuilder
    private var layoutMenu: some View {
        if sim.aiming, sim.canTile {
            TourLayoutMenu(options: sim.layoutOptions, highlighted: sim.menuIndex, focused: sim.menuFocused)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private var flashes: some View {
        ZStack {
            VStack {
                if let note = sim.note {
                    Text(note.text)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 24)
                        .id(note.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if let keys = sim.keys {
                    KeyCaps(text: keys.text)
                        .padding(.bottom, 14)
                        .id(keys.id)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
    }
}

/// An app icon pictogram: the app's symbol on its colour.
struct SimIcon: View {
    let window: SimWindow
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(window.tint.gradient)
            .overlay(Image(systemName: window.symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

/// A window pictogram: title bar with traffic lights, the app's symbol and a few lines of content.
/// The iOS Simulator is drawn as a phone.
struct SimWindowView: View {
    let window: SimWindow
    let isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            if window.isPhone { phone(geometry.size) } else { desktopWindow(geometry.size) }
        }
    }

    private func desktopWindow(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(Color.red.opacity(0.85)).frame(width: 5, height: 5)
                Circle().fill(Color.yellow.opacity(0.85)).frame(width: 5, height: 5)
                Circle().fill(Color.green.opacity(0.85)).frame(width: 5, height: 5)
                Text(window.name)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: 21, height: 1)
            }
            .padding(.horizontal, 5)
            .frame(height: 13)
            .background(Color(nsColor: .windowBackgroundColor))
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<max(1, Int(size.height / 18)), id: \.self) { line in
                        Capsule()
                            .fill(line == 0 ? window.tint.opacity(0.55) : Color.secondary.opacity(0.18))
                            .frame(width: max(10, size.width * [0.5, 0.8, 0.65, 0.72, 0.4, 0.6][line % 6]), height: 4)
                    }
                }
                .padding(8)
                Image(systemName: window.symbol)
                    .font(.system(size: min(size.width, size.height) * 0.28))
                    .foregroundStyle(window.tint.opacity(0.22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isFocused ? Color.accentColor : Color.black.opacity(0.2),
                                                          lineWidth: isFocused ? 2 : 0.5))
        .shadow(color: .black.opacity(isFocused ? 0.35 : 0.2), radius: isFocused ? 8 : 4, y: 2)
    }

    private func phone(_ size: CGSize) -> some View {
        let corner = size.width * 0.16
        return RoundedRectangle(cornerRadius: corner)
            .fill(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: corner * 0.8)
                    .fill(LinearGradient(colors: [window.tint.opacity(0.7), .purple.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    .padding(size.width * 0.045)
                    .overlay(
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(size.width * 0.14), spacing: size.width * 0.07), count: 4),
                                  spacing: size.width * 0.07) {
                            ForEach(0..<12, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: size.width * 0.035)
                                    .fill(Color.white.opacity(0.55))
                                    .frame(width: size.width * 0.14, height: size.width * 0.14)
                            }
                        }
                        .padding(.top, size.height * 0.12),
                        alignment: .top
                    )
                    .overlay(Capsule().fill(Color.black).frame(width: size.width * 0.3, height: size.width * 0.07)
                        .padding(.top, size.width * 0.08), alignment: .top)
            )
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(isFocused ? Color.accentColor : .clear, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}

/// Keycaps for a shortcut written as symbols, `⌥⇧]` → ⌥ ⇧ ].
struct KeyCaps: View {
    let text: String
    var small = false

    static func split(_ text: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var caps: [String] = []
        var rest = Substring(text)
        while let first = rest.first, modifiers.contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest)) }
        return caps
    }

    private static let modifierNames: [String: String] = [
        "⌃": "control", "⌥": "option", "⇧": "shift", "⌘": "command",
    ]

    /// A big modifier cap carries its name under the symbol, as Apple's keyboards print it — on
    /// its own `⌃` reads as a stray caret.
    @ViewBuilder
    private func label(_ cap: String) -> some View {
        if !small, let name = Self.modifierNames[cap] {
            VStack(spacing: 0) {
                Text(cap).font(.system(size: 13, weight: .semibold))
                Text(name).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
            }
        } else {
            Text(cap).font(.system(size: small ? 11 : 15, weight: small ? .medium : .semibold))
        }
    }

    var body: some View {
        // Small caps (in text) hold a whole shortcut each, as menus write them; the big ones over
        // the desktop show a cap per key, as pressed.
        HStack(spacing: 4) {
            ForEach(Array((small ? [text] : Self.split(text)).enumerated()), id: \.offset) { _, cap in
                label(cap)
                    .padding(.horizontal, small ? 6 : 8)
                    .frame(minWidth: small ? 22 : 30, minHeight: small ? 20 : 30)
                    .background(
                        RoundedRectangle(cornerRadius: small ? 5 : 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.3), radius: 0, y: small ? 1 : 2)
                    )
                    .overlay(RoundedRectangle(cornerRadius: small ? 5 : 6).stroke(Color.primary.opacity(0.15)))
                    .fixedSize()
            }
        }
    }
}

/// The layout menu beside the aimed windows, with a little diagram of each arrangement.
struct TourLayoutMenu: View {
    let options: [TileLayout]
    let highlighted: Int
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(focused ? "Tile as" : "→ to tile")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(options.enumerated()), id: \.offset) { index, layout in
                HStack(spacing: 6) {
                    LayoutDiagram(layout: layout)
                        .frame(width: 26, height: 17)
                    Text(layout.name).font(.system(size: 11))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(focused && index == highlighted ? Color.accentColor.opacity(0.85) : .clear))
                .foregroundStyle(focused && index == highlighted ? .white : .primary)
            }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .opacity(focused ? 1 : 0.8)
        .shadow(radius: 4)
    }
}

struct LayoutDiagram: View {
    let layout: TileLayout

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(layout.frames.enumerated()), id: \.offset) { _, unit in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: unit.width * geometry.size.width - 2, height: unit.height * geometry.size.height - 2)
                    .position(x: unit.midX * geometry.size.width, y: unit.midY * geometry.size.height)
            }
        }
    }
}
