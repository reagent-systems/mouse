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
/// A one-finger drag starting in a screen-edge strip swipes the whole *ring*: every lane slides off
/// that side together and the neighbouring ring's lanes slide in. If the strip of rings ends on
/// that side, the swipe mints a fresh single-lane ring instead, so edge swipes both create rings
/// and travel back to existing ones.
///
/// Sizing uses `containerRelativeFrame` (measures the real window); a `GeometryReader` here reports
/// an inflated size from the oversized ASCII art sibling in the `ZStack`.
///
/// The strip persists across launches (`StripPersistence`): restored here at init, saved whenever
/// the scene leaves the active phase.
struct ForegroundView: View {
    @State private var strip = StripPersistence.load() ?? RingStrip(rings: [CarouselDeck.onboarding()])
    @Environment(\.scenePhase) private var scenePhase

    /// Edge-swipe lesson state (the onboarding ring's final step): the label flips to
    /// "Edge Swiped." once the drag crosses the commit threshold, and `edgeNudge` drives the
    /// whole stack's idle bounce while the lesson waits.
    @State private var edgeSwiped = false
    @State private var edgeNudge: CGFloat = 0

    private var edgeLessonVisible: Bool {
        strip.rings.contains { $0.isOnboarding && $0.edgeLessonActive }
    }
    @State private var availableHeight: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var didInit = false
    @State private var dragStart: (top: CGFloat, bottom: CGFloat)?

    /// Horizontal offset of the current ring's lane stack during a ring swipe (and its settle).
    @State private var ringDrag: CGFloat = 0
    /// The off-screen ring rendered beside the current one while a ring swipe is in flight.
    @State private var adjacent: AdjacentRing?

    private struct AdjacentRing {
        let ring: CarouselDeck
        let side: RingSide
        /// True while the ring is a candidate that only joins the strip if the swipe commits.
        let isNew: Bool
    }

    private var deck: CarouselDeck { strip.current }

    private let horizontalInset: CGFloat = 24
    private let cornerRadius: CGFloat = 32
    private let dividerHeight: CGFloat = 32
    /// Divider height while a gap-label lesson (Drag?/Spread?) needs the word to fit in the gap.
    private let lessonDividerHeight: CGFloat = 48
    private let minLaneHeight: CGFloat = 80
    private let maxLanes: Int = 6

    private func dividerHeight(for ring: CarouselDeck) -> CGFloat {
        dividerHeight + ring.dividerBoost
    }

    /// The side gutters widen during the edge lesson so the rotated word fits beside the lanes.
    private func inset(for ring: CarouselDeck) -> CGFloat {
        ring.isOnboarding && ring.edgeLessonActive ? 40 : horizontalInset
    }
    /// Width of the screen-edge strips that capture ring swipes instead of lane swipes.
    private let edgeZoneWidth: CGFloat = 32

    /// Final magnification above which a spread counts as "zoom → add a lane".
    private let addThreshold: CGFloat = 1.2
    /// Final magnification below which a squeeze counts as "pinch → remove a lane".
    private let removeThreshold: CGFloat = 0.83

