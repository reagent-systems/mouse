package com.reagentsystems.mouse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import java.io.File

/**
 * One live document per file, app-wide — every ring viewing the same file binds to the same
 * buffer, so keystrokes in one are instantly the other's content (mirrors `FileBuffer.swift`).
 * Loaded at selection time so the viewer renders complete on its first frame.
 */
class FileBuffer private constructor() {
    var text by mutableStateOf("")
    var note by mutableStateOf<String?>(null)
    var hasDocument by mutableStateOf(false)
        private set

    private var loadedFile: File? = null
    private var loadedPath: String? = null
    private var loadedWorkspace: Workspace? = null
    private var loadedTreeVersion = -1
    private var dirty = false
    private var suppressNextChange = false

    private fun load(path: String?, workspace: Workspace?) {
        flush()
        if (path == null || workspace == null) {
            loadedFile = null; loadedPath = null; note = null; hasDocument = false
            suppressNextChange = true; text = ""; return
        }
        loadedPath = path; loadedWorkspace = workspace; loadedTreeVersion = workspace.treeVersion
        val file = File(workspace.root, path)
        val bytes = runCatching { file.readBytes() }.getOrNull()
        when {
            bytes == null -> { hasDocument = false; note = "couldn't read the file" }
            bytes.size >= 1_500_000 -> { hasDocument = false; note = "file is too large to view (${bytes.size / 1024} KB)" }
            bytes.any { it.toInt() == 0 } -> { hasDocument = false; note = "binary file" }
            else -> { note = null; suppressNextChange = true; text = String(bytes); dirty = false; loadedFile = file; hasDocument = true }
        }
    }

    /** Reload when a pull replaced the tree (discarding local edits, as the pull warned); else
     *  reload only if the selection changed. */
    fun ensure(path: String, workspace: Workspace) {
        if (workspace.treeVersion != loadedTreeVersion && loadedPath == path && loadedWorkspace === workspace) {
            dirty = false; load(path, workspace)
        } else if (loadedPath != path || loadedWorkspace !== workspace) {
            load(path, workspace)
        }
    }

    fun textDidChange() {
        if (suppressNextChange) { suppressNextChange = false; return }
        if (loadedFile == null) return
        dirty = true
        flush()   // simple immediate write (Android IO is cheap here); debounce can come later
    }

    fun flush() {
        if (!dirty) return
        val file = loadedFile ?: return
        runCatching { file.writeText(text) }.onSuccess { loadedPath?.let { p -> loadedWorkspace?.markModified(p) } }
        dirty = false
    }

    companion object {
        private val byFile = HashMap<String, FileBuffer>()
        fun shared(workspace: Workspace, path: String): FileBuffer {
            val key = workspace.root.path + "::" + path
            byFile[key]?.let { return it }
            return FileBuffer().also { it.load(path, workspace); byFile[key] = it }
        }
        fun flushAll() = byFile.values.forEach { it.flush() }
    }
}

@Composable
fun FilesContainer(deck: CarouselDeck, base: File) {
    val workspace = deck.workspace
    val mono = Theme.mono
    val scope = rememberCoroutineScope()

    if (workspace == null) {
        RepoPicker(deck, base)
        return
    }
    Column(Modifier.fillMaxSize().padding(Theme.containerPadding)) {
        BasicText(workspace.repoFullName, style = TextStyle(fontFamily = mono, fontSize = Theme.metaSize, color = Theme.metadata))
        Spacer(Modifier.height(8.dp))
        when (workspace.phase) {
            Workspace.Phase.DOWNLOADING -> BasicText("downloading…", style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.metadata))
            Workspace.Phase.FAILED -> Column {
                BasicText(workspace.failure ?: "download failed", style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.failure))
                Spacer(Modifier.height(8.dp))
                BasicText("tap to retry", modifier = Modifier.clickable { scope.launch { workspace.startDownload(GitHub.accessToken) } },
                    style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.secondary))
            }
            Workspace.Phase.READY -> FileTree(deck, workspace)
        }
    }
}

