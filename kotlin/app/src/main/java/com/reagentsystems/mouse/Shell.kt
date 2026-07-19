package com.reagentsystems.mouse

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.abs

/**
 * The interactive shell (mirrors `ForegroundView.swift`): a vertical stack of horizontally-
 * swipeable lanes with divider handles, a strip of rings you edge-swipe between, and pinch to
 * add/remove lanes. The gesture law is enforced by axis-locked drag detectors: horizontal drives
 * the shell, vertical belongs to content. Sizing uses [BoxWithConstraints] (Android has no ASCII-
 * sibling inflation problem, so this is simpler than the iOS containerRelativeFrame path).
 */

/**
 * Pixel's gesture navigation caps [systemGestureExclusion] at 200dp per edge, so on Pixels the
 * edge strips lose the fight with the system back gesture. There, ring travel moves to the
 * NEGATIVE SPACE BETWEEN CONTAINERS: a horizontal drag in a divider gap swipes the ring
 * (vertical drags in the gap still resize lanes — axis-locked detectors keep both). A one-lane
 * ring has no between-container space, so the edge strips remain its travel path.
 */
private val isPixel = android.os.Build.MANUFACTURER.equals("Google", ignoreCase = true) &&
    android.os.Build.MODEL.contains("Pixel", ignoreCase = true)
@Composable
fun ForegroundView(base: File) {
    val strip = remember { StripPersistence.load(base) ?: RingStrip(listOf(CarouselDeck.onboarding())) }
    val deck = strip.current
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    BoxWithConstraints(Modifier.fillMaxSize().background(Theme.canvas).systemBarsPadding()) {
        val availableHeightPx = with(density) { maxHeight.toPx() }
        val availableWidthPx = with(density) { maxWidth.toPx() }
        val dividerPx = with(density) { Theme.dividerGap.toPx() }
        val minLanePx = with(density) { 80.dp.toPx() }

        // Give lanes an even split once we know the height.
        remember(availableHeightPx, deck) {
            if (deck.lanes.all { it.height == 0f }) {
                val usable = availableHeightPx - dividerPx * (deck.lanes.size - 1)
                deck.lanes.forEach { it.height = usable / deck.lanes.size }
            }
            true
        }

        val ringDrag = remember { Animatable(0f) }
        var adjacent by remember { mutableStateOf<Pair<CarouselDeck, Boolean>?>(null) } // ring, isRight
        // Gap ring-swipe (Pixel): unlike an edge strip, a gap drag has no built-in direction —
        // the FIRST movement locks it (leftward pulls in the right neighbor, rightward the left)
        // and it holds until the finger lifts, so a wobble mid-drag can't flip neighbors.
        var gapDirection by remember { mutableStateOf<Boolean?>(null) } // isRight
        val gapRingDrag: (Float, Boolean) -> Unit = { delta, done ->
            if (done) {
                gapDirection?.let { dir ->
                    ringSwipe(0f, true, dir, strip, ringDrag, availableWidthPx, scope, setAdjacent = { adjacent = it }, adjacent)
                }
                gapDirection = null
            } else {
                val dir = gapDirection ?: (delta < 0f).also { gapDirection = it }
                ringSwipe(delta, false, dir, strip, ringDrag, availableWidthPx, scope, setAdjacent = { adjacent = it }, adjacent)
            }
        }

        Box(Modifier.fillMaxSize().pointerInput(deck) {
            // Two-finger pinch adds/removes a lane. Detected in the INITIAL pass so it can
            // intercept before the lanes' own drag detectors, and it CONSUMES only while ≥2
            // fingers are down — single-finger touches fall straight through to lane swipes and
            // divider drags. `detectTransformGestures` was wrong here twice: it reports
            // incremental zoom per frame (never crossing the 1.2/0.83 thresholds) and it fought
            // the children for single-finger drags (which broke divider resize).
            awaitEachGesture {
                awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                var totalZoom = 1f
                var wasPinch = false
                while (true) {
                    val event = awaitPointerEvent(PointerEventPass.Initial)
                    if (event.changes.count { it.pressed } >= 2) {
                        wasPinch = true
                        val zoom = event.calculateZoom()
                        if (zoom != 1f) {
                            totalZoom *= zoom
                            event.changes.forEach { it.consume() }
                        }
                    }
                    if (event.changes.none { it.pressed }) break
                }
                if (wasPinch) {
                    val lesson = deck.onStageLesson
                    when {
                        // Onboarding lessons advance instead of adding/removing (the ring has no
                        // reserve): spread → Pinch?, pinch → done (then the edge lesson).
                        deck.isOnboarding && lesson?.kind == Kind.spread && totalZoom > 1.2f -> {
                            lesson.done = true
                            scope.launch { kotlinx.coroutines.delay(700); deck.morphOnStageLesson(ContainerType.onboardingPinch()) }
                        }
                        deck.isOnboarding && lesson?.kind == Kind.pinch && totalZoom < 0.83f -> {
                            lesson.done = true
                            scope.launch {
                                kotlinx.coroutines.delay(500)
                                deck.morphOnStageLesson(ContainerType.onboardingBlank())
                                deck.edgeLessonActive = true
                            }
                        }
                        totalZoom > 1.2f -> addLane(deck, availableHeightPx, dividerPx, minLanePx)
                        totalZoom < 0.83f -> removeLane(deck, strip, availableHeightPx, dividerPx)
                    }
                }
            }
        }) {
            adjacent?.let { (ring, isRight) ->
                LaneStack(ring, base, Modifier.offset { IntOffset((ringDrag.value + if (isRight) availableWidthPx else -availableWidthPx).toInt(), 0) })
            }
            LaneStack(deck, base, Modifier.offset { IntOffset(ringDrag.value.toInt(), 0) },
                onGapRingDrag = if (isPixel) gapRingDrag else null)
        }

        // Ring travel. Pixels swipe in the divider gaps (see [isPixel]); the edge strips serve
        // everyone else — and Pixel's one-lane rings, which have no gap to swipe in.
        if (!isPixel || deck.lanes.size == 1) {
            EdgeStrip(true, Modifier.align(Alignment.CenterEnd)) { delta, done -> ringSwipe(delta, done, isRight = true, strip, ringDrag, availableWidthPx, scope, setAdjacent = { adjacent = it }, adjacent) }
            EdgeStrip(false, Modifier.align(Alignment.CenterStart)) { delta, done -> ringSwipe(delta, done, isRight = false, strip, ringDrag, availableWidthPx, scope, setAdjacent = { adjacent = it }, adjacent) }
        }

        // The onboarding's final lesson: once pinch is done, hint the edge swipe that graduates.
        if (deck.isOnboarding && deck.edgeLessonActive) {
            BasicText("Edge Swipe?", Modifier.align(Alignment.Center),
                style = TextStyle(fontFamily = Theme.mono, fontSize = Theme.lessonSize, color = Theme.onContainer))
        }
    }

    // Flush edits + persist when this composable leaves (approximate scenePhase departure).
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose { FileBuffer.flushAll(); StripPersistence.save(base, strip) }
    }
}

