package com.reagentsystems.mouse

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * Snapshot/restore of the ring strip as one JSON file (mirrors `StripPersistence.swift`). The
 * live model relies on reference identity (shared workspaces), which is re-linked through the
 * registries on restore rather than round-tripped.
 */
object StripPersistence {
    private fun fileFor(base: File) = File(base, "ring-strip.json")

    fun save(base: File, strip: RingStrip) {
        val rings = JSONArray()
        for (ring in strip.rings) {
            val lanes = JSONArray()
            for (lane in ring.lanes) lanes.put(JSONObject()
                .put("kind", lane.current.kind).put("id", lane.current.id.toString())
                .put("done", lane.current.done).put("height", lane.height.toDouble()))
            val reserve = JSONArray()
            for (c in ring.reserve) reserve.put(JSONObject().put("kind", c.kind).put("id", c.id.toString()))
            rings.put(JSONObject()
                .put("isOnboarding", ring.isOnboarding)
                .put("lanes", lanes).put("reserve", reserve)
                .apply {
                    ring.workspace?.let { ws ->
                        put("workspaceRepo", ws.repoFullName)
                        put("openFile", ring.openFilePath ?: JSONObject.NULL)
                        put("workspaceDirty", JSONArray(ws.modifiedPaths.sorted()))
                        put("workspaceSyncedSha", ws.syncedSha ?: JSONObject.NULL)
                    }
                })
        }
        val root = JSONObject().put("currentIndex", strip.currentIndex).put("rings", rings)
        runCatching { fileFor(base).writeText(root.toString()) }
    }

    fun load(base: File): RingStrip? {
        val text = runCatching { fileFor(base).readText() }.getOrNull() ?: return null
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return null
        val ringsJson = root.optJSONArray("rings") ?: return null
        if (ringsJson.length() == 0) return null

        val rings = ArrayList<CarouselDeck>()
        for (r in 0 until ringsJson.length()) {
            val ringJson = ringsJson.getJSONObject(r)
            val lanesJson = ringJson.optJSONArray("lanes") ?: return null
            if (lanesJson.length() == 0) return null
            val lanes = ArrayList<Lane>()
            for (l in 0 until lanesJson.length()) {
                val laneJson = lanesJson.getJSONObject(l)
                lanes.add(Lane(restore(laneJson), laneJson.optDouble("height", 0.0).toFloat()))
            }
            val reserveJson = ringJson.optJSONArray("reserve") ?: JSONArray()
            val reserve = (0 until reserveJson.length()).map { restore(reserveJson.getJSONObject(it)) }
            val deck = CarouselDeck(lanes, reserve, ringJson.optBoolean("isOnboarding", false))

            ringJson.optString("workspaceRepo", "").takeIf { it.isNotEmpty() }?.let { repo ->
                val dirty = ringJson.optJSONArray("workspaceDirty")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
                val synced = ringJson.optStringOrNull("workspaceSyncedSha")
                Workspace.existing(base, repo, dirty, synced)?.let { ws ->
                    deck.workspace = ws
                    deck.openFile(ringJson.optStringOrNull("openFile"))
                }
            }
            rings.add(deck)
        }
        return RingStrip(rings, root.optInt("currentIndex", 0))
    }

    private fun restore(json: JSONObject): ContainerType {
        val kind = json.getInt("kind")
        val id = runCatching { UUID.fromString(json.getString("id")) }.getOrDefault(UUID.randomUUID())
        val finished = json.optBoolean("done", false)
        val container = when (kind) {
            Kind.swipe -> ContainerType.onboardingSwipe(id)
            Kind.drag -> if (finished) ContainerType.onboardingSpread() else ContainerType.onboardingDrag(id)
            Kind.spread -> if (finished) ContainerType.onboardingBlank() else ContainerType.onboardingSpread(id)
            Kind.pinch -> ContainerType.onboardingPinch(id)
            Kind.blank -> ContainerType.onboardingBlank(id)
            else -> ContainerType.entry(kind, id)
        }
        if (finished && container.kind == kind) container.done = true
        return container
    }

    /**
     * An absent key, an empty string, or a JSON null all mean "nothing here".
     *
     * `optString` alone does NOT: `save` writes `JSONObject.NULL` for a ring with no open file,
     * and Android's `optString` renders that as the four-character string "null" rather than
     * falling back. A ring saved with nothing open therefore reopened with a file named `null`,
     * and the viewer greeted you with "couldn't read the file" on every launch.
     */
    private fun JSONObject.optStringOrNull(key: String): String? {
        if (isNull(key)) return null
        return optString(key, "").ifEmpty { null }
    }
}