    var body: some View {
        ZStack {
            if let adjacent {
                laneStack(for: adjacent.ring)
                    .offset(x: ringDrag + (adjacent.side == .right ? availableWidth : -availableWidth))
            }
            laneStack(for: deck)
                .offset(x: ringDrag + edgeNudge)
        }
        .containerRelativeFrame([.horizontal, .vertical]) { length, axis in
            if axis == .vertical, availableHeight != length {
                DispatchQueue.main.async { configure(for: length) }
            }
            if axis == .horizontal, availableWidth != length {
                DispatchQueue.main.async { availableWidth = length }
            }
            return length
        }
        .simultaneousGesture(magnifyGesture)
        .overlay(alignment: .leading) { edgeStrip(.left) }
        .overlay(alignment: .trailing) { edgeStrip(.right) }
        .task(id: edgeLessonVisible) { await runEdgeLessonNudge() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                FileBuffer.flushAll()  // pending edits in every open buffer, any ring
                StripPersistence.save(strip)
            }
        }
    }

    /// Bring a ring's divider boost in line with its lessons and re-fit lane heights, in ONE
    /// animation transaction — divider growth and the compensating lane shrink interpolate
    /// together, so the stack's total height never visibly wavers.
    private func refitLanes(in ring: CarouselDeck) {
        let targetBoost: CGFloat = ring.hasGapLabelLesson ? lessonDividerHeight - dividerHeight : 0
        let total = availableHeight - CGFloat(max(0, ring.lanes.count - 1)) * (dividerHeight + targetBoost)
        let sumOff = abs(ring.lanes.map(\.height).reduce(0, +) - total) > 0.5
        guard ring.dividerBoost != targetBoost || sumOff else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            ring.dividerBoost = targetBoost
            applyHeights(distribute(desired: ring.lanes.map { max($0.height, 1) }, total: total), to: ring)
        }
    }

    /// Idle bounce for the edge-swipe lesson: the whole lane stack nudges toward the edge, the
    /// way the lesson wants to be pulled. Skips while any ring drag or transition is in flight.
    private func runEdgeLessonNudge() async {
        withAnimation(.spring(duration: 0.3)) { edgeNudge = 0 }
        guard edgeLessonVisible else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, ringDrag == 0, adjacent == nil else { continue }
            withAnimation(.spring(duration: 0.4)) { edgeNudge = -16 }
            try? await Task.sleep(for: .seconds(0.45))
            withAnimation(.spring(duration: 0.35)) { edgeNudge = 0 }
            try? await Task.sleep(for: .seconds(0.4))
        }
    }

    private func laneStack(for ring: CarouselDeck) -> some View {
        let ringInset = inset(for: ring)
        return VStack(spacing: 0) {
            ForEach(Array(ring.lanes.enumerated()), id: \.element.id) { index, lane in
                CarouselLane(
                    deck: ring,
                    lane: lane,
                    cornerRadius: cornerRadius,
                    horizontalInset: ringInset,
                    onDeckReshaped: { refitLanes(in: ring) }
                )
                .frame(height: lane.height)
                .transition(.scale.combined(with: .opacity))

                if index < ring.lanes.count - 1 {
                    dividerHandle(ring: ring, index: index)
                }
            }
        }
        // The edge lesson's label belongs to this ring's edge: rendered inside the stack, it
        // moves with everything the ring does — the idle nudge and the swipe that drags it away.
        .overlay(alignment: .trailing) {
            if ring.isOnboarding && ring.edgeLessonActive {
                Text(edgeSwiped ? "Edge Swiped." : "Edge Swipe?")
                    .font(.custom(AppFont.asciiName, size: 28))
                    .foregroundStyle(.black)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 40)
                    .allowsHitTesting(false)
            }
        }
        // Each lane also renders the ring's reserve edge panels a screen-width to either side.
        // Clip them to the stack so they can't surface when the whole stack slides during a ring
        // swipe (clip before the outer `.offset`, so the window travels with the stack).
        .clipped()
    }

    // MARK: - Ring swipe (edge gesture: slide to or create a neighbouring ring)

    private func edgeStrip(_ side: RingSide) -> some View {
        Color.clear
            .frame(width: edgeZoneWidth)
            .contentShape(Rectangle())
            .gesture(ringSwipe(from: side))
    }

    private func ringSwipe(from side: RingSide) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard availableWidth > 0 else { return }
                if edgeNudge != 0 { withAnimation(.easeOut(duration: 0.15)) { edgeNudge = 0 } }
                if adjacent == nil { adjacent = makeAdjacent(side) }
                guard let adjacent, adjacent.side == side else { return }
                let t = value.translation.width
                // Only allow pulling the neighbour on; the far direction pins at rest.
                ringDrag = side == .right ? min(0, t) : max(0, t)
                // The edge lesson's label flips the moment the user is clearly doing it.
                if strip.current.isOnboarding {
                    edgeSwiped = abs(ringDrag) >= availableWidth * 0.22
                }
            }
            .onEnded { value in
                guard let adj = adjacent, adj.side == side else { return }
                let threshold = availableWidth * 0.22
                let t = value.translation.width
                let crossed = side == .right ? t <= -threshold : t >= threshold
                if crossed {
                    commitRingSwitch(to: adj)
                } else {
                    edgeSwiped = false
                    withAnimation(.snappy(duration: 0.2), completionCriteria: .logicallyComplete) {
                        ringDrag = 0
                    } completion: {
                        adjacent = nil
                    }
                }
            }
    }

    /// The ring that slides in from `side`: the strip's existing neighbour if there is one,
    /// otherwise a fresh single-lane ring. Created up front so it can render during the drag; a
    /// fresh ring only joins the strip if the swipe commits.
    private func makeAdjacent(_ side: RingSide) -> AdjacentRing {
        if let existing = strip.neighbor(on: side) {
            // Re-fit in case the window (or its lesson state) changed while it was off screen.
            refitLanes(in: existing)
            return AdjacentRing(ring: existing, side: side, isNew: false)
        }
        let fresh = CarouselDeck.fresh()
        fresh.lanes[0].height = usableHeight(for: 1, in: fresh)
        return AdjacentRing(ring: fresh, side: side, isNew: true)
    }

    private func commitRingSwitch(to adj: AdjacentRing) {
        let outgoing = strip.current
        if adj.isNew {
            // A new ring is only mintable past the strip's end, so on the left the insertion index
            // is the current index (0) and `currentIndex` already points at it after the insert.
            strip.rings.insert(adj.ring, at: adj.side == .right ? strip.currentIndex + 1 : strip.currentIndex)
            if adj.side == .right { strip.currentIndex += 1 }
        } else {
            strip.currentIndex += adj.side == .right ? 1 : -1
        }
        // Same two-pass trick as CarouselLane.commit: swap identities with offsets that keep both
        // stacks visually stationary, let SwiftUI render that, then glide everything to rest.
        adjacent = AdjacentRing(ring: outgoing, side: adj.side.opposite, isNew: false)
        ringDrag += adj.side == .right ? availableWidth : -availableWidth
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25), completionCriteria: .logicallyComplete) {
                ringDrag = 0
            } completion: {
                adjacent = nil
                // Edge-swiping away from the onboarding ring is its graduation: the ring
                // retires once it has fully slid off.
                if outgoing.isOnboarding {
                    edgeSwiped = false
                    if let idx = strip.rings.firstIndex(where: { $0 === outgoing }) {
                        strip.rings.remove(at: idx)
                        if idx < strip.currentIndex { strip.currentIndex -= 1 }
                    }
                }
            }
        }
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
        guard usableHeight(for: newCount, in: deck) >= minLaneHeight * CGFloat(newCount) else { return }
        // The spread lesson supplies the pinch lesson as the new lane and completes itself;
        // otherwise a new lane pulls a container off the ring (restoring the last removed lane's
        // container if it's still there) and bails if the whole ring is already on screen.
        let newContainer: ContainerType
        if let spread = deck.pendingSpreadLesson {
            spread.content.done = true
            // The new lane arrives blank; the pinch lesson only steps in after "Spread." has
            // left the stage, so lessons never share a moment.
            let placeholder = ContainerType.onboardingBlank()
            newContainer = placeholder
            deck.pinchLessonStaged = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [deck] in
                withAnimation(.snappy(duration: 0.3)) { deck.morphDoneSpreadIntoBlank() }
                refitLanes(in: deck)  // dividers shrink back; same-flush so the total holds
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [deck] in
                withAnimation(.snappy(duration: 0.3)) { deck.placePinchLesson(replacing: placeholder.id) }
            }
        } else {
            guard let restored = deck.containerForNewLane() else { return }
            newContainer = restored
        }

        let insertIndex = nearestGapIndex(toY: y)
        var desired = deck.lanes.map { $0.height }
        // The new lane claims an even share; neighbours shrink proportionally to make room.
        desired.insert(usableHeight(for: newCount, in: deck) / CGFloat(newCount), at: insertIndex)

        let newLane = Lane(current: newContainer)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            deck.lanes.insert(newLane, at: insertIndex)
            applyHeights(distribute(desired: desired, total: usableHeight(for: newCount, in: deck)), to: deck)
        }
    }

    /// Remove the lane whose center is closest to `y`; remaining lanes grow to refill the space.
    private func removeLane(nearY y: CGFloat) {
        // Pinching the LAST lane closes the whole ring (the strip's counterpart to edge swipes
        // creating rings). The onboarding ring is exempt — its lessons manage their own lanes.
        guard deck.lanes.count > 1 else {
            removeCurrentRing()
            return
        }
        let removeIndex = nearestLaneIndex(toY: y)
        let released = deck.lanes[removeIndex].current
        let isPinchLesson = released.kind == ContainerType.pinchPresetKind
        // The pinch lesson flips to "Pinched." and holds for a beat before collapsing — and it
        // does not return to the ring; pinching it closed is how it leaves.
        if isPinchLesson { released.content.done = true }

        let perform = { [deck] in
            guard let index = deck.lanes.firstIndex(where: { $0.current.id == released.id }),
                  deck.lanes.count > 1 else { return }
            let newCount = deck.lanes.count - 1
            var desired = deck.lanes.map { $0.height }
            desired.remove(at: index)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                deck.lanes.remove(at: index)
                applyHeights(distribute(desired: desired, total: usableHeight(for: newCount, in: deck)), to: deck)
            }
            if !isPinchLesson { deck.release(released) }
        }
        if isPinchLesson {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { perform() }
        } else {
            perform()
        }
    }

    /// Remove the current ring from the strip, landing on its left neighbour. The strip always
    /// keeps at least one ring: removing the final one replaces it with a fresh ring.
    private func removeCurrentRing() {
        guard !deck.isOnboarding else { return }
        let removed = strip.currentIndex
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            strip.rings.remove(at: removed)
            if strip.rings.isEmpty {
                strip.rings = [CarouselDeck.fresh()]
                strip.currentIndex = 0
            } else {
                strip.currentIndex = min(max(removed - 1, 0), strip.rings.count - 1)
            }
        }
        // The ring we landed on (or the fresh one) fits itself to the current window.
        refitLanes(in: deck)
    }

    // MARK: - Height bookkeeping (keeps the deck filling `availableHeight`)

    private func configure(for height: CGFloat) {
        let previous = availableHeight
        availableHeight = height
        if didInit {
            // iPad rotation or a multitasking resize changed the window: re-fit the current ring
            // proportionally (off-screen rings re-fit when they next slide in, via makeAdjacent).
            if abs(previous - height) > 0.5 { refitLanes(in: deck) }
            return
        }
        // A restored ring may come back mid-lesson; its divider boost is view policy, so it's
        // re-derived here rather than persisted.
        deck.dividerBoost = deck.hasGapLabelLesson ? lessonDividerHeight - dividerHeight : 0
        // Fresh lanes carry height 0, so they get an even split; lanes restored from a previous
        // run keep their proportions, re-fit to this window's height.
        let desired = deck.lanes.map { max($0.height, 1) }
        applyHeights(distribute(desired: desired, total: usableHeight(for: deck.lanes.count, in: deck)), to: deck)
        didInit = true
    }

    /// Height available to lanes once the dividers between `count` lanes are subtracted.
    private func usableHeight(for count: Int, in ring: CarouselDeck) -> CGFloat {
        availableHeight - CGFloat(max(0, count - 1)) * dividerHeight(for: ring)
    }

    private func applyHeights(_ heights: [CGFloat], to ring: CarouselDeck) {
        guard heights.count == ring.lanes.count else { return }
        for i in ring.lanes.indices { ring.lanes[i].height = heights[i] }
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
        let dh = dividerHeight(for: deck)
        var offsets: [CGFloat] = [0]
        var cursor: CGFloat = 0
        for (i, lane) in deck.lanes.enumerated() {
            cursor += lane.height
            if i < deck.lanes.count - 1 {
                offsets.append(cursor + dh / 2)
                cursor += dh
            } else {
                offsets.append(cursor)
            }
        }
        return offsets.enumerated().min { abs($0.element - y) < abs($1.element - y) }?.offset ?? 0
    }

    /// Index of the lane whose vertical center is closest to `y`.
    private func nearestLaneIndex(toY y: CGFloat) -> Int {
        let dh = dividerHeight(for: deck)
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
            cursor += lane.height + dh
        }
        return bestIndex
    }

    private func dividerHandle(ring: CarouselDeck, index: Int) -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: dividerHeight(for: ring))
            .contentShape(Rectangle())
            .padding(.horizontal, inset(for: ring))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard index + 1 < ring.lanes.count else { return }
                        let start = dragStart ?? (ring.lanes[index].height, ring.lanes[index + 1].height)
                        if dragStart == nil { dragStart = start }

                        let delta = value.translation.height
                        // The drag lesson's label flips mid-gesture, as soon as this is clearly
                        // a drag rather than a touch.
                        if abs(delta) > 20 { ring.markDragLessonDone() }
                        let newTop = start.top + delta
                        let newBottom = start.bottom - delta
                        guard newTop >= minLaneHeight, newBottom >= minLaneHeight else { return }
                        ring.lanes[index].height = newTop
                        ring.lanes[index + 1].height = newBottom
                    }
                    .onEnded { _ in
                        dragStart = nil
                        // A finished drag lesson lingers as "Dragged." for a beat, then morphs
                        // into the spread lesson — its half of the zoom teaching.
                        if ring.hasDoneDragLesson {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                withAnimation(.snappy(duration: 0.3)) { ring.morphDoneDragIntoSpread() }
                            }
                        }
                    }
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
    /// Called right after a commit mutates the ring, in the same update — the owner re-fits lane
    /// heights if the mutation changed divider heights (lesson arriving/leaving).
    var onDeckReshaped: (() -> Void)? = nil

    /// Animatable vertical lift for the drag lesson's word: rides every transaction that moves
    /// the taught boundary, exactly like the panels' scale effects do.
    private struct VerticalLift: GeometryEffect {
        var lift: CGFloat
        var animatableData: CGFloat {
            get { lift }
            set { lift = newValue }
        }
        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(CGAffineTransform(translationX: 0, y: -lift))
        }
    }

    @State private var drag: CGFloat = 0
    /// Which axis this drag locked to at first movement (the gesture-law arbiter).
    @State private var dragAxis: DragAxis = .undecided
    /// True from the moment a swipe locks horizontal until its settle animation finishes. Edge
    /// panels render only while this is set: at rest each lane costs ONE live panel, not three.
    /// Real containers (trees, editors, graphs) are heavy, and every lane previews the same
    /// reserve edges — mounting them all permanently multiplied the whole ring's view count by
    /// three (and an edge swipe, which renders a second ring, by six).
    @State private var edgesMounted = false

    private enum DragAxis { case undecided, horizontal, vertical }
    /// Idle-bounce offset, driven by `runIdleBounce`. Kept separate from `drag` and always summed
    /// into the offset, so a drag can take over mid-nudge with no jump.
    @State private var nudge: CGSize = .zero
    /// Idle shrink-pulse scale (the pinch lesson's hint).
    @State private var pulse: CGFloat = 1

    /// Restarts the bounce task when the lane shows a different container, or the container's
    /// idle behavior changes, or its lesson completes (done lessons stop idling).
    private struct BounceKey: Equatable {
        let container: ContainerType.ID
        let idle: IdleAnimation
        let done: Bool
    }

    /// One visible panel: the lane's current container or a reserve/preview edge beside it.
    private struct SlotEntry {
        let container: ContainerType
        /// Where the panel rests relative to the lane (−w left edge, 0 current, +w right edge).
        let restingOffset: CGFloat
        let isCurrent: Bool
    }

    /// The visible trio, deduplicated by container id (a one-container reserve is both edges;
    /// `ForEach` identity must stay unique). At rest only the current panel is realized; the
    /// edges join when a swipe starts and leave once it settles. The current container keeps its
    /// identity through a commit either way, so the no-reload-flash guarantee is untouched — an
    /// incoming edge mounts at the first drag tick, while it's still a full width off screen.
    private func slotEntries(width w: CGFloat) -> [SlotEntry] {
        guard edgesMounted else {
            return [SlotEntry(container: lane.current, restingOffset: 0, isCurrent: true)]
        }
        // A preset lane previews its chain successor at both edges (that's what a swipe will
        // bring in — two distinct preview instances); ordinary lanes preview the reserve edges.
        let leftEdge = ContainerType.fillIn(after: lane.current) ?? deck.reserve.last
        let rightEdge = ContainerType.fillIn(after: lane.current) ?? deck.reserve.first
        var entries: [SlotEntry] = []
        if let leftEdge {
            entries.append(SlotEntry(container: leftEdge, restingOffset: -w, isCurrent: false))
        }
        if let rightEdge, rightEdge.id != leftEdge?.id {
            entries.append(SlotEntry(container: rightEdge, restingOffset: w, isCurrent: false))
        }
        // Current goes last so it draws above the edges. Never a duplicate: an instance lives in
        // exactly one place (a lane or the reserve).
        entries.append(SlotEntry(container: lane.current, restingOffset: 0, isCurrent: true))
        return entries
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let spreadRole = deck.gapRole(of: lane.id, lessonKind: ContainerType.spreadPresetKind)
            let dragRole = deck.gapRole(of: lane.id, lessonKind: ContainerType.dragPresetKind)

            ZStack {
                // Identity follows the CONTAINER, not the slot: when a commit moves a container
                // between slots (edge preview → current → outgoing edge), the same view instance
                // just changes offset, keeping its loaded state — no unload flash at release.
                // One uniform modifier chain for every slot, so identity survives the move.
                ForEach(slotEntries(width: w), id: \.container.id) { entry in
                    panel(entry.container, width: w, height: h)
                        .scaleEffect(entry.isCurrent ? pulse : 1)
                        // Spread: both sides of the gap retreat in OPPOSITE directions.
                        .scaleEffect(x: 1, y: entry.isCurrent && spreadRole == .lesson ? deck.spreadPulse : 1, anchor: .bottom)
                        .scaleEffect(x: 1, y: entry.isCurrent && spreadRole == .above ? deck.spreadPulse : 1, anchor: .top)
                        // Drag: both sides move the SAME direction (the boundary itself travels).
                        .scaleEffect(x: 1, y: entry.isCurrent && dragRole == .lesson ? (h + deck.dragPulse) / max(h, 1) : 1, anchor: .bottom)
                        .scaleEffect(x: 1, y: entry.isCurrent && dragRole == .above ? (h - deck.dragPulse) / max(h, 1) : 1, anchor: .top)
                        .offset(
                            x: drag + (entry.isCurrent ? nudge.width : entry.restingOffset),
                            y: entry.isCurrent ? nudge.height : 0
                        )
                }

                if lane.current.usesGapLabel {
                    // The drag lesson's word rides the boundary as it travels; the spread word
                    // holds still while its gap breathes. Both ride real swipes. Explicit black:
                    // the gap shows the app's light background regardless of system appearance.
                    let labelLift = lane.current.kind == ContainerType.dragPresetKind ? deck.dragPulse : 0
                    Text(lane.current.displayTitle)
                        .font(.custom(AppFont.asciiName, size: 28))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .offset(x: drag, y: -42)
                        // The lift goes through a GeometryEffect so it interpolates on the same
                        // Animatable machinery as the panels' scale effects — a parallel offset
                        // could miss the pulse's first return leg.
                        .modifier(VerticalLift(lift: labelLift))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            // Gutter changes (edge lesson) glide instead of popping.
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: horizontalInset)
            // Simultaneous, because UIScrollView-backed content (Files tree, Viewer) claims every
            // drag if we merely queue behind it. The gesture enforces the law itself: it locks to
            // an axis at first movement and stands down for vertical drags, so content scrolls
            // vertically while horizontal swipes move the lane — from anywhere on the container.
            .simultaneousGesture(swipe(
                width: w,
                hasLeft: ContainerType.fillIn(after: lane.current) != nil || !deck.reserve.isEmpty,
                hasRight: ContainerType.fillIn(after: lane.current) != nil || !deck.reserve.isEmpty
            ))
            .task(id: BounceKey(
                container: lane.current.id,
                idle: lane.current.idle,
                done: lane.current.content.done
            )) {
                await runIdleBounce()
            }
        }
    }

    /// Drives the container's idle animation by hand (rather than `phaseAnimator`) so the gesture
    /// can ease an in-flight nudge back to zero instead of dropping it instantly: dwell at rest,
    /// a small two-beat spring, settle, repeat. Skips while a drag is in flight, and stops for
    /// good once the container's lesson is done.
    private func runIdleBounce() async {
        withAnimation(.spring(duration: 0.3)) {
            nudge = .zero
            pulse = 1
        }
        let idle = lane.current.idle
        if idle == .gapBreathe { deck.spreadPulse = 1 }
        if idle == .gapReach { deck.dragPulse = 0 }
        guard !lane.current.content.done, idle != .none else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, drag == 0 else { continue }
            switch idle {
            case .none:
                return
            case .horizontalBounce:
                withAnimation(.spring(duration: 0.4)) { nudge = CGSize(width: -22, height: 0) }
                try? await Task.sleep(for: .seconds(0.45))
                if drag == 0, !Task.isCancelled {
                    withAnimation(.spring(duration: 0.4)) { nudge = CGSize(width: 16, height: 0) }
                    try? await Task.sleep(for: .seconds(0.45))
                }
                withAnimation(.spring(duration: 0.35)) { nudge = .zero }
            case .gapReach:
                // Shared pulse in points: the taught boundary shifts up ~10pt — both neighbours
                // follow the same direction. Symmetric springs keep word and edge in lockstep.
                withAnimation(.spring(duration: 0.4)) { deck.dragPulse = 10 }
                try? await Task.sleep(for: .seconds(0.45))
                withAnimation(.spring(duration: 0.4)) { deck.dragPulse = 0 }
            case .shrinkPulse:
                withAnimation(.spring(duration: 0.4)) { pulse = 0.93 }
                try? await Task.sleep(for: .seconds(0.45))
                withAnimation(.spring(duration: 0.35)) { pulse = 1 }
            case .gapBreathe:
                // Shared pulse: both sides of the gap retreat together.
                withAnimation(.spring(duration: 0.4)) { deck.spreadPulse = 0.95 }
                try? await Task.sleep(for: .seconds(0.45))
                withAnimation(.spring(duration: 0.35)) { deck.spreadPulse = 1 }
            }
            try? await Task.sleep(for: .seconds(0.4))
        }
    }

    private func panel(_ type: ContainerType, width: CGFloat, height: CGFloat) -> some View {
        Panel(type: type, cornerRadius: cornerRadius, deck: deck)
            .padding(.horizontal, horizontalInset)
            .frame(width: width, height: height)
    }

    private func swipe(width w: CGFloat, hasLeft: Bool, hasRight: Bool) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Lock the drag to an axis at first movement: horizontal-dominant drags are lane
                // swipes; vertical-dominant drags belong to the content (tree/file scrolling) and
                // this gesture stands down for their whole duration.
                if dragAxis == .undecided {
                    dragAxis = abs(value.translation.width) >= abs(value.translation.height)
                        ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                if !edgesMounted { edgesMounted = true }
                if nudge != .zero { withAnimation(.easeOut(duration: 0.15)) { nudge = .zero } }
                if deck.spreadPulse != 1 { withAnimation(.easeOut(duration: 0.15)) { deck.spreadPulse = 1 } }
                if deck.dragPulse != 0 { withAnimation(.easeOut(duration: 0.15)) { deck.dragPulse = 0 } }
                drag = value.translation.width
                // The swipe lesson's label flips to "Swiped." the moment the drag would commit
                // (and back, if the user retreats below the threshold).
                if lane.current.kind == ContainerType.swipePresetKind {
                    lane.current.content.done = abs(drag) >= w * 0.22
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = .undecided
                guard axis == .horizontal else { return }
                let threshold = w * 0.22
                let t = value.translation.width
                // The swipe preset retires once swiped away (after the slide settles); other
                // presets stay on the ring.
                let retiring = lane.current.kind == ContainerType.swipePresetKind ? lane.current.id : nil
                if t <= -threshold, hasRight {
                    commit(restingAt: drag + w, retiring: retiring) { deck.advance(laneID: lane.id) }
                } else if t >= threshold, hasLeft {
                    commit(restingAt: drag - w, retiring: retiring) { deck.retreat(laneID: lane.id) }
                } else {
                    withAnimation(.snappy(duration: 0.2), completionCriteria: .logicallyComplete) {
                        drag = 0
                    } completion: {
                        // Skip the unmount if a fresh drag took over mid-settle.
                        if drag == 0 { edgesMounted = false }
                    }
                }
            }
    }

    /// Move the container on the ring *immediately* (so what's shown is never stale, even when the
    /// user out-swipes the animation), then animate the slide in a second render pass: the incoming
    /// container already sits at `restingAt`, so we keep it there and glide it to center. The `async`
    /// hop guarantees SwiftUI renders the resting position before animating from it, so the swap is
    /// invisible and a fast follow-up swipe can never reveal the previous container.
    ///
    /// A `retiring` container is removed from the reserve only after the slide settles — during the
    /// slide it's still partially on screen as the outgoing edge panel, so dropping it sooner would
    /// swap its identity mid-exit.
    private func commit(restingAt offset: CGFloat, retiring: ContainerType.ID? = nil, _ move: () -> Void) {
        move()
        onDeckReshaped?()
        drag = offset
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25), completionCriteria: .logicallyComplete) {
                drag = 0
            } completion: {
                if let retiring { deck.removeFromReserve(retiring) }
                // Skip the unmount if a fresh drag took over mid-settle (out-swiping the
                // animation); the new gesture's own settle handles it.
                if drag == 0 { edgesMounted = false }
            }
        }
    }
}

