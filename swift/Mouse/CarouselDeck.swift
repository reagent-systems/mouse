import SwiftUI

/// A container instance in the shared pool. Identity is per-instance (`id`); `kind` says which
/// catalog type it is. The pool can hold several instances of the same `kind` (e.g. six 6's), and
/// each instance can occupy at most one on-screen position at a time.
struct ContainerType: Identifiable {
    let id = UUID()
    let kind: Int
    let title: String
    let color: Color
}

/// One horizontal lane. A lane isn't a private carousel — it's a window onto the shared pool that
/// currently displays one instance (`current`). Swiping "pulls" another free instance in and
/// "pushes" the old one back to the pool.
struct Lane: Identifiable {
    let id = UUID()
    var current: ContainerType.ID
    var height: CGFloat = 0
}

/// The vertical stack of lanes plus the single pool of container instances they pull from.
@Observable
final class CarouselDeck {
    /// Every container instance. Instances displayed by a lane are "checked out"; the rest are free.
    var pool: [ContainerType]
    var lanes: [Lane]
    /// LIFO history of the instances that removed lanes were showing, newest last. Re-adding a lane
    /// restores the most recently removed lane's instance (if it's still free).
    var removedStack: [ContainerType.ID] = []

    init(pool: [ContainerType], lanes: [Lane]) {
        self.pool = pool
        self.lanes = lanes
    }

    static func demo() -> CarouselDeck {
        let pool = ContainerType.demoPool()
        let lanes = pool.prefix(3).map { Lane(current: $0.id) }
        return CarouselDeck(pool: pool, lanes: Array(lanes))
    }

    /// Instance IDs currently displayed by some lane (optionally ignoring one lane).
    func heldIDs(excluding laneID: Lane.ID? = nil) -> Set<ContainerType.ID> {
        Set(lanes.filter { $0.id != laneID }.map { $0.current })
    }

    /// Instances a lane may show, in pool order: its own current plus anything not held elsewhere.
    /// This set is invariant when the lane swaps its current for a free instance, so the lane's
    /// pager stays stable while exclusivity is enforced against the other lanes.
    func pages(forLane laneID: Lane.ID) -> [ContainerType] {
        guard let lane = lanes.first(where: { $0.id == laneID }) else { return [] }
        let held = heldIDs(excluding: laneID)
        return pool.filter { $0.id == lane.current || !held.contains($0.id) }
    }

    /// The first instance no lane is displaying, or `nil` when the whole pool is checked out.
    func firstFreeContainer() -> ContainerType? {
        let held = heldIDs()
        return pool.first { !held.contains($0.id) }
    }

    /// Pick the instance a newly-added lane should show: the most recently removed lane's instance
    /// if it's still free, otherwise the first free instance. Returns `nil` if the pool is exhausted.
    func containerForNewLane() -> ContainerType? {
        let held = heldIDs()
        while let last = removedStack.popLast() {
            if !held.contains(last), let match = pool.first(where: { $0.id == last }) {
                return match
            }
        }
        return firstFreeContainer()
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

    /// Demo pool: all 15 catalog types, plus extra instances of type 6 so six 6's exist.
    static func demoPool() -> [ContainerType] {
        var pool = catalog()
        for _ in 0..<5 { pool.append(entry(kind: 6)) }
        return pool
    }
}
