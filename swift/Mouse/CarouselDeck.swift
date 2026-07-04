import SwiftUI

/// A container instance on the ring. Identity is per-instance (`id`); `kind` says which catalog
/// type it is, so the ring may hold several instances of the same `kind` (e.g. six 6's). An
/// instance lives in exactly one place at a time: a lane, or the off-screen reserve.
struct ContainerType: Identifiable {
    let id: UUID
    let kind: Int
    let title: String
    let color: Color
    /// What's inside the container, separate from the instance displaying it. Reference-typed:
    /// synced kinds share one object across every instance in every ring; other kinds get a
    /// private one per instance.
    let content: ContainerContent
}

/// A container's mutable contents — the attachment point for whatever containers end up holding.
/// The point is the reference semantics: kinds in `syncedKinds` resolve to a single app-wide
/// object, so every instance of that kind — any lane, any reserve, any ring, existing or created
/// later — shows and mutates the same state. Being `@Observable`, any visible instance updates
/// live when the shared state changes from anywhere. The registry never evicts: a synced kind's
/// contents persist even while no instance of it is on screen.
@Observable
final class ContainerContent {
    let kind: Int

    init(kind: Int) { self.kind = kind }

    /// Container kinds whose content is shared app-wide.
    static let syncedKinds: Set<Int> = [15]

    // Only ever touched from SwiftUI on the main thread; container creation has no other callers.
    nonisolated(unsafe) private static var sharedByKind: [Int: ContainerContent] = [:]

    /// The content object for a new instance of `kind`: the app-wide shared one for synced kinds,
    /// otherwise a fresh private one.
    static func resolve(kind: Int) -> ContainerContent {
        guard syncedKinds.contains(kind) else { return ContainerContent(kind: kind) }
        if let shared = sharedByKind[kind] { return shared }
        let fresh = ContainerContent(kind: kind)
        sharedByKind[kind] = fresh
        return fresh
    }

    /// Snapshot / restore of the shared registry, for persistence. Restore must run before any
    /// instances are rebuilt so `resolve(kind:)` hands them the restored objects.
    static func snapshotSharedContents() -> [ContentSnapshot] {
        sharedByKind.values.map { $0.snapshot() }
    }

    static func restoreSharedContents(_ snapshots: [ContentSnapshot]) {
        sharedByKind = Dictionary(uniqueKeysWithValues:
            snapshots.filter { syncedKinds.contains($0.kind) }.map { ($0.kind, $0.restore()) })
    }
}

/// One on-screen spot in the ring window. A lane holds whichever container currently sits in it.
struct Lane: Identifiable {
    let id = UUID()
    var current: ContainerType
    var height: CGFloat = 0
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

    init(lanes: [Lane], reserve: [ContainerType], removedStack: [ContainerType.ID] = []) {
        self.lanes = lanes
        self.reserve = reserve
        self.removedStack = removedStack
    }

    static func demo() -> CarouselDeck {
        let all = ContainerType.demoPool()
        let lanes = all.prefix(3).map { Lane(current: $0) }
        return CarouselDeck(lanes: Array(lanes), reserve: Array(all.dropFirst(3)))
    }

    /// A brand-new ring: one lane showing catalog type 1, the rest of the catalog in reserve.
    static func fresh() -> CarouselDeck {
        let all = ContainerType.catalog()
        return CarouselDeck(lanes: [Lane(current: all[0])], reserve: Array(all.dropFirst()))
    }

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

/// Which screen edge a ring swipe starts from — equivalently, which side of the current ring the
/// incoming ring sits on.
enum RingSide {
    case left, right
    var opposite: RingSide { self == .left ? .right : .left }
}

/// An ordered strip of rings. Exactly one ring is on screen at a time; an edge swipe slides to the
/// neighbouring ring on that side, or mints a fresh ring when the strip ends there.
@Observable
final class RingStrip {
    var rings: [CarouselDeck]
    var currentIndex: Int

    init(rings: [CarouselDeck], currentIndex: Int = 0) {
        self.rings = rings
        self.currentIndex = currentIndex
    }

    var current: CarouselDeck { rings[currentIndex] }

    func neighbor(on side: RingSide) -> CarouselDeck? {
        let i = currentIndex + (side == .right ? 1 : -1)
        return rings.indices.contains(i) ? rings[i] : nil
    }
}

extension ContainerType {
    static let palette: [Color] = [
        .black, .blue, .purple, .indigo, .teal, .brown, .pink, .orange,
        .green, .red, .cyan, .mint, .yellow, .gray, .secondary,
    ]

    /// The catalog of 15 distinct container types.
    static func catalog() -> [ContainerType] {
        (1...15).map { entry(kind: $0) }
    }

    /// Build an instance of a given catalog type — fresh by default, or with a persisted identity.
    static func entry(kind: Int, id: UUID = UUID()) -> ContainerType {
        let k = (kind - 1) % 15 + 1
        return ContainerType(
            id: id,
            kind: k,
            title: "\(k)",
            color: palette[(k - 1) % palette.count],
            content: .resolve(kind: k)
        )
    }

    /// Demo ring: all 15 catalog types, plus extra instances of type 6 so six 6's exist.
    static func demoPool() -> [ContainerType] {
        var pool = catalog()
        for _ in 0..<5 { pool.append(entry(kind: 6)) }
        return pool
    }
}
