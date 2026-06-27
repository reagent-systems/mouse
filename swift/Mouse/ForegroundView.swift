import SwiftUI

/// Interactive app UI — a vertical stack of horizontally-swipeable carousel lanes separated by
/// shared divider handles. Dragging a divider with one finger resizes the two adjacent lanes.
///
/// Sizing uses `containerRelativeFrame` (measures the real window); a `GeometryReader` here reports
/// an inflated size from the oversized ASCII art sibling in the `ZStack`.
struct ForegroundView: View {
    @State private var deck = CarouselDeck.demo()
    @State private var availableHeight: CGFloat = 0
    @State private var didInit = false
    @State private var dragStart: (top: CGFloat, bottom: CGFloat)?

    private let horizontalInset: CGFloat = 24
    private let cornerRadius: CGFloat = 32
    private let dividerHeight: CGFloat = 32
    private let minLaneHeight: CGFloat = 80

    var body: some View {
        @Bindable var deck = deck

        VStack(spacing: 0) {
            ForEach(Array(deck.lanes.enumerated()), id: \.element.id) { index, lane in
                CarouselLane(
                    lane: $deck.lanes[index],
                    cornerRadius: cornerRadius,
                    horizontalInset: horizontalInset
                )
                .frame(height: lane.height)

                if index < deck.lanes.count - 1 {
                    dividerHandle(index: index)
                }
            }
        }
        .containerRelativeFrame([.horizontal, .vertical]) { length, axis in
            if axis == .vertical, availableHeight != length {
                DispatchQueue.main.async { configure(for: length) }
            }
            return length
        }
    }

    private func configure(for height: CGFloat) {
        availableHeight = height
        guard !didInit else { return }
        let count = deck.lanes.count
        let usable = height - CGFloat(count - 1) * dividerHeight
        let each = max(minLaneHeight, usable / CGFloat(count))
        for i in deck.lanes.indices { deck.lanes[i].height = each }
        didInit = true
    }

    private func dividerHandle(index: Int) -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: dividerHeight)
            .contentShape(Rectangle())
            .padding(.horizontal, horizontalInset)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? (deck.lanes[index].height, deck.lanes[index + 1].height)
                        if dragStart == nil { dragStart = start }

                        let delta = value.translation.height
                        let newTop = start.top + delta
                        let newBottom = start.bottom - delta
                        guard newTop >= minLaneHeight, newBottom >= minLaneHeight else { return }
                        deck.lanes[index].height = newTop
                        deck.lanes[index + 1].height = newBottom
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

/// A single horizontal carousel of panels.
struct CarouselLane: View {
    @Binding var lane: Lane
    let cornerRadius: CGFloat
    let horizontalInset: CGFloat

    var body: some View {
        TabView(selection: $lane.selection) {
            ForEach(Array(lane.panels.enumerated()), id: \.offset) { index, style in
                Panel(style: style, cornerRadius: cornerRadius)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, horizontalInset)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

struct Panel: View {
    let style: PanelStyle
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(style.color)
            .overlay(
                Text(style.title)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

#Preview {
    ContentView()
}
