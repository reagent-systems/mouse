package com.reagentsystems.mouse

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The design language in one place (see DESIGN.md): one mono typeface, black containers on a
 * white canvas, generous radii, monochrome with the graph rails as the only exception.
 */
object Theme {
    val mono = FontFamily(Font(R.font.ibm_plex_mono_bold, FontWeight.Bold))

    val canvas = Color.White
    val container = Color.Black
    val onContainer = Color.White
    val secondary = Color(0xB3FFFFFF)   // white @ 0.7
    val metadata = Color(0x8CFFFFFF)    // white @ 0.55
    val failure = Color(0xFFE53935)
    val lessonStroke = Color(0x59FFFFFF)

    val cornerRadius = 32.dp
    val sideGutter = 24.dp
    val edgeLessonGutter = 40.dp
    val containerPadding = 16.dp
    val dividerGap = 32.dp
    val lessonDividerGap = 48.dp
    val edgeZoneWidth = 32.dp

    // Type scale (see DESIGN.md §3)
    val lessonSize = 28.sp
    val promptSize = 14.sp
    val bodySize = 13.sp
    val codeSize = 12.sp
    val metaSize = 11.sp

    // Graph rails — the sanctioned color exception.
    val railColors = listOf(
        Color(0xFFFF9800), Color(0xFFE91E63), Color(0xFF00BCD4), Color(0xFF4CAF50),
        Color(0xFF9C27B0), Color(0xFFFFEB3B), Color(0xFF2196F3), Color(0xFFF44336),
    )
    fun rail(lane: Int): Color = railColors[((lane % railColors.size) + railColors.size) % railColors.size]
}
