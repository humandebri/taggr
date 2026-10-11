package org.taggr.android.ui

import android.content.Context
import android.media.MediaPlayer
import android.net.Uri
import android.widget.VideoView
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay

internal class SelectedVideoView(context: Context) : VideoView(context) {
    private var preparedPlayer: MediaPlayer? = null
    var released = false
        private set

    fun trackSeek(player: MediaPlayer, completed: () -> Unit) {
        preparedPlayer?.setOnSeekCompleteListener(null)
        preparedPlayer = player
        player.setOnSeekCompleteListener { if (!released) completed() }
    }

    fun release() {
        if (released) return
        released = true
        preparedPlayer?.setOnSeekCompleteListener(null)
        preparedPlayer = null
        setOnPreparedListener(null)
        setOnErrorListener(null)
        setOnCompletionListener(null)
        stopPlayback()
    }
}

/** A picker-granted local URI only. No automatic playback or network video fetching. */
@Composable
internal fun SelectedVideoPreview(uri: Uri) {
    if (uri.scheme != "content" || uri.authority.isNullOrBlank()) {
        Text("Video preview unavailable. Choose the video again.")
        return
    }
    key(uri.toString()) {
        var view by remember { mutableStateOf<SelectedVideoView?>(null) }
        var ready by remember { mutableStateOf(false) }
        var playing by remember { mutableStateOf(false) }
        var failed by remember { mutableStateOf(false) }
        var position by rememberSaveable { mutableIntStateOf(0) }
        var duration by remember { mutableIntStateOf(0) }
        var scrubbing by remember { mutableStateOf<Float?>(null) }
        var seeking by remember { mutableStateOf(false) }
        val lifecycle = LocalLifecycleOwner.current.lifecycle
        var resumed by
            remember(lifecycle) {
                mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
            }
        DisposableEffect(view, lifecycle) {
            val player = view
            val observer = LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_RESUME) resumed = true
                if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) {
                    resumed = false
                    if (player?.released == false && player.duration > 0 && !seeking)
                        position = player.currentPosition.coerceAtLeast(0)
                    player?.takeUnless { it.released }?.pause()
                    playing = false
                }
            }
            lifecycle.addObserver(observer)
            onDispose { lifecycle.removeObserver(observer) }
        }
        LaunchedEffect(view, ready, resumed) {
            val player = view ?: return@LaunchedEffect
            if (!ready || !resumed) return@LaunchedEffect
            while (!player.released) {
                if (player.duration > 0) {
                    if (!seeking) position = player.currentPosition.coerceIn(0, duration)
                    playing = player.isPlaying
                }
                delay(250)
            }
        }
        AndroidView(
            factory = { context ->
                SelectedVideoView(context).apply {
                    view = this
                    setOnPreparedListener { media ->
                        if (!released) {
                            duration = media.duration.coerceAtLeast(0)
                            position = position.coerceIn(0, duration)
                            trackSeek(media) {
                                position = currentPosition.coerceIn(0, duration)
                                seeking = false
                            }
                            ready = true
                            seeking = true
                            seekTo(position.coerceAtLeast(1))
                        }
                    }
                    setOnCompletionListener { if (!released) playing = false }
                    setOnErrorListener { _, _, _ ->
                        if (!released) {
                            failed = true
                            ready = false
                            playing = false
                            seeking = false
                            scrubbing = null
                            release()
                        }
                        true
                    }
                    setVideoURI(uri)
                }
            },
            modifier =
                Modifier.fillMaxWidth().aspectRatio(16f / 9f).testTag("selected-video-preview"),
            onRelease = {
                if (it.duration > 0 && !seeking) position = it.currentPosition.coerceIn(0, duration)
                it.release()
            },
        )
        if (failed) Text("Video preview unavailable. You can choose another video.")
        else {
            Slider(
                value =
                    (scrubbing ?: position.toFloat()).coerceIn(
                        0f,
                        duration.coerceAtLeast(1).toFloat(),
                    ),
                valueRange = 0f..duration.coerceAtLeast(1).toFloat(),
                enabled = ready && duration > 0,
                onValueChange = { scrubbing = it },
                onValueChangeFinished = {
                    val player = view?.takeUnless { it.released } ?: return@Slider
                    scrubbing?.let {
                        position = it.toInt().coerceIn(0, duration)
                        seeking = true
                        player.seekTo(position)
                    }
                    scrubbing = null
                },
                modifier =
                    Modifier.fillMaxWidth().semantics {
                        contentDescription = "Video preview position"
                    },
            )
            Text(
                "${previewTime(position)} / ${previewTime(duration)}",
                style = MaterialTheme.typography.bodySmall,
            )
            TextButton(
                enabled = ready,
                onClick = {
                    val player = view?.takeUnless { it.released } ?: return@TextButton
                    if (playing) player.pause() else player.start()
                    playing = !playing
                },
            ) {
                Text(if (playing) "Pause preview" else "Play preview")
            }
        }
    }
}

private fun previewTime(milliseconds: Int): String {
    val seconds = milliseconds.coerceAtLeast(0) / 1000
    return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
}
