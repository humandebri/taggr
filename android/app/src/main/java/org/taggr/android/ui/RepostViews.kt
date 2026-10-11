package org.taggr.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import org.taggr.android.AccountViewModel
import org.taggr.android.LocalPollAccount
import org.taggr.android.data.*

internal val LocalPostOpen = compositionLocalOf<((Long) -> Unit)?> { null }

@Composable
internal fun RepostSource(id: Long) {
    val account = LocalPollAccount.current
    val viewer = LocalPostViewer.current
    var revision by remember(id, account) { mutableIntStateOf(0) }
    var loaded by remember(id, account, viewer, revision) { mutableStateOf<TaggrPost?>(null) }
    var loading by remember(id, account, viewer, revision) { mutableStateOf(true) }
    var failed by remember(id, account, viewer, revision) { mutableStateOf(false) }
    LaunchedEffect(id, account, viewer, revision) {
        try {
            loaded = account?.api?.posts(listOf(id))?.singleOrNull()
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (_: Exception) {
            failed = true
        } finally {
            loading = false
        }
    }
    val source = loaded
    when {
        loading -> Text("Loading repost", style = MaterialTheme.typography.bodySmall)
        failed -> TextButton(onClick = { revision++ }) { Text("Repost unavailable · Retry") }
        source == null ||
            source.restriction != null ||
            source.hiddenForViewer(viewer) ||
            account?.safety?.allowed(source) == false ->
            Text("Repost unavailable", style = MaterialTheme.typography.bodySmall)
        else -> RepostPreview(source, LocalPostOpen.current)
    }
}

@Composable
internal fun RepostPreview(post: TaggrPost, open: ((Long) -> Unit)? = null) {
    var expanded by remember(post.id, post.body) { mutableStateOf(false) }
    var truncated by remember(post.id, post.body) { mutableStateOf(false) }
    val blocks = remember(post.body) { PostBodyParser.blocks(post.body) }
    Column(Modifier.testTag("repost-source-${post.id}")) {
        Surface(
            shape = RoundedCornerShape(8.dp),
            color = MaterialTheme.colorScheme.surfaceContainer,
        ) {
            Column(
                Modifier.fillMaxWidth().padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Column(
                    Modifier.fillMaxWidth().testTag("repost-open-${post.id}").clickable(
                        enabled = open != null
                    ) {
                        open?.invoke(post.id)
                    }
                ) {
                    Text("Repost", style = MaterialTheme.typography.labelSmall)
                    Text(post.author, style = MaterialTheme.typography.labelMedium)
                    UserBadgeRow(post.authorBadges)
                }
                blocks.forEachIndexed { index, block ->
                    when (block) {
                        is PostBodyBlock.Markdown ->
                            Text(
                                remember(block.text) { markdownText(block.text) },
                                Modifier.fillMaxWidth()
                                    .testTag("repost-body-${post.id}-$index")
                                    .clickable(enabled = open != null) { open?.invoke(post.id) },
                                style = MaterialTheme.typography.bodyMedium,
                                maxLines = if (expanded) Int.MAX_VALUE else 4,
                                overflow = TextOverflow.Ellipsis,
                                onTextLayout = { if (it.hasVisualOverflow) truncated = true },
                            )
                        is PostBodyBlock.YouTube ->
                            key(post.id, index, block.id) { YouTubePlayer(block) }
                    }
                }
            }
        }
        if (truncated && !expanded)
            TextButton(onClick = { expanded = true }) { Text("Show full post") }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RepostDialog(
    account: AccountViewModel,
    source: TaggrPost,
    dismiss: () -> Unit,
    completed: (Long) -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    var ownsPending by
        remember(source.id, state.principal, state.postOutcomeUnknown) { mutableStateOf(false) }
    LaunchedEffect(source.id, state.principal, state.postOutcomeUnknown) {
        val owner = state.principal
        if (state.postOutcomeUnknown && owner != null)
            try {
                ownsPending = account.hasPendingRepost(owner, source.id)
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Exception) {
                ownsPending = false
            }
    }
    var comment by
        remember(source.id, state.principal) {
            mutableStateOf(account.readDraft(null, repostId = source.id))
        }
    var realm by
        remember(source.id, state.principal) {
            mutableStateOf(account.readDraftRealm(null, reposting = source))
        }
    ModalBottomSheet(onDismissRequest = { if (!state.busy) dismiss() }) {
        key(source.id, state.principal) {
            RepostForm(
                source,
                comment,
                realm,
                state.busy,
                state.postOutcomeUnknown,
                state.user != null && state.principal != null && !state.restoring,
                state.error,
                changeComment = {
                    comment = it
                    account.saveDraft(null, comment, realm, repostId = source.id)
                },
                changeRealm = {
                    realm = it
                    account.saveDraft(null, comment, realm, repostId = source.id)
                },
                submit = {
                    account.post(comment.trim(), null, realm, completed, repostId = source.id)
                },
                check = { account.recoverPost(completed) },
                dismiss = dismiss,
                markChecked =
                    if (ownsPending)
                        ({
                            state.principal?.let {
                                account.resolveRepostAfterReview(it, source.id, false, dismiss)
                            }
                        })
                    else null,
                retryEditing =
                    if (ownsPending)
                        ({
                            state.principal?.let {
                                account.resolveRepostAfterReview(it, source.id, true) {
                                    ownsPending = false
                                }
                            }
                        })
                    else null,
            )
        }
    }
}

@Composable
internal fun RepostForm(
    source: TaggrPost,
    comment: String,
    realm: String,
    busy: Boolean,
    pending: Boolean,
    signedIn: Boolean,
    error: String?,
    changeComment: (String) -> Unit,
    changeRealm: (String) -> Unit,
    submit: () -> Unit,
    check: () -> Unit,
    dismiss: () -> Unit,
    markChecked: (() -> Unit)? = null,
    retryEditing: (() -> Unit)? = null,
) {
    var review by remember(source.id) { mutableStateOf<String?>(null) }
    Column(
        Modifier.fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .imePadding()
            .padding(16.dp)
            .testTag("repost-form"),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = dismiss, enabled = !busy) { Text("Cancel") }
            Button(
                onClick = submit,
                modifier = Modifier.testTag("repost-submit"),
                enabled = signedIn && !busy && !pending,
            ) {
                Text("Repost")
            }
        }
        key(source.id) {
            org.taggr.android.MarkdownEditor(
                comment,
                changeComment,
                label = "Comment (optional)",
                enabled = !busy && !pending,
            )
        }
        OutlinedTextField(
            realm,
            changeRealm,
            Modifier.fillMaxWidth(),
            label = { Text("Realm (optional)") },
            enabled = !busy && !pending,
            singleLine = true,
        )
        if (source.restriction != null || source.hiddenForViewer(LocalPostViewer.current))
            Text("Repost unavailable", style = MaterialTheme.typography.bodySmall)
        else RepostPreview(source)
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (pending) {
            Text("Check the pending post result before reposting. Your draft is kept.")
            TextButton(onClick = check, enabled = !busy && signedIn) { Text("Check post result") }
            if (markChecked != null)
                TextButton(onClick = { review = "checked" }, enabled = !busy && signedIn) {
                    Text("I confirmed it was reposted")
                }
            if (retryEditing != null)
                TextButton(onClick = { review = "retry" }, enabled = !busy && signedIn) {
                    Text("Edit and retry")
                }
        }
        if (!signedIn) Text("Sign in from Account to repost.")
        if (busy) CircularProgressIndicator()
    }
    review?.let { choice ->
        AlertDialog(
            onDismissRequest = { if (!busy) review = null },
            title = {
                Text(
                    if (choice == "checked") "Mark repost as checked?"
                    else "Allow editing and another request?"
                )
            },
            text = {
                Text(
                    if (choice == "checked")
                        "Only confirm after checking your profile. This clears the pending record and this draft based on your confirmation, without verifying the request result or sending another request."
                    else
                        "Check your profile first. The previous request may still finish, so another repost could be a duplicate. This clears only the pending record and retains your draft; nothing is sent automatically."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        review = null
                        if (choice == "checked") markChecked?.invoke() else retryEditing?.invoke()
                    },
                    enabled = !busy && signedIn,
                ) {
                    Text("Confirm review")
                }
            },
            dismissButton = {
                TextButton(onClick = { review = null }, enabled = !busy) { Text("Cancel") }
            },
        )
    }
}
