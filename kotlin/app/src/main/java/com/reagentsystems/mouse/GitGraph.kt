package com.reagentsystems.mouse

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class CommitNode(val sha: String, val message: String, val author: String, val parents: List<String>)

/** One rendered graph row: the commit's column, rail state around it, joins/opens. */
data class GraphRow(
    val commit: CommitNode,
    val column: Int,
    val lanesBefore: List<String?>,
    val lanesAfter: List<String?>,
    val joins: List<Int>,
    val opens: List<Int>,
)

object GitGraph {
    data class History(val commits: List<CommitNode>, val branchTips: Map<String, String>)

    /**
     * Classic commit-graph lane assignment, newest first — the same algorithm the Swift app
     * verifies against branch/merge topologies. Each rail carries the sha it expects next.
     */
    fun layout(commits: List<CommitNode>): List<GraphRow> {
        val lanes = ArrayList<String?>()
        val rows = ArrayList<GraphRow>()
        for (commit in commits) {
            val lanesBefore = ArrayList(lanes)
            val joins = ArrayList<Int>()
            val expecting = lanes.indices.filter { lanes[it] == commit.sha }
            val column: Int
            if (expecting.isNotEmpty()) {
                column = expecting.first()
                for (other in expecting.drop(1)) { lanes[other] = null; joins.add(other) }
            } else {
                val free = lanes.indexOfFirst { it == null }
                if (free >= 0) column = free else { column = lanes.size; lanes.add(null) }
            }
            lanes[column] = commit.parents.firstOrNull()

            val opens = ArrayList<Int>()
            for (parent in commit.parents.drop(1)) {
                val existing = lanes.indexOf(parent)
                if (existing >= 0) opens.add(existing)
                else {
                    val free = lanes.indexOfFirst { it == null }
                    if (free >= 0 && free != column) { lanes[free] = parent; opens.add(free) }
                    else { lanes.add(parent); opens.add(lanes.size - 1) }
                }
            }
            rows.add(GraphRow(commit, column, lanesBefore, ArrayList(lanes), joins, opens))
        }
        return rows
    }

    suspend fun fetchHistory(repo: String, token: String): History = withContext(Dispatchers.IO) {
        val commitsData = GitHub.getBytes("https://api.github.com/repos/$repo/commits?per_page=80", token)
        val branchesData = runCatching {
            GitHub.getBytes("https://api.github.com/repos/$repo/branches?per_page=50", token)
        }.getOrNull()

        val commitsArray = JSONArray(String(commitsData))
        val commits = (0 until commitsArray.length()).map {
            val o = commitsArray.getJSONObject(it)
            val inner = o.getJSONObject("commit")
            CommitNode(
                sha = o.getString("sha"),
                message = inner.getString("message").substringBefore("\n"),
                author = inner.optJSONObject("author")?.optString("name") ?: "",
                parents = o.getJSONArray("parents").let { p -> (0 until p.length()).map { i -> p.getJSONObject(i).getString("sha") } },
            )
        }
        val tips = HashMap<String, String>()
        if (branchesData != null) {
            val array = JSONArray(String(branchesData))
            for (i in 0 until array.length()) {
                val b = array.getJSONObject(i)
                tips[b.getJSONObject("commit").getString("sha")] = b.getString("name")
            }
        }
        History(commits, tips)
    }
}

@Composable
fun GraphContainer(workspace: Workspace?) {
    val mono = Theme.mono
    if (workspace == null) {
        BasicText("open a repo in the Files container",
            style = TextStyle(fontFamily = mono, fontSize = Theme.promptSize, color = Theme.metadata))
        return
    }
    Column(Modifier.padding(Theme.containerPadding)) {
        BasicText("${workspace.repoFullName} — history",
            style = TextStyle(fontFamily = mono, fontSize = Theme.metaSize, color = Theme.metadata))
        Spacer(Modifier.height(8.dp))
        val rows = workspace.graphRows
        when {
            rows != null -> LazyColumn {
                items(rows) { row -> GraphRowView(row, workspace.graphTips) }
            }
            workspace.graphError != null -> BasicText(workspace.graphError!!,
                style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.secondary))
            GitHub.accessToken == null -> BasicText("sign in with the GitHub container first",
                style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.metadata))
            else -> BasicText("loading…",
                style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.metadata))
        }
    }
}

@Composable
private fun GraphRowView(row: GraphRow, tips: Map<String, String>) {
    val laneWidth = 14.dp
    val rowHeight = 34.dp
    Row(Modifier.fillMaxWidth().height(rowHeight)) {
        val laneCount = maxOf(row.lanesBefore.size, row.lanesAfter.size, row.column + 1)
        Canvas(Modifier.width(laneWidth * laneCount).height(rowHeight)) {
            val lw = laneWidth.toPx()
            val midY = size.height / 2
            fun x(lane: Int) = lw * lane + lw / 2
            // Pass-through verticals.
            for (lane in 0 until laneCount) {
                val before = row.lanesBefore.getOrNull(lane)
                val after = row.lanesAfter.getOrNull(lane)
                if (before != null || after != null) {
                    drawLine(Theme.rail(lane), Offset(x(lane), 0f), Offset(x(lane), size.height), strokeWidth = 2f)
                }
            }
            // The commit dot.
            drawCircle(Theme.rail(row.column), radius = lw * 0.28f, center = Offset(x(row.column), midY))
        }
        Column(Modifier.padding(start = 6.dp)) {
            val label = tips[row.commit.sha]?.let { "[$it] " } ?: ""
            BasicText("$label${row.commit.message}",
                style = TextStyle(fontFamily = Theme.mono, fontSize = Theme.bodySize, color = Theme.onContainer))
            BasicText("${row.commit.sha.take(7)}  ${row.commit.author}",
                style = TextStyle(fontFamily = Theme.mono, fontSize = Theme.metaSize, color = Theme.metadata))
        }
    }
}
