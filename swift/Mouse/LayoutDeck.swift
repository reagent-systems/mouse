import SwiftUI

enum EdgeSide {
    case left
    case right
}

/// One saved layout: a name plus a complete, independent ring (`CarouselDeck`).
struct LayoutSnapshot: Identifiable {
    let id = UUID()
    var name: String
    var deck: CarouselDeck
}

/// Owns every saved layout (each with its own ring) and edge-hold chrome state.
@Observable
final class LayoutDeck {
    var layouts: [LayoutSnapshot]
    var currentIndex: Int = 0

    /// Edge being held to draft a new ring; preview grows horizontally from that edge.
    var edgeHoldSide: EdgeSide?
    var edgePreviewWidth: CGFloat = 0
    var pageWidth: CGFloat = 0

    var isHoldingEdge: Bool { edgeHoldSide != nil }
    var isChromeActive: Bool { isHoldingEdge }

    init(layouts: [LayoutSnapshot]) {
        self.layouts = layouts
    }

    static func demo() -> LayoutDeck {
        LayoutDeck(layouts: [
            LayoutSnapshot(name: "Layout 1", deck: .demo()),
        ])
    }

    var current: LayoutSnapshot { layouts[currentIndex] }

    @discardableResult
    func createAndSwitchToNewLayout(laneCount: Int = 3) -> LayoutSnapshot {
        let layout = LayoutSnapshot(
            name: "Layout \(layouts.count + 1)",
            deck: .fresh(laneCount: laneCount)
        )
        layouts.append(layout)
        currentIndex = layouts.count - 1
        return layout
    }

    func resetEdgeHold() {
        edgeHoldSide = nil
        edgePreviewWidth = 0
    }
}
