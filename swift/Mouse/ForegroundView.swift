import SwiftUI

/// Interactive app UI — a vertical stack of horizontally-swipeable carousel lanes separated by
/// shared divider handles. Dragging a divider with one finger resizes the two adjacent lanes.
///
/// The stack's outer edges are anchored: the top edge of the first lane and the bottom edge of the
/// last lane always pin to the container, so the deck always fills exactly `availableHeight`. Every
/// mutation re-fits lane heights to preserve that invariant.
///
/// A two-finger magnify gesture adds or removes lanes:
/// - Spreading apart (zoom) inserts a new lane at the gap nearest the gesture's start point.
/// - Pinching together removes the lane nearest the gesture's center.
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
    private let maxLanes: Int = 6

    /// Final magnification above which a spread counts as "zoom → add a lane".
    private let addThreshold: CGFloat = 1.2
    /// Final magnification below which a squeeze counts as "pinch → remove a lane".
    private let removeThreshold: CGFloat = 0.83

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(deck.lanes.enumerated()), id: \.element.id) { index, lane in
                CarouselLane(
                    deck: deck,
                    lane: lane,
                    cornerRadius: cornerRadius,
                    horizontalInset: horizontalInset
                )
                .frame(height: lane.height)
                .transition(.scale.combined(with: .opacity))

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
        .simultaneousGesture(magnifyGesture)
    }

    // MARK: - Magnify (add / remove lanes)

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.05)
            .onEnded { value in
                let y = value.startLocation.y
                if value.magnification >= addThreshold {
                    addLane(nearY: y)
                } else if value.magnification <= removeThreshold {
                    removeLane(nearY: y)
                }
            }
    }

    /// Insert a fresh lane at the gap (inter-lane boundary or outer edge) closest to `y`.
    private func addLane(nearY y: CGFloat) {
        let newCount = deck.lanes.count + 1
        guard newCount <= maxLanes else { return }
        // Must still be able to give every lane at least `minLaneHeight`.
        guard usableHeight(for: newCount) >= minLaneHeight * CGFloat(newCount) else { return }
        // A new lane pulls a container off the ring (restoring the last removed lane's container if
        // it's still on the ring); bail if the whole ring is already on screen.
        guard let restored = deck.containerForNewLane() else { return }

        let insertIndex = nearestGapIndex(toY: y)
        var desired = deck.lanes.map { $0.height }
        // The new lane claims an even share; neighbours shrink proportionally to make room.
        desired.insert(usableHeight(for: newCount) / CGFloat(newCount), at: insertIndex)

        let newLane = Lane(current: restored)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            deck.lanes.insert(newLane, at: insertIndex)
            applyHeights(distribute(desired: desired, total: usableHeight(for: newCount)))
        }
    }

    /// Remove the lane whose center is closest to `y`; remaining lanes grow to refill the space.
    private func removeLane(nearY y: CGFloat) {
        guard deck.lanes.count > 1 else { return }
        let removeIndex = nearestLaneIndex(toY: y)
        let newCount = deck.lanes.count - 1
        var desired = deck.lanes.map { $0.height }
        desired.remove(at: removeIndex)

        let released = deck.lanes[removeIndex].current
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            deck.lanes.remove(at: removeIndex)
            applyHeights(distribute(desired: desired, total: usableHeight(for: newCount)))
        }
        // Its container goes back onto the ring and is remembered for restoration.
        deck.release(released)
    }

    // MARK: - Height bookkeeping (keeps the deck filling `availableHeight`)

    private func configure(for height: CGFloat) {
        availableHeight = height
        guard !didInit else { return }
        let even = deck.lanes.map { _ in CGFloat(1) }
        applyHeights(distribute(desired: even, total: usableHeight(for: deck.lanes.count)))
        didInit = true
    }

    /// Height available to lanes once the dividers between `count` lanes are subtracted.
    private func usableHeight(for count: Int) -> CGFloat {
        availableHeight - CGFloat(max(0, count - 1)) * dividerHeight
    }

    private func applyHeights(_ heights: [CGFloat]) {
        guard heights.count == deck.lanes.count else { return }
        for i in deck.lanes.indices { deck.lanes[i].height = heights[i] }
    }

    /// Scale `desired` heights so they sum exactly to `total` while keeping each ≥ `minLaneHeight`.
    private func distribute(desired: [CGFloat], total: CGFloat) -> [CGFloat] {
        let n = desired.count
        guard n > 0 else { return [] }
        // Not enough room to honour the minimum for everyone: split evenly.
        guard total > minLaneHeight * CGFloat(n) else {
            return Array(repeating: total / CGFloat(n), count: n)
        }
        let floored = desired.map { max(minLaneHeight, $0) }
        let targetSlack = total - minLaneHeight * CGFloat(n)
        let currentSlack = floored.reduce(0) { $0 + ($1 - minLaneHeight) }
        guard currentSlack > 0 else {
            let each = targetSlack / CGFloat(n)
            return floored.map { _ in minLaneHeight + each }
        }
        let factor = targetSlack / currentSlack
        return floored.map { minLaneHeight + ($0 - minLaneHeight) * factor }
    }

    // MARK: - Gesture hit-testing

    /// Y positions of every gap: index 0 = top edge, index `count` = bottom edge, interior gaps at
    /// divider centers. The returned index doubles as the insertion index for a new lane.
    private func nearestGapIndex(toY y: CGFloat) -> Int {
        var offsets: [CGFloat] = [0]
        var cursor: CGFloat = 0
        for (i, lane) in deck.lanes.enumerated() {
            cursor += lane.height
            if i < deck.lanes.count - 1 {
                offsets.append(cursor + dividerHeight / 2)
                cursor += dividerHeight
            } else {
                offsets.append(cursor)
            }
        }
        return offsets.enumerated().min { abs($0.element - y) < abs($1.element - y) }?.offset ?? 0
    }

    /// Index of the lane whose vertical center is closest to `y`.
    private func nearestLaneIndex(toY y: CGFloat) -> Int {
        var cursor: CGFloat = 0
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, lane) in deck.lanes.enumerated() {
            let center = cursor + lane.height / 2
            let distance = abs(center - y)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = i
            }
            cursor += lane.height + dividerHeight
        }
        return bestIndex
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
                        guard index + 1 < deck.lanes.count else { return }
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

