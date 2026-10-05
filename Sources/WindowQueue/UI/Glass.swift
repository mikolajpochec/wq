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
