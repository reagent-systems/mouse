import SwiftUI

/// Interactive app UI — each layout owns an independent ring. Hold the left or right edge to
/// preview a new ring expanding vertically from that edge; release after a beat to create it.
struct ForegroundView: View {
    @State private var layoutDeck = LayoutDeck.demo()
    @State private var availableHeight: CGFloat = 0
    @State private var newRingPreview = CarouselDeck.fresh(laneCount: 3)
    @State private var edgeHoldStart: Date?
    @State private var edgeHoldTimer: Timer?

    private let edgeZoneWidth: CGFloat = 32
    private let edgeHoldDuration: TimeInterval = 0.35
    private let edgePeekWidth: CGFloat = 108
    private let cornerRadius: CGFloat = 32
    private let horizontalInset: CGFloat = 24
    private let dividerHeight: CGFloat = 32
    private let minLaneHeight: CGFloat = 80

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                RingDeckView(
                    layoutDeck: layoutDeck,
                    deck: layoutDeck.current.deck,
                    availableHeight: h,
                    isPreview: false,
                    cornerRadius: cornerRadius,
                    horizontalInset: horizontalInset,
                    dividerHeight: dividerHeight,
                    minLaneHeight: minLaneHeight
                )
                .frame(width: w, height: h)

                if layoutDeck.isHoldingEdge, let side = layoutDeck.edgeHoldSide {
                    HStack(spacing: 0) {
                        if side == .left {
                            edgePreviewStrip(height: h)
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            edgePreviewStrip(height: h)
                        }
                    }
                    .frame(width: w, height: h)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h)
            .clipped()
            .overlay {
                HStack(spacing: 0) {
                    edgeHoldZone(side: .left, height: h)
                    Spacer(minLength: 0)
                    edgeHoldZone(side: .right, height: h)
                }
            }
            .onAppear {
                layoutDeck.pageWidth = w
                configureAllLayoutHeights(for: h)
            }
            .onChange(of: w) { _, width in layoutDeck.pageWidth = width }
            .onChange(of: h) { _, height in
                availableHeight = height
                configureAllLayoutHeights(for: height)
            }
        }
        .containerRelativeFrame([.horizontal, .vertical]) { length, axis in
            if axis == .vertical, availableHeight != length {
                DispatchQueue.main.async {
                    availableHeight = length
                    configureAllLayoutHeights(for: length)
                }
            }
            return length
        }
    }

    private func edgePreviewStrip(height: CGFloat) -> some View {
        RingDeckView(
            deck: newRingPreview,
            availableHeight: height,
            isPreview: true,
            cornerRadius: cornerRadius,
            horizontalInset: horizontalInset,
            dividerHeight: dividerHeight,
            minLaneHeight: minLaneHeight
        )
        .frame(width: layoutDeck.edgePreviewWidth, height: height)
        .clipped()
    }

    private func configureAllLayoutHeights(for height: CGFloat) {
        guard height > 0 else { return }

        for layout in layoutDeck.layouts {
            configureHeights(for: layout.deck, height: height)
        }
        configureHeights(for: newRingPreview, height: height)
    }

    private func configureHeights(for deck: CarouselDeck, height: CGFloat) {
        guard height > 0, !deck.heightsInitialized else { return }
        let count = deck.lanes.count
        guard count > 0 else { return }
        let usable = height - CGFloat(max(0, count - 1)) * dividerHeight
        let each = max(minLaneHeight, usable / CGFloat(count))
        for i in deck.lanes.indices { deck.lanes[i].height = each }
        deck.heightsInitialized = true
    }

    // MARK: - Edge hold → new ring

    private func edgeHoldZone(side: EdgeSide, height: CGFloat) -> some View {
        Color.clear
            .frame(width: edgeZoneWidth, height: height)
            .contentShape(Rectangle())
            .gesture(edgeHoldGesture(side: side))
    }

    private func edgeHoldGesture(side: EdgeSide) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !layoutDeck.isHoldingEdge || layoutDeck.edgeHoldSide == side else { return }

                if layoutDeck.edgeHoldSide == nil {
                    layoutDeck.edgeHoldSide = side
                    newRingPreview = CarouselDeck.fresh(laneCount: 3)
                    configureHeights(for: newRingPreview, height: availableHeight)
                    edgeHoldStart = Date()
                    layoutDeck.edgePreviewWidth = 0
                    startEdgeHoldTimer()
                }

                updateEdgePreviewProgress()
            }
            .onEnded { _ in
                stopEdgeHoldTimer()
                guard layoutDeck.edgeHoldSide == side else { return }
                let heldLongEnough = edgeHoldStart.map {
                    Date().timeIntervalSince($0) >= edgeHoldDuration
                } ?? false
                edgeHoldStart = nil

                if heldLongEnough {
                    commitEdgeHold()
                } else {
                    cancelEdgeHold()
                }
            }
    }

    private func startEdgeHoldTimer() {
        stopEdgeHoldTimer()
        edgeHoldTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            updateEdgePreviewProgress()
        }
    }

    private func stopEdgeHoldTimer() {
        edgeHoldTimer?.invalidate()
        edgeHoldTimer = nil
    }

    private func updateEdgePreviewProgress() {
        guard let start = edgeHoldStart, layoutDeck.isHoldingEdge else { return }
        let progress = min(1, Date().timeIntervalSince(start) / edgeHoldDuration)
        layoutDeck.edgePreviewWidth = edgePeekWidth * progress
    }

    private func commitEdgeHold() {
        stopEdgeHoldTimer()
        let w = max(layoutDeck.pageWidth, 1)
        withAnimation(.snappy(duration: 0.25)) {
            layoutDeck.edgePreviewWidth = w
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                let created = layoutDeck.createAndSwitchToNewLayout(laneCount: 3)
                configureHeights(for: created.deck, height: availableHeight)
                layoutDeck.resetEdgeHold()
            }
        }
    }

    private func cancelEdgeHold() {
        stopEdgeHoldTimer()
        withAnimation(.snappy(duration: 0.2)) {
            layoutDeck.edgePreviewWidth = 0
        } completion: {
            layoutDeck.resetEdgeHold()
        }
    }
}

