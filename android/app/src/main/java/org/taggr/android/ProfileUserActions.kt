package org.taggr.android

import androidx.compose.material3.*
import androidx.compose.runtime.*

internal val LocalProfileChanged = staticCompositionLocalOf<() -> Unit> { {} }

@Composable
internal fun ProfileMuteControl(
    interactable: Boolean,
    muted: Boolean,
    busy: Boolean,
    identity: Any? = Unit,
    change: (Boolean) -> Unit,
) {
    if (!interactable) return
    var review by remember(identity) { mutableStateOf(false) }
    TextButton(onClick = { if (muted) change(false) else review = true }, enabled = !busy) {
        Text(if (muted) "Unmute" else "Mute")
    }
    if (review)
        AlertDialog(
            onDismissRequest = { if (!busy) review = false },
            title = { Text("Mute this user?") },
            text = {
                Text(
                    "Their posts will be hidden from filtered feeds and you will unfollow them. You can still open their profile. Following them again will unmute them."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        review = false
                        change(true)
                    },
                    enabled = !busy,
                ) {
                    Text("Mute")
                }
            },
            dismissButton = {
                TextButton(onClick = { review = false }, enabled = !busy) { Text("Cancel") }
            },
        )
}
