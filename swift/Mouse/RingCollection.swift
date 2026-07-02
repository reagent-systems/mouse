import SwiftUI

/// Holds multiple independent rings (`CarouselDeck` instances) and tracks which one is on screen.
@Observable
final class RingCollection {
    var rings: [CarouselDeck]
    var currentIndex: Int = 0

    init(rings: [CarouselDeck] = [CarouselDeck.demo()]) {
        self.rings = rings
    }

    var current: CarouselDeck { rings[currentIndex] }
    var canRetreat: Bool { currentIndex > 0 }
    var canAdvance: Bool { currentIndex < rings.count - 1 }

    func advance() {
        guard canAdvance else { return }
        currentIndex += 1
    }

    func retreat() {
        guard canRetreat else { return }
        currentIndex -= 1
    }

    /// Insert a fresh demo ring before or after the current one and navigate to it.
    @discardableResult
    func insertRing(after: Bool) -> Int {
        let newRing = CarouselDeck.demo()
        let insertIndex = after ? currentIndex + 1 : currentIndex
        rings.insert(newRing, at: insertIndex)
        currentIndex = insertIndex
        return insertIndex
    }

    func removeRing(at index: Int) {
        guard rings.count > 1, rings.indices.contains(index) else { return }
        rings.remove(at: index)
        if currentIndex >= rings.count {
            currentIndex = rings.count - 1
        } else if index < currentIndex {
            currentIndex -= 1
        }
    }

    func removeCurrentRing() {
        removeRing(at: currentIndex)
    }
}
