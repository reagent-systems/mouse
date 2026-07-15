package com.reagentsystems.mouse

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.UUID

/**
 * Container catalog. Real kinds are ≥ 1; onboarding presets are ≤ 0 (they teach a gesture
 * instead of holding content). Mirrors `ContainerType`/`CarouselDeck` in the Swift app.
 */
object Kind {
    const val gitHub = 1
    const val files = 2
    const val viewer = 3
    const val graph = 4
    const val terminal = 5

    // Onboarding presets (≤ 0).
    const val swipe = 0
    const val drag = -1
    const val blank = -2
    const val spread = -3
    const val pinch = -4

    val realKinds = listOf(gitHub, files, viewer, graph, terminal)
    fun title(kind: Int): String = when (kind) {
        gitHub -> "GitHub"; files -> "Files"; viewer -> "Viewer"; graph -> "Graph"; terminal -> "Terminal"
        else -> ""
    }
    fun isOnboardingPreset(kind: Int) = kind <= 0
}

/** How a preset hints its gesture at rest — motion is the arrow (DESIGN.md §1). */
enum class Idle { NONE, HORIZONTAL_BOUNCE, GAP_REACH, SHRINK_PULSE, GAP_BREATHE }

/** A container instance on the ring. Identity is per-instance (`id`). */
class ContainerType(
    val id: UUID,
    val kind: Int,
    val title: String,
    val idle: Idle = Idle.NONE,
    val doneTitle: String? = null,
) {
    /** Flips true mid-gesture; live-swaps a lesson label to past tense and stops its idle. */
    var done by mutableStateOf(false)

    val isOnboardingPreset get() = Kind.isOnboardingPreset(kind)
    val isLessonPreset get() = kind == Kind.swipe || kind == Kind.drag || kind == Kind.spread || kind == Kind.pinch
    val usesGapLabel get() = kind == Kind.drag || kind == Kind.spread
    val displayTitle: String get() = if (done && doneTitle != null) doneTitle else title

    companion object {
        fun entry(kind: Int, id: UUID = UUID.randomUUID()) =
            ContainerType(id, kind, Kind.title(kind))

        fun onboardingSwipe(id: UUID = UUID.randomUUID()) =
            ContainerType(id, Kind.swipe, "Swipe?", Idle.HORIZONTAL_BOUNCE, "Swiped.")
        fun onboardingDrag(id: UUID = UUID.randomUUID()) =
            ContainerType(id, Kind.drag, "Drag?", Idle.GAP_REACH, "Dragged.")
        fun onboardingSpread(id: UUID = UUID.randomUUID()) =
            ContainerType(id, Kind.spread, "Spread?", Idle.GAP_BREATHE, "Spread.")
        fun onboardingPinch(id: UUID = UUID.randomUUID()) =
            ContainerType(id, Kind.pinch, "Pinch?", Idle.SHRINK_PULSE, "Pinched.")
        fun onboardingBlank(id: UUID = UUID.randomUUID()) =
            ContainerType(id, Kind.blank, "")

        /** Onboarding chain: swiping "Swipe?" away brings in "Drag?"; else nothing. */
        fun fillIn(after: ContainerType): ContainerType? =
            if (after.kind == Kind.swipe) onboardingDrag() else null
    }
}

/** One on-screen spot in the ring window. */
class Lane(current: ContainerType, height: Float = 0f) {
    val id: UUID = UUID.randomUUID()
    var current by mutableStateOf(current)
    var height by mutableStateOf(height)
}

/**
 * A ring: a window (`lanes`) over a circular strip of containers; the rest sit in `reserve`
 * (first = just off the right edge, last = just off the left). Also the per-ring viewport onto
 * a shared [Workspace]: open file + terminal are per-ring, the workspace is shared by repo.
 */