@Composable
private fun LaneStack(
    ring: CarouselDeck, base: File, modifier: Modifier,
    /** Non-null on Pixels for the CURRENT ring: divider gaps also carry the ring swipe. */
    onGapRingDrag: ((delta: Float, done: Boolean) -> Unit)? = null,
) {
    val density = LocalDensity.current
    Column(modifier.fillMaxSize().clip(androidx.compose.ui.graphics.RectangleShape)) {
        ring.lanes.forEachIndexed { index, lane ->
            CarouselLane(ring, lane, base, Modifier.fillMaxWidth().height(with(density) { lane.height.toDp() }))
            if (index < ring.lanes.size - 1) DividerHandle(ring, index, onGapRingDrag)
        }
    }
}

/** The settle spring — the snappy commit/return feel from DESIGN.md §5. */
private val settleSpring = androidx.compose.animation.core.spring<Float>(
    dampingRatio = 0.82f, stiffness = androidx.compose.animation.core.Spring.StiffnessMediumLow)

@Composable
private fun CarouselLane(ring: CarouselDeck, lane: Lane, base: File, modifier: Modifier) {
    val scope = rememberCoroutineScope()
    val drag = remember(lane.id) { Animatable(0f) }
    // Idle "motion is the arrow" channels, kept separate from `drag` so a real gesture can take
    // over mid-nudge (mirrors the iOS `nudge`/`pulse`).
    val nudgeX = remember(lane.id) { Animatable(0f) }   // horizontalBounce (swipe)
    val scale = remember(lane.id) { Animatable(1f) }    // shrinkPulse (pinch)
    val reachY = remember(lane.id) { Animatable(0f) }   // gapReach (drag)
    val breatheY = remember(lane.id) { Animatable(1f) } // gapBreathe (spread)

    val current = lane.current
    // Restart the idle loop when the container, its idle behavior, or its done flag changes.
    LaunchedEffect(current.id, current.idle, current.done) {
        nudgeX.snapTo(0f); scale.snapTo(1f); reachY.snapTo(0f); breatheY.snapTo(1f)
        if (current.done || current.idle == Idle.NONE) return@LaunchedEffect
        while (true) {
            kotlinx.coroutines.delay(1400)
            if (drag.value != 0f) continue
            when (current.idle) {
                Idle.HORIZONTAL_BOUNCE -> { nudgeX.animateTo(-22f, settleSpring); kotlinx.coroutines.delay(450); if (drag.value == 0f) { nudgeX.animateTo(16f, settleSpring); kotlinx.coroutines.delay(450) }; nudgeX.animateTo(0f, settleSpring) }
                Idle.SHRINK_PULSE -> { scale.animateTo(0.93f, settleSpring); kotlinx.coroutines.delay(450); scale.animateTo(1f, settleSpring) }
                Idle.GAP_REACH -> { reachY.animateTo(-10f, settleSpring); kotlinx.coroutines.delay(450); reachY.animateTo(0f, settleSpring) }
                Idle.GAP_BREATHE -> { breatheY.animateTo(0.95f, settleSpring); kotlinx.coroutines.delay(450); breatheY.animateTo(1f, settleSpring) }
                Idle.NONE -> {}
            }
            kotlinx.coroutines.delay(400)
        }
    }

    Box(modifier.pointerInput(lane.id, ring.lanes.size) {
        val widthPx = size.width.toFloat()
        detectHorizontalDragGestures(
            onDragStart = { scope.launch { nudgeX.snapTo(0f) } },
            onDragEnd = {
                scope.launch {
                    val threshold = widthPx * 0.22f
                    when {
                        // Editor focused: this drag was text, not a swipe — snap back.
                        ring.editorFocused && lane.current.kind == Kind.viewer -> drag.animateTo(0f, settleSpring)
                        // Commit glide: mutate the ring, drop the incoming container at the far
                        // edge, then glide it home — what's shown is never stale (the iOS trick).
                        drag.value <= -threshold -> { ring.advance(lane.id); drag.snapTo(widthPx); drag.animateTo(0f, settleSpring) }
                        drag.value >= threshold -> { ring.retreat(lane.id); drag.snapTo(-widthPx); drag.animateTo(0f, settleSpring) }
                        else -> drag.animateTo(0f, settleSpring)
                    }
                }
            },
        ) { _, dragAmount ->
            if (ring.editorFocused && lane.current.kind == Kind.viewer) return@detectHorizontalDragGestures
            scope.launch { drag.snapTo(drag.value + dragAmount) }
            if (lane.current.kind == Kind.swipe) lane.current.done = abs(drag.value) >= widthPx * 0.22f
        }
    }) {
        Panel(ring, lane.current, base, Modifier.fillMaxSize()
            .offset { IntOffset((drag.value + nudgeX.value).toInt(), reachY.value.toInt()) }
            .graphicsLayer {
                scaleX = scale.value; scaleY = scale.value * breatheY.value
                transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0.5f, 1f)
            }
            .padding(horizontal = Theme.sideGutter))
    }
}

