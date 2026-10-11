package org.taggr.android

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*

private data class MembershipConfirmation(
    val joined: Boolean,
    val name: String,
    val penalty: ULong?,
    val confirm: () -> Unit,
)

@Composable
internal fun RealmMembershipControls(
    signedIn: Boolean,
    joined: Boolean,
    busy: Boolean,
    ready: Boolean,
    pending: Boolean,
    blocked: Boolean,
    change: (Boolean) -> Unit,
    checkResult: () -> Unit,
    name: String = "this Realm",
    cleanupPenalty: ULong? = null,
) {
    var confirmation by remember { mutableStateOf<MembershipConfirmation?>(null) }
    confirmation?.let { approved ->
        AlertDialog(
            onDismissRequest = { if (!busy) confirmation = null },
            title = {
                Text(if (approved.joined) "Join /${approved.name}?" else "Leave /${approved.name}?")
            },
            text = {
                Text(
                    if (approved.joined)
                        "By joining, you agree to the Realm description and rules. Rule violations may remove a post and charge up to ${approved.penalty} credits and reward points."
                    else "You can continue reading this Realm and join it again later."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmation = null
                        approved.confirm()
                    },
                    enabled = !busy && ready && !pending && !blocked,
                ) {
                    Text(if (approved.joined) "Agree and Join" else "Leave Realm")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmation = null }, enabled = !busy) { Text("Cancel") }
            },
        )
    }
    Column {
        if (!signedIn) {
            Text("Sign in from Account to join this realm.")
        } else {
            TextButton(
                onClick = {
                    val desired = !joined
                    confirmation =
                        MembershipConfirmation(desired, name, cleanupPenalty) { change(desired) }
                },
                enabled =
                    !busy && ready && !pending && !blocked && (joined || cleanupPenalty != null),
            ) {
                Text(if (joined) "Leave realm" else "Join realm")
            }
            if (!joined && cleanupPenalty == null && !pending && !blocked)
                Text("Realm rules are unavailable. Refresh before joining.")
            if (pending)
                Text(
                    "Realm membership result is unknown. Check it before changing membership again."
                )
            if (blocked)
                Text(
                    "The pending operation could not be loaded. Check it before changing membership."
                )
            if (pending || blocked)
                TextButton(onClick = checkResult, enabled = !busy) {
                    Text("Check membership result")
                }
        }
    }
}
