import SwiftUI

/// A container instance on the ring. Identity is per-instance (`id`); `kind` says which catalog
/// type it is, so the ring may hold several instances of the same `kind` (e.g. six 6's). An
/// instance lives in exactly one place at a time: a lane, or the off-screen reserve.
struct ContainerType: Identifiable {
    let id = UUID()
    let kind: Int
    let title: String
    let color: Color
}

/// One on-screen spot in the ring window. A lane holds whichever container currently sits in it.
struct Lane: Identifiable {
    let id = UUID()
    var current: ContainerType
    var height: CGFloat = 0
}

enum HorizontalSwipeDirection {
    /// Finger moves left — pull the right-edge container into the lane.
    case advance
    /// Finger moves right — pull the left-edge container into the lane.
    case retreat
}

/// The whole thing is a single circular ring. The screen is a window over it, split into `lanes`
/// spots; everything else is the off-screen `reserve`. The reserve is ordered so `first` sits just
/// off the RIGHT edge of the screen and `last` sits just off the LEFT edge. Every lane pulls from
/// and pushes to these same two edges, so a container pushed off one lane can be grabbed by any
/// lane — shuffling is allowed.
@Observable
final class CarouselDeck {
    var lanes: [Lane]
    var reserve: [ContainerType]
    /// LIFO of removed lanes' container ids, so re-adding a lane restores the last one removed.
    var removedStack: [ContainerType.ID] = []

    /// Lanes currently mid-horizontal-drag. Advance preloads top-to-bottom; retreat bottom-to-top.
    var activeHorizontalDrags: [Lane.ID: HorizontalSwipeDirection] = [:]

    /// When set, every lane follows this shared edge drag (all containers move at once).
    var edgeDragOffset: CGFloat = 0
    var edgeDragDirection: HorizontalSwipeDirection?
    /// Measured lane width; used to animate edge drags to a full commit position.
    var laneWidth: CGFloat = 0

    init(lanes: [Lane], reserve: [ContainerType]) {
        self.lanes = lanes
        self.reserve = reserve
    }

    static func demo() -> CarouselDeck {
        let all = ContainerType.demoPool()
        let lanes = all.prefix(3).map { Lane(current: $0) }
        return CarouselDeck(lanes: Array(lanes), reserve: Array(all.dropFirst(3)))
    }

    func laneIndex(for id: Lane.ID) -> Int? {
        lanes.firstIndex { $0.id == id }
    }

    // MARK: - Ring moves

    /// Swipe-left commit: pull the right-edge container into the lane, push the old one off the left.
    func advance(laneID: Lane.ID) {
        guard let i = lanes.firstIndex(where: { $0.id == laneID }), !reserve.isEmpty else { return }
        let incoming = reserve.removeFirst()
        let outgoing = lanes[i].current
        lanes[i].current = incoming
        reserve.append(outgoing)
    }

    /// Swipe-right commit: pull the left-edge container into the lane, push the old one off the right.
    func retreat(laneID: Lane.ID) {
        guard let i = lanes.firstIndex(where: { $0.id == laneID }), !reserve.isEmpty else { return }
        let incoming = reserve.removeLast()
        let outgoing = lanes[i].current
        lanes[i].current = incoming
        reserve.insert(outgoing, at: 0)
    }

    /// Move every lane in top-to-bottom order (edge drag commit). Applied atomically so SwiftUI
    /// never renders a half-advanced ring.
    func advanceAll() {
        var simReserve = reserve
        var simLanes = lanes
        for i in simLanes.indices {
            guard !simReserve.isEmpty else { break }
            let incoming = simReserve.removeFirst()
            let outgoing = simLanes[i].current
            simLanes[i].current = incoming
            simReserve.append(outgoing)
        }
        lanes = simLanes
        reserve = simReserve
    }

    /// Bottom-to-top — the inverse of `advanceAll`. Applied atomically for the same reason.
    func retreatAll() {
        var simReserve = reserve
        var simLanes = lanes
        for i in stride(from: simLanes.count - 1, through: 0, by: -1) {
            guard !simReserve.isEmpty else { break }
            let incoming = simReserve.removeLast()
            let outgoing = simLanes[i].current
            simLanes[i].current = incoming
            simReserve.insert(outgoing, at: 0)
        }
        lanes = simLanes
        reserve = simReserve
    }

    // MARK: - Preload / peek

    /// Right-edge container this lane would pull if it commits an advance now, accounting for
    /// higher-priority lanes above it that are already dragging or bulk edge-dragging.
    func peekRightEdge(forLaneAt index: Int) -> ContainerType? {
        simulatedRing(forLaneAt: index, direction: .advance, bulkDirection: edgeDragDirection).reserve.first
    }