@Composable
private fun DividerHandle(
    ring: CarouselDeck, index: Int,
    onRingDrag: ((delta: Float, done: Boolean) -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val minLanePx = with(density) { 80.dp.toPx() }
    // Pixel: the gap is also the ring's travel surface. Horizontal and vertical detectors are
    // both axis-locked, so whichever axis crosses touch slop first claims the drag — a resize
    // never becomes a ring swipe mid-gesture, and vice versa.
    val gapSwipe = if (onRingDrag == null) Modifier else Modifier.pointerInput(index) {
        detectHorizontalDragGestures(
            onDragEnd = { onRingDrag(0f, true) },
            onDragCancel = { onRingDrag(0f, true) },
        ) { _, dragAmount -> onRingDrag(dragAmount, false) }
    }
    Box(Modifier.fillMaxWidth().height(Theme.dividerGap).then(gapSwipe).pointerInput(index) {
        var acc = 0f
        detectVerticalDragGestures(
            onDragStart = { acc = 0f },
            onDragEnd = {
                // Onboarding: a finished Drag? lesson lingers as "Dragged." then morphs to Spread?.
                val lesson = ring.onStageLesson
                if (ring.isOnboarding && lesson?.kind == Kind.drag && lesson.done) {
                    scope.launch { kotlinx.coroutines.delay(700); ring.morphOnStageLesson(ContainerType.onboardingSpread()) }
                }
            },
        ) { _, dragAmount ->
            if (index + 1 >= ring.lanes.size) return@detectVerticalDragGestures
            val top = ring.lanes[index]; val bottom = ring.lanes[index + 1]
            val newTop = top.height + dragAmount; val newBottom = bottom.height - dragAmount
            if (newTop >= minLanePx && newBottom >= minLanePx) { top.height = newTop; bottom.height = newBottom }
            // The Drag? lesson flips to past tense once this is clearly a drag.
            acc += dragAmount
            val lesson = ring.onStageLesson
            if (ring.isOnboarding && lesson?.kind == Kind.drag && abs(acc) > 20f) lesson.done = true
        }
    }, contentAlignment = Alignment.Center) {
        Box(Modifier.width(40.dp).height(5.dp).background(Color(0x73FFFFFF), RoundedCornerShape(3.dp)))
    }
}

@Composable
private fun Panel(ring: CarouselDeck, type: ContainerType, base: File, modifier: Modifier) {
    Box(modifier.clip(RoundedCornerShape(Theme.cornerRadius)).background(Theme.container)) {
        when (type.kind) {
            Kind.gitHub -> GitHubSignInView()
            Kind.files -> FilesContainer(ring, base)
            Kind.viewer -> ViewerContainer(ring)
            Kind.graph -> GraphContainer(ring.workspace)
            Kind.terminal -> TerminalContainer(ring)
            else -> LessonPanel(type)
        }
        if (type.isOnboardingPreset) {
            Box(Modifier.fillMaxSize().border(1.dp, Theme.lessonStroke, RoundedCornerShape(Theme.cornerRadius)))
        }
        // Corner UI for real containers.
        if (!type.isOnboardingPreset) {
            Box(Modifier.align(Alignment.TopEnd)) { ActionChipsRow(ring) }
            if (type.kind == Kind.terminal) Box(Modifier.align(Alignment.TopStart)) { TerminalEngineChip(ring) }
        }
    }
}

@Composable
private fun LessonPanel(type: ContainerType) {
    if (type.title.isEmpty()) return
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        BasicText(type.displayTitle, style = TextStyle(fontFamily = Theme.mono, fontSize = Theme.lessonSize, color = Theme.onContainer))
    }
}

