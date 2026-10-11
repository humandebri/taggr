package org.taggr.android.ui

import android.text.format.DateFormat
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import org.taggr.android.data.PostTime

@Composable
internal fun PostTimestamp(timestampMillis: Long, modifier: Modifier = Modifier) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val locale = LocalConfiguration.current.locales[0]
    var now by remember(timestampMillis) { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(lifecycle, timestampMillis) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (isActive) {
                now = System.currentTimeMillis()
                delay(PostTime.refreshMillis(timestampMillis, now))
            }
        }
    }
    val label =
        PostTime.label(
            timestampMillis,
            now,
            locale,
            datePattern = DateFormat.getBestDateTimePattern(locale, "MMMd"),
            oldDatePattern = DateFormat.getBestDateTimePattern(locale, "yyMMMd"),
        )
    Text(
        label,
        modifier.semantics { contentDescription = "Posted $label" },
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}
