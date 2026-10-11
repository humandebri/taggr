package org.taggr.android.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.taggr.android.AccountViewModel
import org.taggr.android.PostComposer
import org.taggr.android.data.ReactionGroup
import org.taggr.android.data.TaggrPost

@Composable
internal fun PostEngagementBar(
    account: AccountViewModel,
    post: TaggrPost,
    reply: () -> Unit,
    edit: () -> Unit,
    changed: () -> Unit,
    openProfile: (String) -> Unit,
    repliesExpanded: Boolean = false,
    toggleReplies: (() -> Unit)? = null,
    submitted: () -> Unit = changed,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val saved = state.user?.path("bookmarks")?.any { it.asLong() == post.id } == true
    PostEngagementContent(
        post,
        state.principal,
        replyEnabled =
            state.user != null &&
                !state.busy &&
                !state.restoring &&
                !post.viewerBlocked &&
                post.restriction == null,
        reply = reply,
        reaction = { PostReactionAction(account, post, compact = true, changed = changed) },
        actions = { close ->
            if (state.user != null && !post.viewerBlocked && post.restriction == null)
                PostComposer(
                    account,
                    parent = post.id,
                    editId = null,
                    inline = true,
                    onDismiss = close,
                    completed = {
                        close()
                        submitted()
                    },
                )
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                PostShareButton(post.id)
                if (state.user != null)
                    TextButton(
                        onClick = {
                            state.principal?.let { account.setBookmark(post.id, !saved, it) }
                        },
                        enabled = !state.busy && !state.restoring,
                    ) {
                        Text(if (saved) "Remove bookmark" else "Bookmark")
                    }
                PostActions(account, post, showReaction = false, changed = changed)
                if (state.user?.path("id")?.asLong(-1) == post.authorId && post.restriction == null)
                    TextButton(onClick = edit, enabled = !state.busy && !state.restoring) {
                        Text("Edit")
                    }
            }
            if (post.restriction == null && post.reactions.isNotEmpty())
                ReactionDetails(account, post, openProfile)
        },
        repliesExpanded = repliesExpanded,
        toggleReplies = toggleReplies,
        reactionEnabled =
            state.user != null &&
                !state.busy &&
                !state.restoring &&
                post.restriction == null &&
                post.canReact(state.user?.path("id")?.asLong(-1)),
        selectReaction = { id ->
            state.principal?.let { owner -> account.reactToPost(post.id, id, owner, changed) }
        },
    )
}

@Composable
internal fun PostEngagementContent(
    post: TaggrPost,
    owner: String?,
    replyEnabled: Boolean,
    reply: () -> Unit,
    reaction: @Composable () -> Unit,
    actions: @Composable ColumnScope.(close: () -> Unit) -> Unit,
    repliesExpanded: Boolean = false,
    toggleReplies: (() -> Unit)? = null,
    reactionEnabled: Boolean = false,
    selectReaction: (Int) -> Unit = {},
) {
    var expanded by rememberSaveable(post.id, owner) { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth()
            .testTag("post-engagement-${post.id}")
            .padding(horizontal = 12.dp, vertical = 4.dp)
    ) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            Row(
                Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                val groups = ReactionGroup.groups(post.reactions, ReactionGroup.defaultOrder)
                groups.forEach { group ->
                    Surface(
                        onClick = { if (reactionEnabled) selectReaction(group.id) },
                        enabled = reactionEnabled,
                        shape = MaterialTheme.shapes.small,
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        modifier =
                            Modifier.semantics {
                                contentDescription = "${group.emoji} reaction, ${group.users.size}"
                            },
                    ) {
                        Text(
                            "${group.emoji} ${group.users.size}",
                            Modifier.padding(horizontal = 8.dp, vertical = 6.dp)
                                .clearAndSetSemantics {},
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                }
                if (groups.isEmpty())
                    Text(
                        "${post.reactionCount} reactions",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                if (post.reposts.isNotEmpty())
                    Text(
                        "${post.reposts.size} reposts",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                if (post.tipCount > 0)
                    Text(
                        "${post.tipCount} tips",
                        modifier =
                            Modifier.clearAndSetSemantics {
                                contentDescription = "${post.tipCount} tips"
                            },
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
            }
            reaction()
            if (toggleReplies != null) {
                if (post.replyCount > 0)
                    TextButton(
                        onClick = toggleReplies,
                        modifier =
                            Modifier.semantics {
                                contentDescription =
                                    if (repliesExpanded) "Hide replies" else "Show replies"
                                stateDescription = if (repliesExpanded) "Expanded" else "Collapsed"
                            },
                    ) {
                        Text("${post.replyCount} replies")
                    }
            } else
                TextButton(onClick = reply, enabled = replyEnabled) {
                    Text("Reply${if (post.replyCount > 0) " · ${post.replyCount}" else ""}")
                }
            IconButton(
                colors =
                    IconButtonDefaults.iconButtonColors(
                        contentColor = MaterialTheme.colorScheme.primary
                    ),
                onClick = { expanded = !expanded },
                modifier =
                    Modifier.semantics {
                        contentDescription =
                            if (expanded) "Hide post actions" else "Show post actions"
                    },
            ) {
                Text(
                    "⋯",
                    Modifier.clearAndSetSemantics {},
                    style = MaterialTheme.typography.titleLarge,
                )
            }
        }
        if (expanded)
            Surface(
                shape = MaterialTheme.shapes.medium,
                color = MaterialTheme.colorScheme.surface,
            ) {
                Column(Modifier.fillMaxWidth().padding(8.dp)) { actions { expanded = false } }
            }
    }
}