    /// Left-edge container this lane would pull if it commits a retreat now.
    func peekLeftEdge(forLaneAt index: Int) -> ContainerType? {
        simulatedRing(forLaneAt: index, direction: .retreat, bulkDirection: edgeDragDirection).reserve.last
    }

    func canAdvance(forLaneAt index: Int) -> Bool {
        !simulatedRing(forLaneAt: index, direction: .advance, bulkDirection: edgeDragDirection).reserve.isEmpty
    }

    func canRetreat(forLaneAt index: Int) -> Bool {
        !simulatedRing(forLaneAt: index, direction: .retreat, bulkDirection: edgeDragDirection).reserve.isEmpty
    }

    /// Simulate ring state after all higher-priority pending operations for this direction run first.
    /// Advance commits top-to-bottom; retreat commits bottom-to-top.
    private func simulatedRing(
        forLaneAt index: Int,
        direction: HorizontalSwipeDirection,
        bulkDirection: HorizontalSwipeDirection?
    ) -> (reserve: [ContainerType], laneContents: [ContainerType]) {
        var simReserve = reserve
        var simLanes = lanes.map(\.current)

        if bulkDirection == direction {
            switch direction {
            case .advance:
                for i in 0..<index {
                    applySimulated(direction: .advance, laneIndex: i, reserve: &simReserve, lanes: &simLanes)
                }
            case .retreat:
                for i in stride(from: lanes.count - 1, through: index + 1, by: -1) {
                    applySimulated(direction: .retreat, laneIndex: i, reserve: &simReserve, lanes: &simLanes)
                }
            }
            return (simReserve, simLanes)
        }

        let pending = activeHorizontalDrags.compactMap { id, dir -> (Int, HorizontalSwipeDirection)? in
            guard let idx = laneIndex(for: id), dir == direction else { return nil }
            return (idx, dir)
        }

        switch direction {
        case .advance:
            for (idx, _) in pending.filter({ $0.0 < index }).sorted(by: { $0.0 < $1.0 }) {
                applySimulated(direction: .advance, laneIndex: idx, reserve: &simReserve, lanes: &simLanes)
            }
        case .retreat:
            for (idx, _) in pending.filter({ $0.0 > index }).sorted(by: { $0.0 > $1.0 }) {
                applySimulated(direction: .retreat, laneIndex: idx, reserve: &simReserve, lanes: &simLanes)
            }
        }

        return (simReserve, simLanes)
    }

    private func applySimulated(
        direction: HorizontalSwipeDirection,
        laneIndex: Int,
        reserve: inout [ContainerType],
        lanes: inout [ContainerType]
    ) {
        guard !reserve.isEmpty else { return }
        switch direction {
        case .advance:
            let incoming = reserve.removeFirst()
            let outgoing = lanes[laneIndex]
            lanes[laneIndex] = incoming
            reserve.append(outgoing)
        case .retreat:
            let incoming = reserve.removeLast()
            let outgoing = lanes[laneIndex]
            lanes[laneIndex] = incoming
            reserve.insert(outgoing, at: 0)
        }
    }

    // MARK: - Lane add/remove

    /// The container a newly-added lane should show: the most recently removed lane's container if
    /// it's still on the ring, otherwise the right-edge container. Removes it from the reserve.
    /// Returns `nil` only if the ring is fully on screen (nothing left to pull).
    func containerForNewLane() -> ContainerType? {
        while let lastID = removedStack.popLast() {
            if let idx = reserve.firstIndex(where: { $0.id == lastID }) {
                return reserve.remove(at: idx)
            }
        }
        guard !reserve.isEmpty else { return nil }
        return reserve.removeFirst()
    }

    /// Return a removed lane's container to the ring (off the left edge) and remember it.
    func release(_ container: ContainerType) {
        reserve.append(container)
        removedStack.append(container.id)
    }
}

extension ContainerType {
    static let palette: [Color] = [
        .black, .blue, .purple, .indigo, .teal, .brown, .pink, .orange,
        .green, .red, .cyan, .mint, .yellow, .gray, .secondary,
    ]

    /// The catalog of 15 distinct container types.
    static func catalog() -> [ContainerType] {
        (1...15).map { n in
            ContainerType(kind: n, title: "\(n)", color: palette[(n - 1) % palette.count])
        }
    }

    /// Build a fresh instance of a given catalog type.
    static func entry(kind: Int) -> ContainerType {
        let template = catalog()[(kind - 1) % 15]
        return ContainerType(kind: template.kind, title: template.title, color: template.color)
    }

    /// Demo ring: all 15 catalog types, plus extra instances of type 6 so six 6's exist.
    static func demoPool() -> [ContainerType] {
        var pool = catalog()
        for _ in 0..<5 { pool.append(entry(kind: 6)) }
        return pool
    }
}