@Composable
private fun EdgeStrip(right: Boolean, modifier: Modifier, onDrag: (delta: Float, done: Boolean) -> Unit) {
    // Claim this edge band from Android's system back-gesture (API 29+), so an edge swipe reaches
    // the shell instead of navigating back/home. The iOS app has no such conflict — the screen
    // edge is already the app's.
    Box(modifier.fillMaxHeight().width(Theme.edgeZoneWidth).systemGestureExclusion().pointerInput(right) {
        detectHorizontalDragGestures(
            onDragEnd = { onDrag(0f, true) },
        ) { _, dragAmount -> onDrag(dragAmount, false) }
    })
}

// MARK: - Ring + lane mutations

private fun ringSwipe(
    delta: Float, done: Boolean, isRight: Boolean, strip: RingStrip,
    ringDrag: Animatable<Float, *>, widthPx: Float, scope: kotlinx.coroutines.CoroutineScope,
    setAdjacent: (Pair<CarouselDeck, Boolean>?) -> Unit, adjacent: Pair<CarouselDeck, Boolean>?,
) {
    if (!done) {
        val neighbor = strip.neighbor(isRight) ?: CarouselDeck.fresh().also { it.lanes[0].height = 0f }
        setAdjacent(neighbor to isRight)
        scope.launch { ringDrag.snapTo(if (isRight) minOf(0f, ringDrag.value + delta) else maxOf(0f, ringDrag.value + delta)) }
    } else {
        val threshold = widthPx * 0.22f
        val crossed = abs(ringDrag.value) >= threshold
        val outgoing = strip.current
        scope.launch {
            if (crossed && adjacent != null) {
                val (ring, right) = adjacent
                val existingIndex = strip.rings.indexOf(ring)
                if (existingIndex < 0) {
                    strip.rings.add(if (right) strip.currentIndex + 1 else strip.currentIndex, ring)
                    if (right) strip.currentIndex += 1
                } else strip.currentIndex = existingIndex
            }
            ringDrag.animateTo(0f); setAdjacent(null)
            // Graduation: an onboarding ring retires once you edge-swipe away from it.
            if (crossed && outgoing.isOnboarding && outgoing !== strip.current) {
                val idx = strip.rings.indexOf(outgoing)
                if (idx >= 0) {
                    strip.rings.removeAt(idx)
                    if (idx < strip.currentIndex) strip.currentIndex -= 1
                }
            }
        }
    }
}

