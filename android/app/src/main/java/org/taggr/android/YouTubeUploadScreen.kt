package org.taggr.android

import android.app.Activity
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.withLock
import org.taggr.android.data.*

private val youtubeDispatch
    get() = YouTubeBackground.dispatch

/** Foreground controls for account-bound OS transfer and durable draft insertion. */
@Composable
internal fun YouTubeUploadScreen(
    owner: String,
    network: String,
    canister: String,
    draftSlot: String,
    currentOwner: () -> String?,
    insert: (YouTubeUploadJob) -> Unit,
    close: () -> Unit,
    authorization: GoogleYouTubeAuth? = null,
    jobStore: YouTubeUploadJobStore? = null,
    initialAccess: YouTubeAuthorization.Access? = null,
    connectionChanged: (YouTubeAuthorization.Access?) -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val auth = remember(authorization) { authorization ?: GoogleYouTubeAuth(context) }
    val store = remember(jobStore) { jobStore ?: YouTubeUploadJobStore(context) }
    val transport = remember { YouTubeUploadTransport() }
    var access by remember { mutableStateOf<YouTubeAuthorization.Access?>(null) }
    var job by remember { mutableStateOf<YouTubeUploadJob?>(null) }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var work by remember { mutableStateOf<Job?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var cancelConfirmation by remember { mutableStateOf(false) }
    var disconnectConfirmation by remember { mutableStateOf(false) }
    var restoreFailed by remember { mutableStateOf(false) }
    var discardSnapshot by remember { mutableStateOf<YouTubeUploadDiscardSnapshot?>(null) }
    var discardConfirmation by remember { mutableStateOf(false) }
    var backgroundRunning by remember { mutableStateOf(false) }
    val notifications =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(job?.id, backgroundRunning) {
        val initial = job ?: return@LaunchedEffect
        while (true) {
            try {
                val progress = store.progress(initial.target)
                if (progress?.id == initial.id) job = progress
                backgroundRunning = YouTubeBackground.isRunning(context)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                error = "Upload progress could not be read. Reopen the original draft."
                break
            }
            if (!backgroundRunning) break
            delay(1000)
        }
    }
    fun target(channel: String) = YouTubeDraftTarget(owner, network, canister, channel, draftSlot)
    fun checkOwner() {
        require(currentOwner() == owner) { "Return to the original TAGGR account." }
    }
    fun perform(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        work = scope.launch {
            try {
                checkOwner()
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                error =
                    "This action could not finish. Reconnect YouTube or reopen this draft to try again."
            } finally {
                busy = false
            }
        }
    }
    suspend fun accept(value: YouTubeAuthorization) {
        checkOwner()
        if (value is YouTubeAuthorization.Access) {
            access = value
            connectionChanged(value)
            try {
                val saved = store.load(target(value.channel.id), System.currentTimeMillis())
                require(
                    saved?.googleAccountEmail == null ||
                        saved.googleAccountEmail == value.account.name
                )
                job = saved
                restoreFailed = false
                discardSnapshot = null
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                job = null
                restoreFailed = true
                discardSnapshot = store.discardSnapshot()
                error =
                    "The saved upload could not be restored. It may belong to another account, channel or draft, have expired, or contain unavailable data."
            }
        }
    }
    LaunchedEffect(initialAccess) {
        try {
            if (initialAccess != null) accept(initialAccess) else access = null
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (_: Exception) {
            access = null
            error = "Return to the original account and reconnect YouTube."
        }
    }
    val consent =
        rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {
            result ->
            if (result.resultCode == Activity.RESULT_OK && result.data != null)
                perform {
                    accept(auth.finish(result.data!!, access?.account, job?.target?.channelId))
                }
            else error = "YouTube connection was cancelled."
        }
    val picker =
        rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
            if (uri != null) selected = uri.toString()
        }
    suspend fun runUpload() = youtubeDispatch.withLock {
        val connected = requireNotNull(access)
        val expected = target(connected.channel.id)
        val runner =
            YouTubeUploadRunner(transport, { old, new -> store.save(new, old) }, store::source)
        var saved = requireNotNull(store.progress(expected))
        require(
            saved.googleAccountEmail == null || saved.googleAccountEmail == connected.account.name
        )
        if (saved.googleAccountEmail == null) {
            val bound = saved.copy(googleAccountEmail = connected.account.name)
            store.save(bound, saved)
            saved = bound
        }
        if (saved.phase in listOf(YouTubeJobPhase.FAILED, YouTubeJobPhase.AUTHORIZATION_REQUIRED))
            saved = runner.resume(saved, expected)
        job = saved
        checkOwner()
        if (
            android.os.Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED
        )
            notifications.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        YouTubeBackground.start(context, saved)
        backgroundRunning = true
    }
    Dialog(
        onDismissRequest = close,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
                Row(
                    Modifier.fillMaxWidth().padding(12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text("YouTube Upload", style = MaterialTheme.typography.titleLarge)
                    TextButton(onClick = close) { Text("Close") }
                }
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    Card(Modifier.fillMaxWidth()) {
                        Column(
                            Modifier.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text("YouTube channel", style = MaterialTheme.typography.titleMedium)
                            access?.let { Text(it.channel.title) }
                            if (access != null)
                                TextButton(
                                    enabled = !busy,
                                    onClick = { disconnectConfirmation = true },
                                ) {
                                    Text("Disconnect YouTube")
                                }
                            TextButton(
                                enabled = !busy && !backgroundRunning,
                                onClick = {
                                    perform {
                                        when (
                                            val result =
                                                auth.authorize(
                                                    access?.account,
                                                    job?.target?.channelId,
                                                )
                                        ) {
                                            is YouTubeAuthorization.Resolution ->
                                                consent.launch(
                                                    IntentSenderRequest.Builder(
                                                            result.pendingIntent
                                                        )
                                                        .build()
                                                )
                                            is YouTubeAuthorization.Access -> accept(result)
                                        }
                                    }
                                },
                            ) {
                                Text(if (access == null) "Connect YouTube" else "Reconnect YouTube")
                            }
                            Text(
                                "The video is sent directly from this device to the selected YouTube channel."
                            )
                        }
                    }
                    val saved = job
                    if (restoreFailed) {
                        Text(
                            "Saved upload needs attention",
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Text(
                            "Return to the original account, channel and draft to retry. Discarding removes this app's saved upload even if it belongs to another account or draft."
                        )
                        TextButton(
                            enabled = !busy && access != null,
                            onClick = { perform { accept(requireNotNull(access)) } },
                        ) {
                            Text("Retry saved upload")
                        }
                        if (discardSnapshot != null)
                            TextButton(enabled = !busy, onClick = { discardConfirmation = true }) {
                                Text("Discard saved upload")
                            }
                    } else if (saved == null) {
                        YouTubeUploadForm(
                            selected != null,
                            busy,
                            choose = {
                                picker.launch(
                                    PickVisualMediaRequest(
                                        ActivityResultContracts.PickVisualMedia.VideoOnly
                                    )
                                )
                            },
                            connected = access != null,
                            videoUri = selected?.let { Uri.parse(it) },
                            upload = { metadata ->
                                perform {
                                    val uri = Uri.parse(requireNotNull(selected))
                                    val mime =
                                        withContext(Dispatchers.IO) {
                                            context.contentResolver.getType(uri)
                                        }
                                    require(mime?.startsWith("video/") == true)
                                    val uploadTarget = target(requireNotNull(access).channel.id)
                                    job =
                                        withContext(Dispatchers.IO) {
                                            store.create(
                                                requireNotNull(
                                                    context.contentResolver.openInputStream(uri)
                                                ),
                                                uploadTarget,
                                                metadata,
                                                requireNotNull(mime),
                                                System.currentTimeMillis(),
                                                googleAccountEmail =
                                                    requireNotNull(access).account.name,
                                            )
                                        }
                                    selected = null
                                    runUpload()
                                }
                            },
                        )
                    } else {
                        Text(saved.metadata.title, style = MaterialTheme.typography.titleMedium)
                        Text(saved.phase.name.lowercase().replace('_', ' '))
                        LinearProgressIndicator(
                            progress = {
                                (saved.acknowledgedBytes.toDouble() / saved.byteCount).toFloat()
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text("${saved.acknowledgedBytes} / ${saved.byteCount} bytes")
                        if (saved.phase == YouTubeJobPhase.COMPLETED) {
                            Button(
                                enabled = !busy,
                                onClick = {
                                    perform {
                                        insert(saved)
                                        store.clear(saved.target, saved)
                                        close()
                                    }
                                },
                            ) {
                                Text("Use video in post")
                            }
                        } else if (saved.phase != YouTubeJobPhase.CANCELLED) {
                            Button(
                                enabled = !busy && !backgroundRunning && access != null,
                                onClick = { perform { runUpload() } },
                            ) {
                                Text("Resume upload")
                            }
                            TextButton(onClick = { cancelConfirmation = true }) {
                                Text("Cancel upload")
                            }
                        } else
                            TextButton(
                                enabled = !busy,
                                onClick = {
                                    perform {
                                        store.clear(saved.target)
                                        job = null
                                    }
                                },
                            ) {
                                Text("Choose another video")
                            }
                    }
                    if (busy) CircularProgressIndicator()
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    Text(
                        "Uploads can continue after closing this screen. Pause from the notification, or reopen the original draft to check progress. YouTube may require you to reconnect." +
                            if (android.os.Build.VERSION.SDK_INT < 34)
                                " On this Android version, uploads pause after 30 minutes. Resume to continue from saved progress."
                            else "",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
    if (discardConfirmation)
        AlertDialog(
            onDismissRequest = { discardConfirmation = false },
            title = { Text("Discard this app's saved upload?") },
            text = {
                Text(
                    "This removes the local video copy and recovery record (${discardSnapshot?.privateBytes ?: 0} bytes), including progress from another account or draft. This cannot be undone. Videos already accepted by YouTube remain on the channel. No YouTube deletion request will be sent."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        discardConfirmation = false
                        perform {
                            youtubeDispatch.withLock {
                                store.discardConfirmed(requireNotNull(discardSnapshot))
                            }
                            job = null
                            selected = null
                            restoreFailed = false
                            discardSnapshot = null
                        }
                    }
                ) {
                    Text("Discard local upload")
                }
            },
            dismissButton = {
                TextButton(onClick = { discardConfirmation = false }) { Text("Keep saved upload") }
            },
        )
    if (disconnectConfirmation)
        AlertDialog(
            onDismissRequest = { disconnectConfirmation = false },
            title = { Text("Disconnect YouTube?") },
            text = {
                Text(
                    "Google authorization will be revoked for this account. Saved upload progress will remain; reconnect the same channel to resume. Uploaded videos remain on YouTube."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        disconnectConfirmation = false
                        perform {
                            YouTubeBackground.pauseAndWait(context)
                            backgroundRunning = false
                            auth.revoke(requireNotNull(access).account)
                            access = null
                            connectionChanged(null)
                        }
                    }
                ) {
                    Text("Disconnect")
                }
            },
            dismissButton = {
                TextButton(onClick = { disconnectConfirmation = false }) { Text("Keep connected") }
            },
        )
    if (cancelConfirmation)
        AlertDialog(
            onDismissRequest = { cancelConfirmation = false },
            title = { Text("Cancel this YouTube upload?") },
            text = {
                Text(
                    "Sending will stop and the local video copy will be removed. A video already accepted by YouTube may remain on your channel."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        cancelConfirmation = false
                        scope.launch {
                            work?.cancelAndJoin()
                            YouTubeBackground.pauseAndWait(context)
                            perform {
                                val saved = requireNotNull(job)
                                youtubeDispatch.withLock {
                                    val current =
                                        requireNotNull(
                                            store.load(saved.target, System.currentTimeMillis())
                                        )
                                    if (current.phase != YouTubeJobPhase.COMPLETED) {
                                        val cancelled =
                                            current.copy(phase = YouTubeJobPhase.CANCELLED)
                                        store.save(cancelled, current)
                                        job = cancelled
                                    } else job = current
                                }
                            }
                        }
                    }
                ) {
                    Text("Cancel upload")
                }
            },
            dismissButton = {
                TextButton(onClick = { cancelConfirmation = false }) { Text("Keep uploading") }
            },
        )
}

@Composable
internal fun YouTubeUploadForm(
    hasVideo: Boolean,
    busy: Boolean,
    connected: Boolean,
    choose: () -> Unit,
    upload: (YouTubeUploadMetadata) -> Unit,
    videoUri: Uri? = null,
) {
    var title by rememberSaveable { mutableStateOf("") }
    var description by rememberSaveable { mutableStateOf("") }
    var privacy by rememberSaveable { mutableStateOf(YouTubePrivacy.UNLISTED.name) }
    var kids by rememberSaveable { mutableStateOf<Boolean?>(null) }
    var synthetic by rememberSaveable { mutableStateOf(false) }
    var accepted by rememberSaveable { mutableStateOf(false) }
    val metadata =
        YouTubeUploadMetadata(
            title,
            description,
            YouTubePrivacy.valueOf(privacy),
            kids,
            synthetic,
            accepted,
        )
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Video", style = MaterialTheme.typography.titleMedium)
            if (hasVideo) Text("Video selected")
            videoUri?.let { org.taggr.android.ui.SelectedVideoPreview(it) }
            TextButton(onClick = choose, enabled = !busy) {
                Text(if (hasVideo) "Choose another video" else "Choose video")
            }
            Text("YouTube details", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(
                title,
                { title = it },
                label = { Text("Title") },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            )
            Text("${Regex("\\X").findAll(title).count()}/100")
            OutlinedTextField(
                description,
                { description = it },
                label = { Text("Description") },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth().heightIn(min = 96.dp),
            )
            Text("${description.toByteArray(Charsets.UTF_8).size}/5000 bytes")
            Text("Visibility")
            Row {
                YouTubePrivacy.entries.forEach { value ->
                    FilterChip(
                        selected = privacy == value.name,
                        onClick = { privacy = value.name },
                        label = {
                            Text(value.name.lowercase().replaceFirstChar { it.uppercase() })
                        },
                        enabled = !busy,
                    )
                }
            }
            Text("Is this video made for kids?")
            Row {
                FilterChip(
                    selected = kids == false,
                    onClick = { kids = false },
                    label = { Text("No") },
                    enabled = !busy,
                )
                FilterChip(
                    selected = kids == true,
                    onClick = { kids = true },
                    label = { Text("Yes") },
                    enabled = !busy,
                )
            }
            Row {
                Checkbox(
                    synthetic,
                    { synthetic = it },
                    enabled = !busy,
                    modifier =
                        Modifier.semantics {
                            contentDescription = "Contains altered or synthetic media"
                        },
                )
                Text("Contains altered or synthetic media")
            }
            Row {
                Checkbox(
                    accepted,
                    { accepted = it },
                    enabled = !busy,
                    modifier =
                        Modifier.semantics {
                            contentDescription = "Accept YouTube terms and community guidelines"
                        },
                )
                Text(
                    "I confirm this video follows YouTube's Terms of Service and Community Guidelines."
                )
            }
            metadata.validationMessage()?.let {
                Text(it, style = MaterialTheme.typography.bodySmall)
            }
            Button(
                onClick = { upload(metadata) },
                enabled = !busy && connected && hasVideo && metadata.validationMessage() == null,
            ) {
                Text("Upload to YouTube")
            }
        }
    }
}
