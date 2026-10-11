package org.taggr.android

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import org.taggr.android.data.*

/** Explicit Google actions only; shared connection contains no persisted token. */
@Composable
internal fun YouTubeAccountPanel(
    owner: String?,
    currentOwner: () -> String?,
    access: YouTubeAuthorization.Access?,
    changed: (YouTubeAuthorization.Access?) -> Unit,
    authorization: GoogleYouTubeAuth? = null,
) {
    val context = LocalContext.current
    val auth = remember(authorization) { authorization ?: GoogleYouTubeAuth(context) }
    val scope = rememberCoroutineScope()
    var busy by remember(owner) { mutableStateOf(false) }
    var error by remember(owner) { mutableStateOf<String?>(null) }
    var confirming by remember(owner) { mutableStateOf(false) }
    fun checkOwner() {
        require(currentOwner() == owner) { "Return to the original TAGGR account." }
    }
    fun perform(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try {
                checkOwner()
                block()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Exception) {
                error =
                    "YouTube connection could not be updated. Return to this account and try again."
            } finally {
                busy = false
            }
        }
    }
    val consent =
        rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {
            result ->
            if (result.resultCode == Activity.RESULT_OK && result.data != null)
                perform {
                    val connected = auth.finish(result.data!!, access?.account, access?.channel?.id)
                    checkOwner()
                    require(connected is YouTubeAuthorization.Access)
                    changed(connected)
                }
            else error = "YouTube connection was cancelled."
        }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("YouTube", style = MaterialTheme.typography.titleMedium)
            if (access == null) {
                Text(
                    "Connect a YouTube channel to upload videos selected in TAGGR.",
                    style = MaterialTheme.typography.bodySmall,
                )
                TextButton(
                    enabled = !busy,
                    onClick = {
                        perform {
                            val connected = auth.authorize()
                            checkOwner()
                            when (connected) {
                                is YouTubeAuthorization.Access -> changed(connected)
                                is YouTubeAuthorization.Resolution ->
                                    consent.launch(
                                        IntentSenderRequest.Builder(
                                                connected.pendingIntent.intentSender
                                            )
                                            .build()
                                    )
                            }
                        }
                    },
                ) {
                    Text(if (busy) "Connecting…" else "Connect YouTube")
                }
            } else {
                Text(access.channel.title, style = MaterialTheme.typography.titleSmall)
                Text(
                    "Videos selected in TAGGR are uploaded directly to this channel.",
                    style = MaterialTheme.typography.bodySmall,
                )
                TextButton(enabled = !busy, onClick = { confirming = true }) {
                    Text("Disconnect YouTube")
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (busy) CircularProgressIndicator()
        }
    }
    if (confirming)
        AlertDialog(
            onDismissRequest = { if (!busy) confirming = false },
            title = { Text("Disconnect YouTube?") },
            text = {
                Text(
                    "This pauses video sending and revokes Google authorization for the connected account. Saved upload progress remains. Reconnect the same account and channel to resume. Uploaded videos remain on YouTube."
                )
            },
            confirmButton = {
                TextButton(
                    enabled = !busy,
                    onClick = {
                        confirming = false
                        perform {
                            val original = requireNotNull(access)
                            YouTubeBackground.pauseAndWait(context)
                            checkOwner()
                            auth.revoke(original.account)
                            checkOwner()
                            changed(null)
                        }
                    },
                ) {
                    Text("Disconnect")
                }
            },
            dismissButton = {
                TextButton(enabled = !busy, onClick = { confirming = false }) {
                    Text("Keep connected")
                }
            },
        )
}
