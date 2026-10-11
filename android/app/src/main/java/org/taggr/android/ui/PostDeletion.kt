package org.taggr.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.taggr.android.AccountViewModel
import org.taggr.android.data.TaggrPost

@Composable
internal fun DeletePostAction(account: AccountViewModel, post: TaggrPost, changed: () -> Unit) {
    val state by account.state.collectAsStateWithLifecycle()
    var shown by remember(post.id, state.principal, post.deleted) { mutableStateOf(false) }
    val own = state.principal != null && state.user?.path("id")?.asLong(-1) == post.authorId
    DeletePostControl(own, post.deleted, state.busy || state.restoring) { shown = true }
    if (shown)
        DeletePostConfirmation(
            state.busy,
            state.postOutcomeUnknown,
            state.error,
            delete = {
                account.deletePost(post) {
                    shown = false
                    changed()
                }
            },
            check = {
                account.recoverPost {
                    shown = false
                    changed()
                }
            },
            cancel = { shown = false },
        )
}

@Composable
internal fun DeletePostControl(own: Boolean, deleted: Boolean, busy: Boolean, review: () -> Unit) {
    if (own && !deleted)
        TextButton(onClick = review, enabled = !busy) {
            Text("Delete", color = MaterialTheme.colorScheme.error)
        }
}

@Composable
internal fun DeletePostConfirmation(
    busy: Boolean,
    pending: Boolean,
    error: String?,
    delete: () -> Unit,
    check: () -> Unit,
    cancel: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) cancel() },
        title = { Text("Delete post?") },
        text = {
            Column {
                Text(
                    "This removes the text and attachment references. History hashes remain. Deletion may use credits and refund reaction rewards. You cannot restore the text."
                )
                if (pending) {
                    Text("A post request is pending. Check its result before deleting.")
                    TextButton(onClick = check, enabled = !busy) { Text("Check post result") }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (busy) CircularProgressIndicator()
            }
        },
        confirmButton = {
            TextButton(onClick = delete, enabled = !busy && !pending) {
                Text("Delete", color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = cancel, enabled = !busy) { Text("Cancel") } },
    )
}
