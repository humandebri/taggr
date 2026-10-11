package org.taggr.android.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

private val colors =
    darkColorScheme(
        background = Color(0xFF1E1E23),
        surface = Color(0xFF26262B),
        surfaceVariant = Color(0xFF2B2B31),
        onBackground = Color(0xFFE0E0CF),
        onSurface = Color(0xFFE0E0CF),
        onSurfaceVariant = Color(0xFFA0A092),
        primary = Color(0xFF30D5C8),
        tertiary = Color(0xFFFFD700),
        onTertiary = Color(0xFF111111),
        onPrimary = Color(0xFF111111),
        secondary = Color(0xFF30D5C8),
    )

@Composable
fun TaggrTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colors) {
        Surface(
            Modifier.fillMaxSize(),
            color = colors.background,
            contentColor = colors.onBackground,
        ) {
            content()
        }
    }
}
