import SwiftUI

/// Interactive app UI — a horizontally swipeable deck of basic containers.
///
/// Sizing uses `containerRelativeFrame` (measures the real window) rather than `GeometryReader`,
/// which gets an inflated size from the oversized ASCII art sibling in the `ZStack`.
struct ForegroundView: View {
    @State private var selection = 0
    private let horizontalInset: CGFloat = 24
    private let cornerRadius: CGFloat = 32

    private let panels: [PanelStyle] = [
        PanelStyle(title: "1", color: .black),
        PanelStyle(title: "2", color: .blue),
        PanelStyle(title: "3", color: .purple),
    ]

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(panels.enumerated()), id: \.offset) { index, style in
                Panel(style: style, cornerRadius: cornerRadius)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, horizontalInset)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .containerRelativeFrame([.horizontal, .vertical]) { length, axis in
            axis == .vertical ? length / 3 : length
        }
    }
}

struct PanelStyle {
    let title: String
    let color: Color
}

struct Panel: View {
    let style: PanelStyle
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(style.color)
            .overlay(
                Text(style.title)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

#Preview {
    ZStack {
        AsciiLogoBackground()
        ForegroundView()
    }
}