struct Panel: View {
    let type: ContainerType
    let cornerRadius: CGFloat
    /// The ring this panel belongs to, for containers that are windows onto its workspace.
    var deck: CarouselDeck? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(type.color)
            .overlay {
                // Gap-label lessons render their label in the lane (outside the container, so it
                // doesn't move with idle animations); the panel itself stays blank for those.
                if type.kind == ContainerType.gitHubKind {
                    GitHubSignInView()
                } else if type.kind == ContainerType.filesKind, let deck {
                    FilesContainerView(deck: deck)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else if type.kind == ContainerType.viewerKind {
                    ViewerContainerView(deck: deck)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else if type.kind == ContainerType.graphKind {
                    GitGraphContainerView(workspace: deck?.workspace)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else if type.kind == ContainerType.terminalKind {
                    TerminalContainerView(deck: deck)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else if !type.usesGapLabel {
                    Text(type.displayTitle)
                        .font(type.isOnboardingPreset
                            ? .custom(AppFont.asciiName, size: 28)
                            : .system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                // Presets read as instructional, not content: outlined instead of filled color.
                if type.isOnboardingPreset {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                // The container action stack: icons appear as their prerequisites are met.
                // Nudged slightly further off the right edge than the top, by request.
                if !type.isOnboardingPreset, let deck {
                    ContainerActionsRow(deck: deck, cornerRadius: cornerRadius)
                        .padding(.top, ContainerActionsRow.inset)
                        .padding(.trailing, ContainerActionsRow.inset + 8)
                }
            }
    }
}

#Preview {
    ContentView()
}
