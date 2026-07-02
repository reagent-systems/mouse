import SwiftUI

/// Full-screen horizontal pager over multiple rings. Edge strips capture swipes and magnify
/// gestures so ring navigation stays separate from in-lane container swipes.
struct RingNavigator: View {
    @State private var collection = RingCollection()
    @State private var drag: CGFloat = 0
    @State private var screenWidth: CGFloat = 0

    private let edgeWidth: CGFloat = 44
    private let addThreshold: CGFloat = 1.2
    private let removeThreshold: CGFloat = 0.83

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let idx = collection.currentIndex

            ZStack {
                if idx > 0 {
                    ForegroundView(deck: collection.rings[idx - 1])
                        .offset(x: drag - w)
                }
                ForegroundView(deck: collection.rings[idx])
                    .offset(x: drag)
                if idx < collection.rings.count - 1 {
                    ForegroundView(deck: collection.rings[idx + 1])
                        .offset(x: drag + w)
                }
            }
            .frame(width: w, height: h)
            .clipped()

            HStack(spacing: 0) {
                edgeStrip(width: edgeWidth, height: h, isLeft: true, screenWidth: w)
                Spacer()
                edgeStrip(width: edgeWidth, height: h, isLeft: false, screenWidth: w)
            }
            .onAppear { screenWidth = w }
            .onChange(of: w) { _, newW in screenWidth = newW }
        }
        .containerRelativeFrame([.horizontal, .vertical])
    }

    // MARK: - Edge strips

    private func edgeStrip(width: CGFloat, height: CGFloat, isLeft: Bool, screenWidth w: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .highPriorityGesture(swipeGesture(isLeft: isLeft, screenWidth: w))
            .simultaneousGesture(magnifyGesture(isLeft: isLeft))
    }

    // MARK: - Edge swipe (ring navigation)

    private func swipeGesture(isLeft: Bool, screenWidth w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if isLeft {
                    guard value.translation.width >= 0 else { return }
                    drag = value.translation.width
                } else {
                    guard value.translation.width <= 0 else { return }
                    drag = value.translation.width
                }
            }
            .onEnded { value in
                let threshold = w * 0.22
                let t = value.translation.width
                if isLeft, t >= threshold, collection.canRetreat {
                    commit(restingAt: drag - w) { collection.retreat() }
                } else if !isLeft, t <= -threshold, collection.canAdvance {
                    commit(restingAt: drag + w) { collection.advance() }
                } else {
                    withAnimation(.snappy(duration: 0.2)) { drag = 0 }
                }
            }
    }

    // MARK: - Edge magnify (add / remove rings)

    private func magnifyGesture(isLeft: Bool) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.05)
            .onEnded { value in
                if value.magnification >= addThreshold {
                    addRing(after: !isLeft)
                } else if value.magnification <= removeThreshold {
                    removeCurrentRing()
                }
            }
    }

    private func addRing(after: Bool) {
        collection.insertRing(after: after)
        drag = after ? screenWidth : -screenWidth
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25)) { drag = 0 }
        }
    }

    private func removeCurrentRing() {
        guard collection.rings.count > 1 else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            collection.removeCurrentRing()
        }
    }

    /// Move the ring index *immediately*, then animate the slide — same pattern as `CarouselLane.commit`.
    private func commit(restingAt offset: CGFloat, _ move: () -> Void) {
        move()
        drag = offset
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25)) { drag = 0 }
        }
    }
}
