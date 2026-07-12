package com.reagentsystems.mouse

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Mouse for Android — the seed. One Mouse-styled container (white canvas, black panel,
 * IBM Plex Mono) holding a real `/system/bin/sh` terminal. The ring/lane shell, workspaces,
 * and the rest of the interaction model follow the Swift app's spec (swift/README.md);
 * everything here obeys the same design language (DESIGN.md).
 */
class MainActivity : ComponentActivity() {

    private lateinit var shell: ShellSession

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        shell = ShellSession(filesDir)
        setContent { TerminalScreen(shell) }
    }

    override fun onDestroy() {
        shell.destroy()
        super.onDestroy()
    }
}

private val plexMono = FontFamily(Font(R.font.ibm_plex_mono_bold, FontWeight.Bold))

private val terminalText = TextStyle(
    fontFamily = plexMono,
    fontWeight = FontWeight.Bold,
    fontSize = 12.sp,
    lineHeight = 14.4.sp,   // 1.2× fixed, like the iOS app
    color = Color.White
)

@androidx.compose.runtime.Composable
private fun TerminalScreen(shell: ShellSession) {
    var prompt by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    // Follow new output, like the iOS terminal's bottom anchor.
    LaunchedEffect(shell.lines.size) {
        if (shell.lines.isNotEmpty()) listState.scrollToItem(shell.lines.size - 1)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.White)
            .imePadding()
            .padding(24.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black, RoundedCornerShape(32.dp))
                .padding(16.dp)
        ) {
            LazyColumn(state = listState, modifier = Modifier.weight(1f)) {
                itemsIndexed(shell.lines) { _, line ->
                    BasicText(text = line, style = terminalText)
                }
            }
            BasicTextField(
                value = prompt,
                onValueChange = { prompt = it },
                textStyle = terminalText,
                cursorBrush = SolidColor(Color.White),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = {
                    val command = prompt.trim()
                    if (command.isNotEmpty()) shell.send(command)
                    prompt = ""
                }),
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}