private fun addLane(deck: CarouselDeck, heightPx: Float, dividerPx: Float, minLanePx: Float) {
    val newCount = deck.lanes.size + 1
    if (newCount > 6) return
    val usable = heightPx - dividerPx * (newCount - 1)
    if (usable < minLanePx * newCount) return
    val container = deck.containerForNewLane() ?: return
    val each = usable / newCount
    deck.lanes.forEach { it.height = each }
    deck.lanes.add(Lane(container, each))
}

private fun removeLane(deck: CarouselDeck, strip: RingStrip, heightPx: Float, dividerPx: Float) {
    if (deck.lanes.size <= 1) {
        // Pinching the last lane closes the ring; the strip never empties.
        if (deck.isOnboarding) return
        val removed = strip.currentIndex
        strip.rings.removeAt(removed)
        if (strip.rings.isEmpty()) { strip.rings.add(CarouselDeck.fresh()); strip.currentIndex = 0 }
        else strip.currentIndex = (removed - 1).coerceIn(0, strip.rings.size - 1)
        return
    }
    val released = deck.lanes.removeAt(deck.lanes.size - 1)
    if (!released.current.isOnboardingPreset) deck.release(released.current)
    val newCount = deck.lanes.size
    val usable = heightPx - dividerPx * (newCount - 1)
    deck.lanes.forEach { it.height = usable / newCount }
}

// MARK: - GitHub sign-in container

@Composable
fun GitHubSignInView() {
    val scope = rememberCoroutineScope()
    val mono = Theme.mono
    Box(Modifier.fillMaxSize().padding(Theme.containerPadding), contentAlignment = Alignment.Center) {
        when (val phase = GitHub.phase) {
            is GitHub.Phase.SignedOut -> BasicText("tap to sign in with GitHub",
                modifier = Modifier.clickable { scope.launch { GitHub.signIn() } },
                style = TextStyle(fontFamily = mono, fontSize = Theme.promptSize, color = Theme.onContainer, textAlign = TextAlign.Center))
            is GitHub.Phase.RequestingCode -> BasicText("requesting a device code…",
                style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.metadata))
            is GitHub.Phase.AwaitingAuthorization -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                BasicText("go to ${phase.url}", style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.metadata, textAlign = TextAlign.Center))
                Spacer(Modifier.height(12.dp))
                BasicText(phase.code, style = TextStyle(fontFamily = mono, fontSize = Theme.lessonSize, color = Theme.onContainer))
            }
            is GitHub.Phase.SignedIn -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                BasicText("signed in as ${phase.login}", style = TextStyle(fontFamily = mono, fontSize = Theme.promptSize, color = Theme.onContainer))
                Spacer(Modifier.height(12.dp))
                BasicText("sign out", modifier = Modifier.clickable { GitHub.signOut() },
                    style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.metadata))
            }
            is GitHub.Phase.Failed -> BasicText(phase.reason,
                modifier = Modifier.clickable { scope.launch { GitHub.signIn() } },
                style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.failure, textAlign = TextAlign.Center))
        }
    }
}
