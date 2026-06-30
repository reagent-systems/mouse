import SwiftUI

/// Screen-level swipe direction — switches between saved layouts, not ring containers.
enum LayoutSwipeDirection {
    /// Finger moves left — reveal the next layout from the right.
    case next
    /// Finger moves right — reveal the previous layout from the left.
    case previous
}

/// One saved layout: a name plus a complete, independent ring (`CarouselDeck`).
struct LayoutSnapshot: Identifiable {
    let id = UUID()
    var name: String
    var deck: CarouselDeck
}

/// Horizontal pager over saved layouts. Each layout owns its own ring; screen-edge swipes swap
/// layouts without touching container order inside a ring.
@Observable
final class LayoutDeck {
    var layouts: [LayoutSnapshot]
    var currentIndex: Int = 0

    var layoutDragOffset: CGFloat = 0
    var layoutDragDirection: LayoutSwipeDirection?
    var pageWidth: CGFloat = 0

    var isLayoutDragging: Bool { layoutDragDirection != nil }

    init(layouts: [LayoutSnapshot]) {
        self.layouts = layouts
    }

    static func demo() -> LayoutDeck {
        LayoutDeck(layouts: [
            LayoutSnapshot(name: "Layout 1", deck: .demo()),
            LayoutSnapshot(name: "Layout 2", deck: .fresh(laneCount: 4)),
        ])
    }

    var current: LayoutSnapshot { layouts[currentIndex] }

    var canGoPrevious: Bool { currentIndex > 0 }

    /// Swipe past the last layout creates a fresh one.
    func goNext() {
        if currentIndex + 1 < layouts.count {
            currentIndex += 1
        } else {
            layouts.append(LayoutSnapshot(
                name: "Layout \(layouts.count + 1)",
                deck: .fresh(laneCount: 3)
            ))
            currentIndex += 1
        }
    }

    func goPrevious() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    /// Deck shown when peeking the next page (may be a not-yet-committed new layout).
    func deckForNextPeek() -> CarouselDeck? {
        if currentIndex + 1 < layouts.count {
            return layouts[currentIndex + 1].deck
        }
        return nil
    }
}
