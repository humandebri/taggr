package org.taggr.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.semantics.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.util.UUID
import org.taggr.android.AccountViewModel
import org.taggr.android.data.TaggrPost

@Composable
fun ReportAction(account: AccountViewModel, user: Long, post: Long?) {
    var shown by remember { mutableStateOf(false) }
    var reason by rememberSaveable { mutableStateOf("") }
    var id by rememberSaveable { mutableStateOf(UUID.randomUUID().toString()) }
    val state by account.state.collectAsStateWithLifecycle()
    TextButton(onClick = { shown = true }) { Text("Report") }
    if (shown)
        AlertDialog(
            onDismissRequest = { if (!state.busy) shown = false },
            title = { Text("Report content") },
            text = {
                Column {
                    OutlinedTextField(
                        reason,
                        { reason = it },
                        label = { Text("Reason") },
                        enabled = !state.busy,
                    )
                    state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        account.report(user, post, reason, id) {
                            shown = false
                            reason = ""
                            id = UUID.randomUUID().toString()
                        }
                    },
                    enabled = reason.trim().length >= 10 && !state.busy,
                ) {
                    Text("Send report")
                }
            },
            dismissButton = {
                TextButton(onClick = { shown = false }, enabled = !state.busy) { Text("Cancel") }
            },
        )
}

@Composable
fun PostActions(
    account: AccountViewModel,
    post: TaggrPost,
    showReaction: Boolean = true,
    changed: () -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    var repostShown by remember(post.id, state.principal) { mutableStateOf(false) }
    val openPost = LocalPostOpen.current
    if (state.user != null && state.principal != null)
        TextButton(onClick = { repostShown = true }, enabled = !state.busy && !state.restoring) {
            Text("Repost")
        }
    if (repostShown)
        RepostDialog(account, post, { repostShown = false }) { id ->
            repostShown = false
            changed()
            openPost?.invoke(id)
        }
    PostWatchControl(
        signedIn = state.user != null && state.principal != null,
        watching = state.user?.path("id")?.asLong(-1) in post.watchers,
        busy = state.busy || state.restoring,
        select = { selected ->
            state.principal?.let { owner ->
                account.setPostWatching(post.id, selected, owner, changed)
            }
        },
    )
    PostHideControl(
        signedIn = state.user != null && state.principal != null,
        hidden = post.hiddenForViewer(state.user?.path("id")?.asLong(-1)),
        busy = state.busy || state.restoring,
        select = { selected ->
            state.principal?.let { owner ->
                account.setPostHidden(post.id, selected, owner, changed)
            }
        },
    )
    val pins =
        remember(state.user) {
            runCatching {
                org.taggr.android.data.PinnedPosts.decode(state.user?.get("pinned_posts"))
            }
        }
    PostPinControl(
        ownPost = state.principal != null && state.user?.path("id")?.asLong(-1) == post.authorId,
        pinned = pins.getOrDefault(emptyList()).contains(post.id),
        busy = state.busy || state.restoring || pins.isFailure,
        select = { selected ->
            state.principal?.let { owner ->
                account.setPostPinned(post.id, selected, owner, changed)
            }
        },
    )
    if (pins.isFailure && state.user?.path("id")?.asLong(-1) == post.authorId)
        Text("Pin status unavailable. Refresh your account.")
    DeletePostAction(account, post, changed)
    if (showReaction) PostReactionAction(account, post, changed = changed)
    UserBlockControl(
        target = post.authorId,
        name = post.author,
        viewer = state.user?.path("id")?.asLong(-1),
        scope = state.principal,
        blocked = account.safety.blocked(post.authorId),
        busy = state.busy || state.restoring,
    ) { selected ->
        account.blockUser(post.authorId, selected, changed)
    }
    ReportAction(account, post.authorId, post.id)
}

@Composable
internal fun PostReactionAction(
    account: AccountViewModel,
    post: TaggrPost,
    compact: Boolean = false,
    changed: () -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    var reactionPicker by remember(post.id, state.principal) { mutableStateOf(false) }
    var options by remember { mutableStateOf<List<Pair<Int, Long>>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(reactionPicker) {
        if (!reactionPicker) return@LaunchedEffect
        error = null
        try {
            val config = account.api.jsonQuery("config")
            val fees = config.path("reaction_fee").associate { it[0].asInt() to it[1].asLong() }
            options =
                config.path("reactions").map {
                    val id = it[0].asInt()
                    val delta = it[1].asLong()
                    id to (if (delta < 0) -delta else delta + (fees[id] ?: 0))
                }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message
        }
    }
    PostReactionControl(
        post,
        state.user?.path("id")?.asLong(-1),
        state.busy || state.restoring,
        compact,
    ) {
        reactionPicker = true
    }
    if (reactionPicker)
        AlertDialog(
            onDismissRequest = { reactionPicker = false },
            title = { Text("React to post") },
            text = {
                Column {
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    for ((id, cost) in options) {
                        val symbol =
                            org.taggr.android.data.ReactionGroup.emoji(id) ?: "Reaction $id"
                        val label = "$symbol · $cost credits"
                        TextButton(
                            onClick = {
                                account.reactToPost(
                                    post.id,
                                    id,
                                    state.principal ?: return@TextButton,
                                ) {
                                    reactionPicker = false
                                    changed()
                                }
                            },
                            enabled =
                                !state.busy &&
                                    state.user != null &&
                                    !state.restoring &&
                                    post.canReact(state.user?.path("id")?.asLong(-1)),
                        ) {
                            Text(label)
                        }
                    }
                    if (state.user == null) Text("Sign in from Account to react.")
                }
            },
            confirmButton = { TextButton(onClick = { reactionPicker = false }) { Text("Close") } },
        )
}

@Composable
internal fun PostWatchControl(
    signedIn: Boolean,
    watching: Boolean,
    busy: Boolean,
    select: (Boolean) -> Unit,
) {
    if (signedIn)
        TextButton(onClick = { select(!watching) }, enabled = !busy) {
            Text(if (watching) "Unwatch" else "Watch")
        }
}

@Composable
internal fun PostHideControl(
    signedIn: Boolean,
    hidden: Boolean,
    busy: Boolean,
    select: (Boolean) -> Unit,
) {
    if (signedIn)
        TextButton(onClick = { select(!hidden) }, enabled = !busy) {
            Text(if (hidden) "Unhide" else "Hide")
        }
}

@Composable
internal fun PostPinControl(
    ownPost: Boolean,
    pinned: Boolean,
    busy: Boolean,
    select: (Boolean) -> Unit,
) {
    if (ownPost)
        TextButton(onClick = { select(!pinned) }, enabled = !busy) {
            Text(if (pinned) "Unpin" else "Pin")
        }
}

@Composable
internal fun PostReactionControl(
    post: TaggrPost,
    viewer: Long?,
    busy: Boolean,
    compact: Boolean = false,
    open: () -> Unit,
) {
    if (post.canReact(viewer)) {
        if (compact)
            IconButton(
                colors =
                    IconButtonDefaults.iconButtonColors(
                        contentColor = MaterialTheme.colorScheme.primary
                    ),
                onClick = open,
                enabled = !busy && post.restriction == null,
                modifier =
                    androidx.compose.ui.Modifier.semantics { contentDescription = "Add reaction" },
            ) {
                Text(
                    "+",
                    modifier = androidx.compose.ui.Modifier.clearAndSetSemantics {},
                    style = MaterialTheme.typography.titleLarge,
                )
            }
        else
            TextButton(onClick = open, enabled = !busy && post.restriction == null) {
                Text("React")
            }
    }
}