class CarouselDeck(
    lanes: List<Lane>,
    reserve: List<ContainerType> = emptyList(),
    val isOnboarding: Boolean = false,
) {
    val lanes = mutableStateListOf<Lane>().apply { addAll(lanes) }
    val reserve = mutableStateListOf<ContainerType>().apply { addAll(reserve) }
    val removedStack = ArrayDeque<UUID>()

    var workspace by mutableStateOf<Workspace?>(null)
    var openFilePath by mutableStateOf<String?>(null)
    var editorFocused by mutableStateOf(false)
    var dividerBoost by mutableStateOf(0f)
    /// Set once the onboarding's pinch lesson is done — the ring now waits to be edge-swiped
    /// away (its graduation). Only meaningful while `isOnboarding`.
    var edgeLessonActive by mutableStateOf(false)

    /// The onboarding lesson currently on stage (the middle lane), if any.
    val onStageLesson: ContainerType? get() = lanes.map { it.current }.firstOrNull { it.isLessonPreset }

    /// Swap the on-stage lesson for the next one in the chain (drag→spread→pinch→blank).
    fun morphOnStageLesson(next: ContainerType) {
        val lane = lanes.firstOrNull { it.current.isLessonPreset } ?: return
        lane.current = next
    }

    private var ringTerminal: TerminalSession? = null
    fun terminal(workspace: Workspace): TerminalSession {
        ringTerminal?.let { if (it.root == workspace.root) return it }
        return TerminalSession(workspace.root).also { ringTerminal = it }
    }

    fun openFile(path: String?) {
        openFilePath = path
        val ws = workspace ?: return
        if (path != null) FileBuffer.shared(ws, path)
    }

    val hasGapLabelLesson get() = lanes.any { it.current.usesGapLabel }

    // Reserve shuffling ------------------------------------------------------

    fun advance(laneId: UUID) = shift(laneId, forward = true)
    fun retreat(laneId: UUID) = shift(laneId, forward = false)

    private fun shift(laneId: UUID, forward: Boolean) {
        val index = lanes.indexOfFirst { it.id == laneId }.takeIf { it >= 0 } ?: return
        val outgoing = lanes[index].current
        val incoming = ContainerType.fillIn(outgoing)
            ?: (if (forward) reserve.removeFirstOrNull() else reserve.removeLastOrNull())
            ?: return
        // Push the outgoing container to the far edge; a preset that morphs just disappears.
        if (ContainerType.fillIn(outgoing) == null && !outgoing.isOnboardingPreset) {
            if (forward) reserve.add(outgoing) else reserve.add(0, outgoing)
        }
        lanes[index].current = incoming
    }

    /** A fresh lane pulls a container off the ring (or restores the last removed one). */
    fun containerForNewLane(): ContainerType? {
        while (removedStack.isNotEmpty()) {
            val id = removedStack.removeLast()
            val restored = reserve.indexOfFirst { it.id == id }
            if (restored >= 0) return reserve.removeAt(restored)
        }
        return reserve.removeFirstOrNull()
    }

    fun release(container: ContainerType) {
        removedStack.addLast(container.id)
        reserve.add(0, container)
    }

    companion object {
        /** A normal ring: the five real containers, one on stage. */
        fun fresh(): CarouselDeck {
            val entries = Kind.realKinds.map { ContainerType.entry(it) }
            return CarouselDeck(lanes = listOf(Lane(entries.first())), reserve = entries.drop(1))
        }

        /** The dedicated onboarding ring: the first lesson sits on stage between blank lanes
         *  (blank / Swipe? / blank), the way the iOS onboarding presents one lesson at a time. */
        fun onboarding(): CarouselDeck = CarouselDeck(
            lanes = listOf(
                Lane(ContainerType.onboardingBlank()),
                Lane(ContainerType.onboardingSwipe()),
                Lane(ContainerType.onboardingBlank()),
            ),
            isOnboarding = true,
        )
    }
}

/** The strip of rings; the screen shows `current`. */
class RingStrip(rings: List<CarouselDeck>, currentIndex: Int = 0) {
    val rings = mutableStateListOf<CarouselDeck>().apply { addAll(rings) }
    var currentIndex by mutableStateOf(currentIndex.coerceIn(0, (rings.size - 1).coerceAtLeast(0)))
    val current get() = rings[currentIndex]

    fun neighbor(right: Boolean): CarouselDeck? {
        val i = if (right) currentIndex + 1 else currentIndex - 1
        return rings.getOrNull(i)
    }
}
