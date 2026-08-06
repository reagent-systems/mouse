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
    /// What the container does when nothing is happening in its lane.
    var idle: IdleAnimation = .none
    /// The label once the container's lesson has been performed ("Swipe?" → "Swiped."). The swap
    /// happens live, mid-gesture, via `content.done`.
    var doneTitle: String? = nil

    /// Preset onboarding containers (kinds ≤ 0) teach a gesture instead of holding content.
    var isOnboardingPreset: Bool { kind <= 0 }

    /// Lesson presets gate the onboarding chain; blank fillers don't.
    var isLessonPreset: Bool {
        [Self.swipePresetKind, Self.dragPresetKind, Self.spreadPresetKind, Self.pinchPresetKind]
            .contains(kind)
    }

    /// Whether the label rides the divider gap above the container instead of its center.
    var usesGapLabel: Bool {
        kind == Self.dragPresetKind || kind == Self.spreadPresetKind
    }

    /// The live label: past tense once the lesson is being (or has been) performed.
    var displayTitle: String {
        if content.done, let doneTitle { return doneTitle }
        return title
    }
}

/// A container's idle behavior, part of its properties. Onboarding presets use it to suggest
/// their gesture without any overlay UI or arrows — the motion is the arrow.
enum IdleAnimation: Equatable {
    case none
    /// Periodic small left-right bounce — "this swipes".
    case horizontalBounce
    /// The container's top edge periodically reaches up toward the divider (scale from the
    /// bottom) — "the boundary above me drags". The container itself doesn't travel.
    case gapReach
    /// Periodic slight shrink — "this pinches closed".
    case shrinkPulse
    /// The gap above periodically widens: this container's top edge retreats (scale from the
    /// bottom) while the container above retreats upward in sync — "this space spreads open".
    case gapBreathe
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
    /// For lesson presets: flips true the moment the user is clearly performing the gesture,
    /// which live-swaps the label to its past tense and stops the idle animation.
    var done = false

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
    /// True for the dedicated first-launch onboarding ring, which holds nothing but lesson
    /// containers and retires once the user edge-swipes away to their first real ring.
    let isOnboarding: Bool
    /// The spread lesson's shared idle pulse (1 at rest, briefly below): both sides of the gap
    /// retreat from it in OPPOSITE directions, widening the space. Transient — never persisted.
    var spreadPulse: CGFloat = 1
    /// The drag lesson's shared idle pulse, in points: how far the taught boundary has shifted
    /// up. Both sides follow it in the SAME direction — the lane above shrinks upward while the
    /// lesson lane's top edge reaches up, so the divider visibly travels. Transient.
    var dragPulse: CGFloat = 0
    /// Set while the pinch lesson is scheduled but not yet on stage (the blank beat after
    /// "Spread." leaves), so the edge lesson can't jump the queue in between. Transient.
    var pinchLessonStaged = false
    /// The ring's project. Containers are windows onto it: Files browses it, Viewer shows its
    /// open file, and later Source Control and the terminal operate on it. Workspaces are shared
    /// (one per repo, app-wide) — project truth lives there; VIEWPORT state lives on the ring.
    var workspace: Workspace?
    /// Which file THIS ring's viewer shows. Per-ring by design: rings sharing a repo share
    /// files/git/graph but keep their own open file, so swiping between rings is switching
    /// between editors on the same project.
    var openFilePath: String?
    /// True while this ring's editor owns the keyboard. The shell's lane swipe stands down on
    /// the viewer then: horizontal drags there are text interactions (selection handles, the
    /// caret) — without this, dragging a highlight also dragged the lane, re-rendering the
    /// whole stack every frame (CPU) and threatening a container swap on release.
    var editorFocused = false
    @ObservationIgnored private var ringTerminal: TerminalSession?

    /// Choose the file this ring's viewer shows; the shared buffer for it loads immediately
    /// (off screen), so the viewer renders complete on its first frame.
    func openFile(_ path: String?) {
        openFilePath = path
        if let path, let workspace {
            _ = FileBuffer.shared(for: workspace, path: path)
        }
    }

    /// This ring's own terminal session on the (possibly shared) workspace — separate scrollback
    /// and cwd per ring. Memoized; rebuilt if the ring later opens a different repo.
    @MainActor
    func terminal(for workspace: Workspace) -> TerminalSession {
        if let ringTerminal, ringTerminal.root == workspace.root { return ringTerminal }
        let session = TerminalSession(root: workspace.root)
        ringTerminal = session
        return session
    }
    /// Extra divider height while a gap-label lesson needs room for its word. Animated model
    /// state (not derived at render time) so divider growth and the compensating lane re-fit
    /// share one transaction — the stack's total height never wavers. Set by the view layer.
    var dividerBoost: CGFloat = 0