/// A lane window onto the shared ring. It looks like a carousel, but swiping just slides plain
/// panels and, on release, moves a container between this lane and the ring's shared edges:
/// swiping left pulls the right-edge container in (pushing the old one off the left), swiping right
/// pulls the left-edge container in (pushing the old one off the right). Every lane shows the same
/// off-screen edges, so containers shuffle freely between lanes. Panels are never torn down and
/// rebuilt (unlike `TabView`), so there is no reload flash.
struct CarouselLane: View {
    let deck: CarouselDeck
    let lane: Lane
    let cornerRadius: CGFloat
    let horizontalInset: CGFloat

    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let rightEdge = deck.reserve.first
            let leftEdge = deck.reserve.last

            ZStack {
                if let leftEdge {
                    panel(leftEdge, width: w, height: h).offset(x: drag - w)
                }
                if let rightEdge {
                    panel(rightEdge, width: w, height: h).offset(x: drag + w)
                }
                panel(lane.current, width: w, height: h).offset(x: drag)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(swipe(width: w, hasLeft: leftEdge != nil, hasRight: rightEdge != nil))
        }
    }

    private func panel(_ type: ContainerType, width: CGFloat, height: CGFloat) -> some View {
        Panel(type: type, cornerRadius: cornerRadius)
            .padding(.horizontal, horizontalInset)
            .frame(width: width, height: height)
    }

    private func swipe(width w: CGFloat, hasLeft: Bool, hasRight: Bool) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in drag = value.translation.width }
            .onEnded { value in
                let threshold = w * 0.22
                let t = value.translation.width
                if t <= -threshold, hasRight {
                    commit(restingAt: drag + w) { deck.advance(laneID: lane.id) }
                } else if t >= threshold, hasLeft {
                    commit(restingAt: drag - w) { deck.retreat(laneID: lane.id) }
                } else {
                    withAnimation(.snappy(duration: 0.2)) { drag = 0 }
                }
            }
    }

    /// Move the container on the ring *immediately* (so what's shown is never stale, even when the
    /// user out-swipes the animation), then animate the slide in a second render pass: the incoming
    /// container already sits at `restingAt`, so we keep it there and glide it to center. The `async`
    /// hop guarantees SwiftUI renders the resting position before animating from it, so the swap is
    /// invisible and a fast follow-up swipe can never reveal the previous container.
    private func commit(restingAt offset: CGFloat, _ move: () -> Void) {
        move()
        drag = offset
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25)) { drag = 0 }
        }
    }
}

struct Panel: View {
    let type: ContainerType
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(type.color)
            .overlay(
                Text(type.title)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

#Preview {
    ContentView()
}
