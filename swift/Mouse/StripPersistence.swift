import Foundation

/// Persistence for the ring strip: the live model is snapshotted into the plain Codable DTOs
/// below and written as one atomic JSON file in Application Support; launch restores from it
/// (`ForegroundView` falls back to the demo strip when nothing usable is saved).
///
/// The DTOs are separate from the live types because the model relies on reference identity —
/// every instance of a synced kind points at one shared `ContainerContent` — and that aliasing
/// doesn't round-trip through Codable directly. Instead, shared content is stored once per kind
/// in `StripSnapshot.sharedContents`, restored into the registry first, and instances re-link to
/// it via `ContainerContent.resolve(kind:)` as they're rebuilt.
///
/// Saving is wired to `scenePhase` in `ForegroundView`: every departure from `.active` writes a
/// fresh snapshot (that's the reliable "app is going away" signal on iOS). Restored lane heights
/// are absolute points from the previous run; the first layout pass re-fits them proportionally
/// to the current window (`ForegroundView.configure`).

struct StripSnapshot: Codable {
    var currentIndex: Int
    var rings: [RingSnapshot]
    /// One entry per synced kind with live content (see `ContainerContent.syncedKinds`).
    var sharedContents: [ContentSnapshot]
}

struct RingSnapshot: Codable {
    var lanes: [LaneSnapshot]
    var reserve: [InstanceSnapshot]
    var removedStack: [UUID]
}

struct LaneSnapshot: Codable {
    var container: InstanceSnapshot
    var height: CGFloat
}

struct InstanceSnapshot: Codable {
    var id: UUID
    var kind: Int
}

/// The persisted fields of `ContainerContent`. Grows alongside it as containers gain real
/// content; runtime-only state (live sessions and the like) stays out.
struct ContentSnapshot: Codable {
    var kind: Int
}

// MARK: - Live model ↔ snapshot

extension RingStrip {
    func snapshot() -> StripSnapshot {
        StripSnapshot(
            currentIndex: currentIndex,
            rings: rings.map { $0.snapshot() },
            sharedContents: ContainerContent.snapshotSharedContents()
        )
    }

    convenience init(restoring snapshot: StripSnapshot) {
        // Shared content first, so instance restoration resolves to the restored objects.
        ContainerContent.restoreSharedContents(snapshot.sharedContents)
        let rings = snapshot.rings.map(CarouselDeck.init(restoring:))
        self.init(rings: rings, currentIndex: max(0, min(snapshot.currentIndex, rings.count - 1)))
    }
}

extension CarouselDeck {
    func snapshot() -> RingSnapshot {
        RingSnapshot(
            lanes: lanes.map { LaneSnapshot(container: $0.current.snapshot(), height: $0.height) },
            reserve: reserve.map { $0.snapshot() },
            removedStack: removedStack
        )
    }

    convenience init(restoring snapshot: RingSnapshot) {
        self.init(
            lanes: snapshot.lanes.map { Lane(current: $0.container.restore(), height: $0.height) },
            reserve: snapshot.reserve.map { $0.restore() },
            removedStack: snapshot.removedStack
        )
    }
}

extension ContainerType {
    func snapshot() -> InstanceSnapshot { InstanceSnapshot(id: id, kind: kind) }
}

extension InstanceSnapshot {
    /// Rebuild the instance: catalog visuals come from `kind`; content comes from `resolve` —
    /// the shared object for synced kinds (restored just prior), a fresh private one otherwise.
    func restore() -> ContainerType { .entry(kind: kind, id: id) }
}

extension ContainerContent {
    func snapshot() -> ContentSnapshot { ContentSnapshot(kind: kind) }
}

extension ContentSnapshot {
    func restore() -> ContainerContent { ContainerContent(kind: kind) }
}

// MARK: - Disk

enum StripPersistence {
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ring-strip.json")
    }

    static func save(_ strip: RingStrip) {
        do {
            let url = fileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(strip.snapshot()).write(to: url, options: .atomic)
        } catch {
            print("StripPersistence: save failed — \(error)")
        }
    }

    /// The saved strip, or `nil` when there's nothing (or nothing usable) on disk.
    static func load() -> RingStrip? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(StripSnapshot.self, from: data),
              !snapshot.rings.isEmpty,
              snapshot.rings.allSatisfy({ !$0.lanes.isEmpty })
        else { return nil }
        return RingStrip(restoring: snapshot)
    }
}