    /// A lane's part in a gap lesson's idle animation (drag or spread), if any.
    enum GapRole {
        /// The lesson container itself (below the taught gap).
        case lesson
        /// The lane directly above the taught gap.
        case above
    }

    func gapRole(of laneID: Lane.ID, lessonKind: Int) -> GapRole? {
        guard let i = lanes.firstIndex(where: {
            $0.current.kind == lessonKind && !$0.current.content.done
        }) else { return nil }
        if lanes[i].id == laneID { return .lesson }
        if i > 0, lanes[i - 1].id == laneID { return .above }
        return nil
    }

    /// Whether any lane shows a gap-label lesson (drag/spread) — those dividers grow to fit
    /// the word.
    var hasGapLabelLesson: Bool { lanes.contains { $0.current.usesGapLabel } }

    init(
        lanes: [Lane],
        reserve: [ContainerType],
        removedStack: [ContainerType.ID] = [],
        isOnboarding: Bool = false
    ) {
        self.lanes = lanes
        self.reserve = reserve
        self.removedStack = removedStack
        self.isOnboarding = isOnboarding
    }

    /// The dedicated onboarding ring: blank fillers around the "Swipe?" lesson, empty reserve so
    /// nothing else swipes. Lessons chain — swipe → drag → spread → pinch → edge swipe — with
    /// each finished lesson producing the next.
    static func onboarding() -> CarouselDeck {
        CarouselDeck(
            lanes: [
                Lane(current: .onboardingBlank()),
                Lane(current: .onboardingSwipe()),
                Lane(current: .onboardingBlank()),
            ],
            reserve: [],
            isOnboarding: true
        )
    }

    /// The edge-swipe lesson (the ring's final step) begins only once no lesson container is in
    /// the lanes at all — a finished lesson still lingering ("Dragged.", "Spread."), mid-morph,
    /// or staged-but-not-yet-shown keeps the stage to itself, so lessons appear strictly one at
    /// a time.
    var edgeLessonActive: Bool {
        isOnboarding && !pinchLessonStaged && !lanes.contains { $0.current.isLessonPreset }
    }

    /// Mark the drag lesson as being performed (label flips to "Dragged.", idle stops).
    func markDragLessonDone() {
        for lane in lanes where lane.current.kind == ContainerType.dragPresetKind {
            lane.current.content.done = true
        }
    }

    var hasDoneDragLesson: Bool {
        lanes.contains { $0.current.kind == ContainerType.dragPresetKind && $0.current.content.done }
    }

    /// The spread lesson still waiting to be performed, if any.
    var pendingSpreadLesson: ContainerType? {
        lanes.first {
            $0.current.kind == ContainerType.spreadPresetKind && !$0.current.content.done
        }?.current
    }

    /// Swap each finished drag preset for the spread lesson — its half of the zoom teaching.
    func morphDoneDragIntoSpread() {
        for i in lanes.indices
        where lanes[i].current.kind == ContainerType.dragPresetKind && lanes[i].current.content.done {
            lanes[i].current = .onboardingSpread()
        }
    }

    /// A finished spread lesson goes blank once its moment has passed.
    func morphDoneSpreadIntoBlank() {
        for i in lanes.indices
        where lanes[i].current.kind == ContainerType.spreadPresetKind && lanes[i].current.content.done {
            lanes[i].current = .onboardingBlank()
        }
    }

    /// The pinch lesson takes the stage only after "Spread." has left it: the spread gesture's
    /// new lane arrives blank, then swaps to the pinch preset. No-op if that lane is gone
    /// (pinching it away early already proved the lesson).
    func placePinchLesson(replacing blankID: ContainerType.ID) {
        pinchLessonStaged = false
        guard let i = lanes.firstIndex(where: { $0.current.id == blankID }) else { return }
        lanes[i].current = .onboardingPinch()
    }

    /// A brand-new ring: one lane showing catalog type 1, the rest of the catalog in reserve.
    static func fresh() -> CarouselDeck {
        let all = ContainerType.catalog()
        return CarouselDeck(lanes: [Lane(current: all[0])], reserve: Array(all.dropFirst()))
    }

    /// Swipe-left commit: pull the right-edge container into the lane, push the old one off the
    /// left. A swiped-away onboarding preset hands its lane to its chain successor instead of
    /// pulling from the reserve.
    func advance(laneID: Lane.ID) {
        guard let i = lanes.firstIndex(where: { $0.id == laneID }) else { return }
        let outgoing = lanes[i].current
        if let fill = ContainerType.fillIn(after: outgoing) {
            lanes[i].current = fill
        } else {
            guard !reserve.isEmpty else { return }
            lanes[i].current = reserve.removeFirst()
        }
        reserve.append(outgoing)
    }

