package com.reagentsystems.mouse.node

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * The event loop's BOOKKEEPING — timers, immediates, handles, exit code — with none of the
 * platform's scheduling in it.
 *
 * ## Why this is a separate, pure object
 *
 * iOS runs `NodeEngine.runEventLoop()`: a `while` loop on a background queue that drains jobs,
 * then port deliveries, then immediates, then the earliest due timer, and blocks on a semaphore
 * in between. Android cannot copy that shape. JavaScript in a WebView runs on the thread that
 * owns the WebView, which is the main thread, and a `while` loop there is an ANR. So the LOOP is
 * inverted — Android's `Looper` drives it, one `Handler` message per turn — while the DECISIONS
 * the loop makes stay here, unchanged and testable:
 *
 *  - ordering: every ready immediate runs before any timer, as a batch snapshot;
 *  - a repeating timer re-arms from NOW, not from its old due time (iOS: `Date().addingTimeInterval`);
 *  - an unref'd timer is not a reason to stay alive. "A process whose only remaining work is a
 *    watchdog should exit, and node's does" — the comment on the iOS loop, and the rule that
 *    [isQuiescent] encodes;
 *  - an open handle or a live stdin listener holds the loop open even with no timers at all.
 *
 * ## Threading
 *
 * `@JavascriptInterface` methods do NOT run on the caller's thread — the WebView dispatches them
 * onto its own JavaBridge thread — while the dispatch back into JS must happen on the WebView's
 * thread. So this object is touched from two threads by construction and takes a lock. That is
 * also why it holds no JS values: only ids cross.
 */
class NodeLoop {

    data class Timer(
        val id: Int,
        val dueNanos: Long,
        /** The delay it was created with. `refresh()` restarts THIS, not the time left. */
        val delayMs: Long,
        /** Milliseconds between repeats, or null for a one-shot. */
        val intervalMs: Long?,
        val refed: Boolean,
    )

    private val lock = ReentrantLock()
    private var nextId = 1
    private val timers = LinkedHashMap<Int, Timer>()
    private val immediates = ArrayList<Int>()
    private var holds = 0

    /** True while JavaScript has a live stdin listener. Holds the loop open, as on iOS. */
    var stdinActive: Boolean = false
        get() = lock.withLock { field }
        set(value) = lock.withLock { field = value }

    /** Set by `process.exit`. Non-null stops the loop; the host reports it as the run's status. */
    var exitCode: Int? = null
        get() = lock.withLock { field }
        set(value) = lock.withLock { if (field == null) field = value }

    // ------------------------------------------------------------------ timers ----

    fun setTimer(delayMs: Long, repeat: Boolean, nowNanos: Long): Int = lock.withLock {
        val id = nextId++
        timers[id] = Timer(
            id = id,
            dueNanos = nowNanos + delayMs * 1_000_000L,
            delayMs = delayMs,
            intervalMs = if (repeat) delayMs else null,
            refed = true,
        )
        id
    }

    fun clearTimer(id: Int) = lock.withLock { timers.remove(id); Unit }

    fun refTimer(id: Int, refed: Boolean) = lock.withLock {
        timers[id]?.let { timers[id] = it.copy(refed = refed) }
        Unit
    }

    /**
     * node's `timeout.refresh()`: restart the ORIGINAL delay from now. Not the time remaining —
     * that would make a repeatedly-refreshed idle timer converge on firing instantly, which is
     * the opposite of what every keep-alive that calls it wants.
     */
    fun refreshTimer(id: Int, nowNanos: Long) = lock.withLock {
        timers[id]?.let { timers[id] = it.copy(dueNanos = nowNanos + it.delayMs * 1_000_000L) }
        Unit
    }

    /** The earliest-due timer, ref'd or not. Peek only — nothing is consumed. */
    fun earliest(): Timer? = lock.withLock { timers.values.minByOrNull { it.dueNanos } }

    /**
     * Claim the earliest timer that is due at [nowNanos], re-arming it if it repeats. Returns null
     * when nothing is ready. Claiming BEFORE the callback runs is what stops one long callback
     * from firing the same one-shot twice.
     */
    fun claimDue(nowNanos: Long): Timer? = lock.withLock {
        val next = timers.values.filter { it.dueNanos <= nowNanos }.minByOrNull { it.dueNanos }
            ?: return@withLock null
        if (next.intervalMs != null) {
            // From NOW, not from the old due time: a callback that overran its interval must not
            // leave a backlog of instantly-due repeats behind it.
            timers[next.id] = next.copy(dueNanos = nowNanos + next.intervalMs * 1_000_000L)
        } else {
            timers.remove(next.id)
        }
        next
    }

    // -------------------------------------------------------------- immediates ----

    fun setImmediate(): Int = lock.withLock {
        val id = nextId++
        immediates.add(id)
        id
    }

    fun clearImmediate(id: Int) = lock.withLock { immediates.remove(id); Unit }

    /**
     * Take the whole immediate queue as one batch, the way the iOS loop does
     * (`let batch = immediates; immediates = []`). An immediate scheduled BY an immediate belongs
     * to the next turn, not this one — draining a live queue instead would starve timers forever.
     */
    fun takeImmediates(): List<Int> = lock.withLock {
        if (immediates.isEmpty()) return@withLock emptyList()
        val batch = ArrayList(immediates)
        immediates.clear()
        batch
    }

    // ------------------------------------------------------------------ handles ----

    /** `bridge.loopHold`. An open handle keeps the process alive with nothing else scheduled. */
    fun hold(on: Boolean) = lock.withLock {
        if (on) holds += 1 else if (holds > 0) holds -= 1
        Unit
    }

    fun openHandles(): Int = lock.withLock { holds }

    // ----------------------------------------------------------------- the rule ----

    /**
     * Is there any reason left to stay alive? The iOS loop's exit condition, verbatim in intent:
     * no REF'D timer, no open handle, no live stdin listener. Immediates count because they are
     * work already queued.
     */
    fun isQuiescent(): Boolean = lock.withLock {
        immediates.isEmpty() && holds == 0 && !stdinActive && timers.values.none { it.refed }
    }

    /**
     * How long the host should sleep before the next turn, in milliseconds: 0 when work is ready
     * now, null when there is nothing scheduled at all (the caller then either parks on a handle
     * or ends the run, per [isQuiescent]).
     */
    fun nextWaitMillis(nowNanos: Long): Long? = lock.withLock {
        if (immediates.isNotEmpty()) return@withLock 0L
        val next = timers.values.minByOrNull { it.dueNanos } ?: return@withLock null
        ((next.dueNanos - nowNanos + 999_999L) / 1_000_000L).coerceAtLeast(0L)
    }

    fun timerCount(): Int = lock.withLock { timers.size }
}