@Composable
private fun RepoPicker(deck: CarouselDeck, base: File) {
    val mono = Theme.mono
    val scope = rememberCoroutineScope()
    var repos by remember { mutableStateOf<List<RepoSummary>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(GitHub.accessToken) {
        val token = GitHub.accessToken ?: return@LaunchedEffect
        runCatching { RepoSummary.fetchMine(token) }.onSuccess { repos = it }.onFailure { error = it.message }
    }

    Column(Modifier.fillMaxSize().padding(Theme.containerPadding)) {
        BasicText("open a repo", style = TextStyle(fontFamily = mono, fontSize = Theme.metaSize, color = Theme.metadata))
        Spacer(Modifier.height(8.dp))
        when {
            GitHub.accessToken == null -> BasicText("sign in with the GitHub container first",
                style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.metadata))
            error != null -> BasicText(error!!, style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.failure))
            repos == null -> BasicText("loading your repos…", style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.metadata))
            else -> LazyColumn {
                items(repos!!) { repo ->
                    BasicText("${repo.fullName}${if (repo.isPrivate) "  (private)" else ""}",
                        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp).clickable {
                            val ws = Workspace.shared(base, repo.fullName)
                            deck.workspace = ws
                            scope.launch { ws.startDownload(GitHub.accessToken) }
                        },
                        style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.onContainer))
                }
            }
        }
    }
}

@Composable
private fun FileTree(deck: CarouselDeck, workspace: Workspace) {
    val mono = Theme.mono
    val expanded = remember { mutableStateOf(setOf<String>()) }

    fun rows(dir: File, prefix: String, depth: Int, into: MutableList<Triple<File, Int, String>>) {
        val entries = dir.listFiles()?.filter { it.name != ".git" }
            ?.sortedWith(compareByDescending<File> { it.isDirectory }.thenBy { it.name.lowercase() }) ?: return
        for (entry in entries) {
            val rel = if (prefix.isEmpty()) entry.name else "$prefix/${entry.name}"
            into.add(Triple(entry, depth, rel))
            if (entry.isDirectory && rel in expanded.value) rows(entry, rel, depth + 1, into)
        }
    }
    val flat = ArrayList<Triple<File, Int, String>>()
    rows(workspace.root, "", 0, flat)

    LazyColumn {
        items(flat) { (file, depth, rel) ->
            val open = deck.openFilePath == rel
            Row(Modifier.fillMaxWidth().background(if (open) Theme.lessonStroke else androidx.compose.ui.graphics.Color.Transparent)
                .clickable {
                    if (file.isDirectory) expanded.value = if (rel in expanded.value) expanded.value - rel else expanded.value + rel
                    else deck.openFile(rel)
                }.padding(vertical = 4.dp, horizontal = (depth * 12).dp)) {
                BasicText((if (file.isDirectory) (if (rel in expanded.value) "▾ " else "▸ ") else "  ") + file.name,
                    style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.onContainer))
            }
        }
    }
}

@Composable
fun ViewerContainer(deck: CarouselDeck) {
    val workspace = deck.workspace
    val path = deck.openFilePath
    val mono = Theme.mono
    if (workspace == null || path == null) {
        Box(Modifier.fillMaxSize().padding(Theme.containerPadding)) {
            BasicText("open a file in the Files container",
                style = TextStyle(fontFamily = mono, fontSize = Theme.promptSize, color = Theme.metadata))
        }
        return
    }
    val buffer = remember(workspace.root.path, path) { FileBuffer.shared(workspace, path) }
    LaunchedEffect(workspace.root.path, path, workspace.treeVersion) { buffer.ensure(path, workspace) }

    Column(Modifier.fillMaxSize().padding(Theme.containerPadding)) {
        BasicText(path, style = TextStyle(fontFamily = mono, fontSize = Theme.metaSize, color = Theme.metadata))
        Spacer(Modifier.height(8.dp))
        val note = buffer.note
        when {
            note != null -> BasicText(note, style = TextStyle(fontFamily = mono, fontSize = Theme.bodySize, color = Theme.secondary))
            buffer.hasDocument -> BasicTextField(
                value = buffer.text,
                onValueChange = { buffer.text = it; buffer.textDidChange() },
                textStyle = TextStyle(fontFamily = mono, fontSize = Theme.codeSize, color = Theme.onContainer),
                cursorBrush = SolidColor(Theme.onContainer),
                modifier = Modifier.fillMaxSize()
                    .onFocusChanged { deck.editorFocused = it.isFocused },
            )
        }
    }
}