    /// Swipe-right commit: pull the left-edge container into the lane, push the old one off the right.
    func retreat(laneID: Lane.ID) {
        guard let i = lanes.firstIndex(where: { $0.id == laneID }) else { return }
        let outgoing = lanes[i].current
        if let fill = ContainerType.fillIn(after: outgoing) {
            lanes[i].current = fill
        } else {
            guard !reserve.isEmpty else { return }
            lanes[i].current = reserve.removeLast()
        }
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

    /// Drop a container from the off-screen reserve entirely. Onboarding presets retire this way
    /// after being swiped: once the swipe is taught, they leave the ring instead of riding it.
    func removeFromReserve(_ id: ContainerType.ID) {
        reserve.removeAll { $0.id == id }
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
    /// The catalog: the five real containers, in ring order. The colored numbered
    /// placeholders (kinds 6–15) that filled the ring out before the real surfaces existed
    /// are retired — Android's deck already ships only these five, and a snapshot that still
    /// carries a placeholder drops it at restore.
    static func catalog() -> [ContainerType] {
        [gitHubKind, filesKind, viewerKind, graphKind, terminalKind].map { entry(kind: $0) }
    }

    /// Build an instance of a given catalog type — fresh by default, or with a persisted identity.
    static func entry(kind: Int, id: UUID = UUID()) -> ContainerType {
        ContainerType(
            id: id,
            kind: kind,
            title: realTitles[kind] ?? "\(kind)",
            color: .black,
            content: .resolve(kind: kind)
        )
    }

    /// Catalog kind 1 is the GitHub sign-in container (`GitHubSignInView` / `GitHubAuth`).
    static let gitHubKind = 1
    /// Catalog kind 2 is the Files container: repo picker, then the working tree.
    static let filesKind = 2
    /// Catalog kind 3 is the Viewer container: the workspace's open file.
    static let viewerKind = 3
    /// Catalog kind 4 is the Graph container: the workspace's commit graph.
    static let graphKind = 4
    /// Catalog kind 5 is the Terminal container: a native command dispatcher on the workspace.
    static let terminalKind = 5

    /// Containers with real surfaces (they render their own content, terminal-styled black).
    static let realKinds: Set<Int> = [gitHubKind, filesKind, viewerKind, graphKind, terminalKind]
    static let realTitles: [Int: String] = [
        gitHubKind: "GitHub", filesKind: "Files", viewerKind: "Viewer", graphKind: "Graph",
        terminalKind: "Terminal",
    ]

    static let swipePresetKind = 0
    static let dragPresetKind = -1
    static let blankPresetKind = -2
    static let spreadPresetKind = -3
    static let pinchPresetKind = -4

    /// "Swipe?" — teaches the lane swipe with a horizontal idle bounce; retires once swiped.
    static func onboardingSwipe(id: UUID = UUID()) -> ContainerType {
        ContainerType(
            id: id, kind: swipePresetKind, title: "Swipe?", color: .black,
            content: .resolve(kind: swipePresetKind),
            idle: .horizontalBounce, doneTitle: "Swiped."
        )
    }

    /// "Drag?" — label rides the divider gap it teaches; bounces vertically. Once dragged, it
    /// morphs into the spread lesson (its half of the zoom teaching).
    static func onboardingDrag(id: UUID = UUID()) -> ContainerType {
        ContainerType(
            id: id, kind: dragPresetKind, title: "Drag?", color: .black,
            content: .resolve(kind: dragPresetKind),
            idle: .gapReach, doneTitle: "Dragged."
        )
    }

    /// "Spread?" — same gap label; the two-finger spread opens a new lane, which arrives already
    /// holding the pinch lesson. Afterwards this container goes blank.
    static func onboardingSpread(id: UUID = UUID()) -> ContainerType {
        ContainerType(
            id: id, kind: spreadPresetKind, title: "Spread?", color: .black,
            content: .resolve(kind: spreadPresetKind),
            idle: .gapBreathe, doneTitle: "Spread."
        )
    }

    /// "Pinch?" — pulses slightly smaller; pinching its lane closed removes it for good.
    static func onboardingPinch(id: UUID = UUID()) -> ContainerType {
        ContainerType(
            id: id, kind: pinchPresetKind, title: "Pinch?", color: .black,
            content: .resolve(kind: pinchPresetKind),
            idle: .shrinkPulse, doneTitle: "Pinched."
        )
    }

    /// Unlabeled filler for the onboarding ring, so the tutorial reads clean and isolated.
    static func onboardingBlank(id: UUID = UUID()) -> ContainerType {
        ContainerType(
            id: id, kind: blankPresetKind, title: "", color: .black,
            content: .resolve(kind: blankPresetKind)
        )
    }

    /// The onboarding chain: what fills a lane when a preset is swiped away, instead of pulling
    /// from the reserve. Swiping "Swipe?" away brings in "Drag?"; everything else returns `nil`.
    static func fillIn(after outgoing: ContainerType) -> ContainerType? {
        outgoing.kind == swipePresetKind ? .onboardingDrag() : nil
    }

}
