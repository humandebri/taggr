package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.taggr.android.data.RetirementQuote
import org.taggr.android.data.RetirementStage

internal const val retirementExplanation =
    "This clears your biography, links and PGP setting, then encrypts ordinary posts using a random key that is not saved. Android offers no recovery. Names, previous names, images (including access through known URLs), DAO proposals and financial records remain. This uses the existing account suspension feature. It does not erase all account data."

@Composable
internal fun RetirementConfirmation(
    quote: RetirementQuote,
    busy: Boolean,
    dismiss: () -> Unit,
    confirm: () -> Unit,
) {
    var text by remember(quote) { mutableStateOf("") }
    var reviewed by remember(quote) { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = { if (!busy) dismiss() },
        title = { Text("Delete account?") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(retirementExplanation)
                Text("Cost: ${quote.cost} credits")
                Text("Account: ${quote.owner}")
                Text(
                    "The confirmation expires after 2 minutes. If interrupted, check status; the stop request will not be resent."
                )
                if (!reviewed)
                    OutlinedTextField(
                        text,
                        { text = it },
                        label = { Text("Type delete to continue") },
                        singleLine = true,
                    )
                else Text("Delete this account? This cannot be undone.")
            }
        },
        confirmButton = {
            TextButton(
                onClick = { if (reviewed) confirm() else reviewed = true },
                enabled = !busy && (reviewed || text == "delete"),
            ) {
                Text(if (reviewed) "Yes, delete account" else "Continue")
            }
        },
        dismissButton = { TextButton(onClick = dismiss, enabled = !busy) { Text("Cancel") } },
    )
}

@Composable
internal fun AccountRetirementPanel(account: AccountViewModel) {
    val state by account.state.collectAsStateWithLifecycle()
    var quote by remember { mutableStateOf<RetirementQuote?>(null) }
    quote?.let {
        RetirementConfirmation(it, state.busy, { quote = null }) {
            quote = null
            account.retireAccount(it)
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Account deletion", style = MaterialTheme.typography.titleMedium)
        TextButton(onClick = { account.prepareRetirement { quote = it } }, enabled = !state.busy) {
            Text("Delete account", color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
internal fun RetiredAccountScreen(account: AccountViewModel, progress: RetirementState) {
    val identity by account.state.collectAsStateWithLifecycle()
    Column(
        Modifier.fillMaxSize()
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Account", style = MaterialTheme.typography.headlineSmall)
        Text(
            when {
                progress.blocked ->
                    "Deletion progress could not be restored. SNS actions are blocked."
                progress.record?.stage == RetirementStage.PREPARING ->
                    "Deletion preparation is incomplete. Profile fields may already be cleared. Review the confirmation before retrying."
                progress.record?.stage == RetirementStage.STOP_PENDING ->
                    "Waiting for stop confirmation. The stop request will not be resent."
                progress.record?.stage == RetirementStage.STOP_CONFIRMED ->
                    "The stop response was received. Check account status to finish."
                progress.record?.stage == RetirementStage.CLEANUP ->
                    "Account stopped. Finish removing credentials and drafts from this device."
                else ->
                    "This account is already stopped. No new encryption was performed. SNS actions and reactivation are unavailable in Android."
            }
        )
        identity.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (progress.record?.stage == RetirementStage.PREPARING) AccountRetirementPanel(account)
        else
            TextButton(onClick = account::checkRetirement, enabled = !identity.busy) {
                Text(
                    if (progress.record?.stage == RetirementStage.CLEANUP) "Finish on this device"
                    else "Check status"
                )
            }
        Text("Asset recovery", style = MaterialTheme.typography.titleMedium)
        WalletPanel(identity.user, account, recoveryOnly = true)
        TextButton(onClick = account::signOut, enabled = !identity.busy) { Text("Sign out") }
        org.taggr.android.ui.PolicyLinks()
    }
}
