import AppKit
import SwiftUI

extension View {
    /// The background every floating panel sits on: Liquid Glass on macOS 26 and later, a thin
    /// material with a hairline edge before that.
    ///
    /// Glass draws its own rim and shadow, so it only gets a stroke when `border` asks for one (a
    /// state, like an accent edge while focused), never the plain hairline the material needs.
    /// `opacity` fades the background alone, not the content on top.
    @ViewBuilder
    func glassBackground<S: InsettableShape>(
        _ shape: S,
        opacity: Double = 1,
        border: Color? = nil,
        borderWidth: CGFloat = 1
    ) -> some View {
        if #available(macOS 26, *) {
            background { Color.clear.glassEffect(.regular, in: shape).opacity(opacity) }
                .overlay { if let border { shape.strokeBorder(border, lineWidth: borderWidth) } }
        } else {
            background { shape.fill(.ultraThinMaterial).opacity(opacity) }
                .overlay { shape.strokeBorder(border ?? Color.primary.opacity(0.12), lineWidth: borderWidth) }
        }
    }
}

extension View {
    /// The background of the strips that line a screen edge, as the Dock's: thicker glass, lit
    /// along its top edge and shaded towards the bottom, bending what is behind it at the rim.
    /// Elsewhere the same as `glassBackground`.
    @ViewBuilder
    func dockGlassBackground(
        cornerRadius: CGFloat,
        opacity: Double = 1,
        border: Color? = nil,
        borderWidth: CGFloat = 1
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *), let variant = DockGlass.variant {
            background { DockGlass(cornerRadius: cornerRadius, variant: variant).opacity(opacity) }
                .overlay { if let border { shape.strokeBorder(border, lineWidth: borderWidth) } }
        } else {
            glassBackground(shape, opacity: opacity, border: border, borderWidth: borderWidth)
        }
    }
}

/// Glass in one of AppKit's own variants. SwiftUI only offers the plain one (`.regular`); the
/// raised, Dock-like look is a private variant of `NSGlassEffectView`.
@available(macOS 26, *)
private struct DockGlass: NSViewRepresentable {
    let cornerRadius: CGFloat
    let variant: Int

    /// The variant to draw, or nil to use plain glass: when AppKit no longer has the private
    /// setter, or the hidden default `glassVariant` is negative. 9 by default; 0–23 are the ones
    /// that exist on macOS 26–27 (0 is plain, 11 clear and strongly refracting).
    static var variant: Int? {
        guard NSGlassEffectView.instancesRespond(to: NSSelectorFromString("set_variant:")) else { return nil }
        let value = UserDefaults.standard.object(forKey: "glassVariant") as? Int ?? 9
        return value >= 0 ? value : nil
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = PassThroughGlassView()
        view.setValue(variant, forKey: "_variant")
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
        if (view.value(forKey: "_variant") as? Int) != variant { view.setValue(variant, forKey: "_variant") }
    }
}

/// Only a background: clicks and hovers go to the SwiftUI content and gestures over it.
@available(macOS 26, *)
private final class PassThroughGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
