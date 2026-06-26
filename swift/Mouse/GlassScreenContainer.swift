import SwiftUI

/// Inset glass panel whose corner radius equals its margin from the screen edge.
struct GlassScreenContainer<Content: View>: View {
    var edgeInset: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(LiquidGlassPanel(cornerRadius: edgeInset))
            .padding(edgeInset)
    }
}

private struct LiquidGlassPanel: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }
}

#Preview {
    ZStack {
        Color.white
        GlassScreenContainer {
            Color.clear
        }
    }
}
