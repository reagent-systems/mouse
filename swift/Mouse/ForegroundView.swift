import SwiftUI

/// Interactive app UI — a horizontally swipeable deck of basic containers whose height can be
/// resized by dragging the top or bottom edge.
///
/// Resizing is anchored: dragging one edge moves only that edge while the opposite edge stays put.
/// The panel area is the space left between a top spacer (`topInset`) and bottom spacer
/// (`bottomInset`), so no per-frame height math or layout feedback is needed — which keeps the
/// drag smooth. Container height is read once via a stable background `GeometryReader`.
struct ForegroundView: View {
    @State private var selection = 0
    @State private var availableHeight: CGFloat = 0
    @State private var topInset: CGFloat = 0
    @State private var bottomInset: CGFloat = 0
    @State private var didInit = false
    @State private var dragStartInset: CGFloat?

    private let horizontalInset: CGFloat = 24
    private let cornerRadius: CGFloat = 32
    private let minHeight: CGFloat = 120

    private let panels: [PanelStyle] = [
        PanelStyle(title: "1", color: .black),
        PanelStyle(title: "2", color: .blue),
        PanelStyle(title: "3", color: .purple),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)

            TabView(selection: $selection) {
                ForEach(Array(panels.enumerated()), id: \.offset) { index, style in
                    Panel(style: style, cornerRadius: cornerRadius)
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, horizontalInset)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .top) { resizeHandle(edge: .top) }
            .overlay(alignment: .bottom) { resizeHandle(edge: .bottom) }

            Color.clear.frame(height: bottomInset)
        }
        // Force the VStack to exactly the container size. `containerRelativeFrame` measures the real
        // window; a `GeometryReader` here reports an inflated size from the oversized ASCII sibling.
        .containerRelativeFrame([.horizontal, .vertical]) { length, axis in
            if axis == .vertical, availableHeight != length {
                DispatchQueue.main.async { setAvailableHeight(length) }
            }
            return length
        }
    }

    private func setAvailableHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        availableHeight = height
        if !didInit {
            topInset = height / 3
            bottomInset = height / 3
            didInit = true
        }
    }

    private func resizeHandle(edge: VerticalEdge) -> some View {
        Capsule()
            .fill(.white.opacity(0.6))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .contentShape(Rectangle())
            .padding(.horizontal, horizontalInset)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard availableHeight > 0 else { return }
                        switch edge {
                        case .top:
                            let base = dragStartInset ?? topInset
                            if dragStartInset == nil { dragStartInset = base }
                            let upper = max(0, availableHeight - bottomInset - minHeight)
                            topInset = min(max(base + value.translation.height, 0), upper)
                        case .bottom:
                            let base = dragStartInset ?? bottomInset
                            if dragStartInset == nil { dragStartInset = base }
                            let upper = max(0, availableHeight - topInset - minHeight)
                            bottomInset = min(max(base - value.translation.height, 0), upper)
                        }
                    }
                    .onEnded { _ in dragStartInset = nil }
            )
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
    ContentView()
}