// MARK: - One layout's ring (lanes + pinch/zoom + dividers)

private struct RingDeckView: View {
    var layoutDeck: LayoutDeck? = nil
    let deck: CarouselDeck
    let availableHeight: CGFloat
    var isPreview: Bool
    let cornerRadius: CGFloat
    let horizontalInset: CGFloat
    let dividerHeight: CGFloat
    let minLaneHeight: CGFloat

    @State private var dragStart: (top: CGFloat, bottom: CGFloat)?

    private let maxLanes: Int = 6
    private let addThreshold: CGFloat = 1.2
    private let removeThreshold: CGFloat = 0.83

    private var chromeActive: Bool { layoutDeck?.isChromeActive ?? false }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(deck.lanes.enumerated()), id: \.element.id) { index, lane in
                Group {
                    if isPreview {
                        StaticLaneView(
                            container: lane.current,
                            cornerRadius: cornerRadius,
                            horizontalInset: horizontalInset
                        )
                    } else {
                        CarouselLane(
                            deck: deck,
                            lane: lane,
                            laneIndex: index,
                            layoutDragging: chromeActive,
                            cornerRadius: cornerRadius,
                            horizontalInset: horizontalInset
                        )
                    }
                }
                .frame(height: max(lane.height, minLaneHeight))

                if index < deck.lanes.count - 1 {
                    if isPreview {
                        Color.clear.frame(height: dividerHeight)
                    } else {
                        dividerHandle(index: index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { configureHeightsIfNeeded() }
        .onChange(of: availableHeight) { _, _ in configureHeightsIfNeeded() }
        .simultaneousGesture(isPreview ? nil : magnifyGesture)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.05)
            .onEnded { value in
                guard !chromeActive else { return }
                let y = value.startLocation.y
                if value.magnification >= addThreshold {
                    addLane(nearY: y)
                } else if value.magnification <= removeThreshold {
                    removeLane(nearY: y)
                }
            }
    }

    private func configureHeightsIfNeeded() {
        guard availableHeight > 0, !deck.heightsInitialized else { return }
        let even = deck.lanes.map { _ in CGFloat(1) }
        applyHeights(distribute(desired: even, total: usableHeight(for: deck.lanes.count)))
        deck.heightsInitialized = true
    }

    private func addLane(nearY y: CGFloat) {
        let newCount = deck.lanes.count + 1
        guard newCount <= maxLanes else { return }
        guard usableHeight(for: newCount) >= minLaneHeight * CGFloat(newCount) else { return }
        guard let restored = deck.containerForNewLane() else { return }

        let insertIndex = nearestGapIndex(toY: y)
        var desired = deck.lanes.map { $0.height }
        desired.insert(usableHeight(for: newCount) / CGFloat(newCount), at: insertIndex)

        let newLane = Lane(current: restored)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            deck.lanes.insert(newLane, at: insertIndex)
            applyHeights(distribute(desired: desired, total: usableHeight(for: newCount)))
        }
    }

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
        deck.release(released)
    }

    private func usableHeight(for count: Int) -> CGFloat {
        availableHeight - CGFloat(max(0, count - 1)) * dividerHeight
    }

    private func applyHeights(_ heights: [CGFloat]) {
        guard heights.count == deck.lanes.count else { return }
        for i in deck.lanes.indices { deck.lanes[i].height = heights[i] }
    }

    private func distribute(desired: [CGFloat], total: CGFloat) -> [CGFloat] {
        let n = desired.count
        guard n > 0 else { return [] }
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
                        guard !chromeActive, index + 1 < deck.lanes.count else { return }
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

// MARK: - Lane carousel (within one ring)

private struct StaticLaneView: View {
    let container: ContainerType
    let cornerRadius: CGFloat
    let horizontalInset: CGFloat

    var body: some View {
        Panel(type: container, cornerRadius: cornerRadius)
            .padding(.horizontal, horizontalInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CarouselLane: View {
    let deck: CarouselDeck
    let lane: Lane
    let laneIndex: Int
    var layoutDragging: Bool = false
    let cornerRadius: CGFloat
    let horizontalInset: CGFloat

    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Color.clear
                .onAppear { deck.laneWidth = w }
                .onChange(of: w) { _, width in deck.laneWidth = width }
            let leftEdge = deck.peekLeftEdge(forLaneAt: laneIndex)
            let rightEdge = deck.peekRightEdge(forLaneAt: laneIndex)
            let canLeft = deck.canRetreat(forLaneAt: laneIndex)
            let canRight = deck.canAdvance(forLaneAt: laneIndex)

            ZStack {
                if let leftEdge, canLeft, !layoutDragging {
                    panel(leftEdge, width: w, height: h).offset(x: drag - w)
                }
                if let rightEdge, canRight, !layoutDragging {
                    panel(rightEdge, width: w, height: h).offset(x: drag + w)
                }
                panel(lane.current, width: w, height: h).offset(x: drag)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(swipe(width: w, canLeft: canLeft, canRight: canRight))
        }
    }

    private func panel(_ type: ContainerType, width: CGFloat, height: CGFloat) -> some View {
        Panel(type: type, cornerRadius: cornerRadius)
            .padding(.horizontal, horizontalInset)
            .frame(width: width, height: height)
    }

    private func swipe(width w: CGFloat, canLeft: Bool, canRight: Bool) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !layoutDragging else { return }
                drag = value.translation.width
                if abs(value.translation.width) > 12 {
                    let direction: HorizontalSwipeDirection = value.translation.width < 0 ? .advance : .retreat
                    deck.activeHorizontalDrags[lane.id] = direction
                } else {
                    deck.activeHorizontalDrags.removeValue(forKey: lane.id)
                }
            }
            .onEnded { value in
                guard !layoutDragging else { return }
                deck.activeHorizontalDrags.removeValue(forKey: lane.id)

                let threshold = w * 0.22
                let t = value.translation.width
                if t <= -threshold, canRight {
                    finishSwipe(to: -w) { deck.advance(laneID: lane.id) }
                } else if t >= threshold, canLeft {
                    finishSwipe(to: w) { deck.retreat(laneID: lane.id) }
                } else {
                    withAnimation(.snappy(duration: 0.2)) { drag = 0 }
                }
            }
    }

    private func finishSwipe(to target: CGFloat, apply: @escaping () -> Void) {
        withAnimation(.snappy(duration: 0.25)) {
            drag = target
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                apply()
                drag = 0
            }
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
