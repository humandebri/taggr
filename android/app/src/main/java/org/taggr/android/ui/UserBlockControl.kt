package org.taggr.android.ui

import androidx.compose.material3.*
import androidx.compose.runtime.*

@Composable
internal fun UserBlockControl(
    target: Long,
    name: String,
    viewer: Long?,
    scope: String?,
    blocked: Boolean,
    busy: Boolean,
    select: (Boolean) -> Unit,
) {
    var shown by remember(target, scope, blocked, viewer) { mutableStateOf(false) }
    if (viewer == target) return
    TextButton(onClick = { shown = true }, enabled = !busy) {
        Text(if (blocked) "Unblock" else "Block")
    }
    if (shown)
        AlertDialog(
            onDismissRequest = { if (!busy) shown = false },
            title = { Text(if (blocked) "Unblock $name?" else "Block $name?") },
            text = {
                Text(
                    if (blocked) "Your personal block of $name will be removed."
                    else "$name's content will immediately be hidden in this app."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        shown = false
                        select(!blocked)
                    },
                    enabled = !busy,
                ) {
                    Text(if (blocked) "Unblock" else "Block")
                }
            },
            dismissButton = {
                TextButton(onClick = { shown = false }, enabled = !busy) { Text("Cancel") }
            },
        )
}
