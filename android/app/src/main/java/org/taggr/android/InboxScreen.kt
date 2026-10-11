package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import org.taggr.android.data.*
import org.taggr.android.ui.PostContent
import org.taggr.android.ui.markdownText

@Composable
internal fun InboxScreen(
    state: AccountState,
    account: AccountViewModel,
    openPost: (Long) -> Unit,
    openProfile: (String) -> Unit,
    openProposal: ((Long) -> Unit)? = null,
) {
    val list =
        remember(state.user) {
            try {
                Notifications.decode(state.user?.get("notifications"))
            } catch (_: Exception) {
                NotificationList(emptyList(), 1)
            }
        }
    var revision by remember(state.principal) { mutableIntStateOf(0) }
    LaunchedEffect(state.principal) { if (state.principal != null) account.reload() }
    InboxContent(
        state.principal,
        state.user != null,
        list,
        state.busy,
        revision,
        refresh = {
            revision++
            account.reload()
        },
        markRead = { ids -> state.principal?.let { account.markNotificationsRead(ids, it) } },
        loadPost = { id ->
            account.api.posts(listOf(id)).singleOrNull()?.takeIf {
                it.restriction == null && account.safety.allowed(it)
            }
        },
        openPost = openPost,
        openProfile = openProfile,
        openProposal = openProposal,
        unwatch = { entry ->
            state.principal?.let { owner ->
                entry.postId?.let { account.unwatchNotification(entry.id, it, owner) }
            }
        },
    )
}

@Composable
internal fun InboxContent(
    owner: String?,
    hasAccount: Boolean,
    notifications: NotificationList,
    busy: Boolean,
    revision: Int = 0,
    refresh: () -> Unit,
    markRead: (List<Long>) -> Unit,
    loadPost: suspend (Long) -> TaggrPost?,
    openPost: (Long) -> Unit,
    openProfile: (String) -> Unit,
    openProposal: ((Long) -> Unit)? = null,
    unwatch: (NotificationEntry) -> Unit = {},
) {
    var archive by rememberSaveable(owner) { mutableStateOf(false) }
    val fresh = notifications.entries.filter { !it.read }
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item { Text("Inbox", style = MaterialTheme.typography.headlineLarge) }
        if (owner == null) item { Text("Sign in from Account to see your notifications.") }
        else if (!hasAccount)
            item { Text("Create your TAGGR account from Account to receive notifications.") }
        else {
            item {
                Row {
                    TextButton(onClick = refresh, enabled = !busy) { Text("Refresh") }
                    TextButton(
                        onClick = { markRead(fresh.map { it.id }) },
                        enabled = !busy && fresh.isNotEmpty(),
                    ) {
                        Text("Mark all read")
                    }
                }
            }
            if (notifications.invalidCount > 0)
                item {
                    Text(
                        "Some notifications could not be loaded. Refresh to retry.",
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            if (fresh.isEmpty()) item { Text("No unread notifications.") }
            items(fresh, key = { "fresh-${it.id}" }) { entry ->
                NotificationCard(
                    entry,
                    owner,
                    revision,
                    busy,
                    loadPost,
                    { markRead(listOf(entry.id)) },
                    openPost,
                    openProfile,
                    unwatch = { unwatch(entry) },
                    openProposal = openProposal,
                )
            }
            item {
                TextButton(onClick = { archive = !archive }) {
                    Text(if (archive) "Hide archive" else "Show archive")
                }
            }
            if (archive) {
                item { Text("Archive", style = MaterialTheme.typography.titleMedium) }
                items(notifications.entries.filter { it.read }, key = { "read-${it.id}" }) { entry
                    ->
                    NotificationCard(
                        entry,
                        owner,
                        revision,
                        busy,
                        loadPost,
                        {},
                        openPost,
                        openProfile,
                        unwatch = {},
                        openProposal = openProposal,
                    )
                }
            }
        }
    }
}

@Composable
private fun NotificationCard(
    entry: NotificationEntry,
    owner: String,
    revision: Int,
    busy: Boolean,
    loadPost: suspend (Long) -> TaggrPost?,
    markRead: () -> Unit,
    openPost: (Long) -> Unit,
    openProfile: (String) -> Unit,
    openProposal: ((Long) -> Unit)? = null,
    unwatch: () -> Unit,
) {
    var post by remember(owner, entry.id, revision) { mutableStateOf<TaggrPost?>(null) }
    var loading by remember(owner, entry.id, revision) { mutableStateOf(entry.postId != null) }
    var error by remember(owner, entry.id, revision) { mutableStateOf<String?>(null) }
    var retry by remember(owner, entry.id) { mutableIntStateOf(0) }
    LaunchedEffect(owner, entry.postId, revision, retry) {
        post = null
        error = null
        loading = entry.postId != null
        try {
            entry.postId?.let { post = loadPost(it) }
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            error = "Could not load notification"
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            error = "Could not load notification"
        } finally {
            loading = false
        }
    }
    Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.medium) {
        Column(
            Modifier.fillMaxWidth().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            val message =
                if (entry.postId != null && post == null) "Notification" else entry.message
            Text(remember(message) { markdownText(message) })
            if (loading) CircularProgressIndicator()
            else if (error != null) {
                Text(error!!)
                TextButton(onClick = { retry++ }) { Text("Retry") }
            } else if (entry.postId != null && post == null) Text("Post unavailable")
            post?.let { value ->
                PostContent(value, false)
                ProposalLink(value, openProposal)
                TextButton(onClick = { openPost(value.id) }) { Text("Open conversation") }
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(entry.watchedEntries, key = { it }) { id ->
                        TextButton(onClick = { openPost(id) }) { Text("Reply #$id") }
                    }
                }
            }
            entry.userId?.let { id ->
                TextButton(onClick = { openProfile(id.toString()) }) { Text("Open profile") }
            }
            if (!entry.read && entry.watchedEntries.isNotEmpty())
                TextButton(onClick = unwatch, enabled = !busy && post != null) {
                    Text("Unwatch post")
                }
            if (!entry.read)
                TextButton(onClick = markRead, enabled = !busy) { Text("Mark as read") }
        }
    }
}