/** Top-right action chips: push (∧) once there are edits, pull (∨) when upstream differs. */
object ActionChips {
    val inset = 8.dp
    val diameter = 22.dp
}

@Composable
fun ActionChipsRow(deck: CarouselDeck) {
    val workspace = deck.workspace ?: return
    if (workspace.phase != Workspace.Phase.READY) return
    if (GitHub.phase !is GitHub.Phase.SignedIn) return
    val scope = rememberCoroutineScope()

    var askingPush by remember { mutableStateOf(false) }
    var askingPull by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(workspace.repoFullName, workspace.treeVersion) {
        val token = GitHub.accessToken ?: return@LaunchedEffect
        workspace.refreshUpstream(token)
        workspace.refreshHistory(token)
    }

    Row(Modifier.padding(top = ActionChips.inset, end = ActionChips.inset + 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (workspace.hasChanges) Chip(pointingUp = true, red = failure != null) { askingPush = true }
        if (workspace.upstreamAvailable) Chip(pointingUp = false, red = false) { askingPull = true }
    }

    if (askingPush) AlertDialog(
        onDismissRequest = { askingPush = false },
        title = { Text("Commit ${workspace.modifiedPaths.size} file(s) to ${workspace.repoFullName}") },
        text = { OutlinedTextField(value = message, onValueChange = { message = it }, label = { Text("Commit message") }) },
        confirmButton = { TextButton(onClick = {
            askingPush = false; busy = true; failure = null
            val token = GitHub.accessToken
            val paths = workspace.modifiedPaths.toList()
            val commitMessage = message.ifEmpty { "Edit ${paths.size} file(s) from Mouse" }
            scope.launch {
                try {
                    val sha = GitHubPush.push(workspace.repoFullName, workspace.root, paths, commitMessage, token!!)
                    workspace.clearModified(); workspace.markSynced(sha)
                    GitHub.accessToken?.let { workspace.refreshHistory(it) }
                } catch (e: Exception) { failure = e.message } finally { busy = false; message = "" }
            }
        }) { Text("Commit & Push") } },
        dismissButton = { TextButton(onClick = { askingPush = false }) { Text("Cancel") } },
    )

    if (askingPull) AlertDialog(
        onDismissRequest = { askingPull = false },
        title = { Text("Pull the latest ${workspace.repoFullName}") },
        text = { Text(if (workspace.hasChanges) "Unpushed edits will be discarded." else "Re-download the latest tree.") },
        confirmButton = { TextButton(onClick = {
            askingPull = false
            scope.launch { workspace.startDownload(GitHub.accessToken) }
        }) { Text("Pull") } },
        dismissButton = { TextButton(onClick = { askingPull = false }) { Text("Cancel") } },
    )
}

@Composable
private fun Chip(pointingUp: Boolean, red: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(ActionChips.diameter).background(if (red) Theme.failure else Theme.onContainer, CircleShape).clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.foundation.Canvas(Modifier.size(12.dp)) {
            val w = size.width; val h = size.height
            val path = androidx.compose.ui.graphics.Path().apply {
                if (pointingUp) { moveTo(0f, h * 0.7f); lineTo(w / 2, h * 0.3f); lineTo(w, h * 0.7f) }
                else { moveTo(0f, h * 0.3f); lineTo(w / 2, h * 0.7f); lineTo(w, h * 0.3f) }
            }
            drawPath(path, Theme.container, style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2f))
        }
    }
}
