package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.ic4j.agent.android.ICPAmount
import org.taggr.android.data.LedgerWire
import org.taggr.android.data.TransferQuote

@Composable
internal fun SendICPDialog(account: AccountViewModel, onDismiss: () -> Unit) {
    val state by account.state.collectAsStateWithLifecycle()
    val transfers by account.transferState.collectAsStateWithLifecycle()
    var recipient by rememberSaveable { mutableStateOf("") }
    var amount by rememberSaveable { mutableStateOf("") }
    var quote by remember { mutableStateOf<TransferQuote?>(null) }
    val blocked = transfers.restoring || transfers.blocked || transfers.pending != null
    AlertDialog(
        onDismissRequest = { if (!state.busy) onDismiss() },
        title = { Text("Send ICP") },
        text = {
            Column(
                Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                SendICPFields(
                    recipient,
                    amount,
                    !state.busy && !blocked,
                    { recipient = it },
                    { amount = it },
                )
                state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (blocked) Text("Confirm the previous transfer result before sending again.")
                if (state.busy || transfers.restoring) CircularProgressIndicator()
            }
        },
        confirmButton = {
            TextButton(
                onClick = { account.prepareTransfer(recipient, amount) { quote = it } },
                enabled = !state.busy && !blocked && recipient.isNotBlank() && amount.isNotBlank(),
            ) {
                Text("Review transfer")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !state.busy) { Text("Cancel") }
        },
    )
    quote?.let { value ->
        TransferConfirmation(
            value,
            if (
                account.api.configuration.rootKey.contentEquals(
                    org.ic4j.agent.Agent.mainnetRootKey()
                )
            )
                "Internet Computer mainnet"
            else "Test network: ${account.api.configuration.apiBaseURL.host}",
            state.busy,
            onDismiss = { quote = null },
        ) {
            quote = null
            account.sendTransfer(value, onDismiss)
        }
    }
}

@Composable
internal fun SendICPFields(
    recipient: String,
    amount: String,
    enabled: Boolean,
    onRecipient: (String) -> Unit,
    onAmount: (String) -> Unit,
) {
    OutlinedTextField(
        recipient,
        onRecipient,
        label = { Text("Recipient Principal or ICP account") },
        modifier = Modifier.fillMaxWidth(),
        enabled = enabled,
    )
    OutlinedTextField(
        amount,
        onAmount,
        label = { Text("Amount in ICP") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        modifier = Modifier.fillMaxWidth(),
        enabled = enabled,
    )
}

@Composable
internal fun TransferConfirmation(
    quote: TransferQuote,
    networkLabel: String,
    busy: Boolean,
    onDismiss: () -> Unit,
    onSend: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text("Confirm ICP transfer") },
        text = {
            Column(
                Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("Amount: ${ICPAmount.format(quote.amount)}")
                Text("Fee: ${ICPAmount.format(quote.fee)}")
                Text("Network: $networkLabel", style = MaterialTheme.typography.bodySmall)
                Text("From: ${quote.owner}", style = MaterialTheme.typography.bodySmall)
                Text("To: ${quote.recipient}", style = MaterialTheme.typography.bodySmall)
                Text(
                    "ICP Ledger: ${LedgerWire.CANISTER}",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        },
        confirmButton = { TextButton(onClick = onSend, enabled = !busy) { Text("Send") } },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !busy) { Text("Cancel") } },
    )
}

@Composable
internal fun ReplayConfirmation(
    pending: org.taggr.android.data.PendingTransfer,
    networkLabel: String,
    busy: Boolean,
    onDismiss: () -> Unit,
    onRetry: () -> Unit,
) {
    val time =
        java.time.Instant.ofEpochSecond(
                (pending.createdAtNanos / 1_000_000_000uL).toLong(),
                (pending.createdAtNanos % 1_000_000_000uL).toLong(),
            )
            .toString()
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text("Retry the same ICP transfer?") },
        text = {
            Column(
                Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    "This resubmits the original payment with unchanged amount, fee, timestamp and memo. If it already succeeded, the Ledger returns its original block. An unconfirmed result stays pending."
                )
                Text("Amount: ${ICPAmount.format(pending.quote.amount)}")
                Text("Fee: ${ICPAmount.format(pending.quote.fee)}")
                Text("Network: $networkLabel")
                Text("From: ${pending.quote.owner}", style = MaterialTheme.typography.bodySmall)
                Text("To: ${pending.quote.recipient}", style = MaterialTheme.typography.bodySmall)
                Text("Original time: $time", style = MaterialTheme.typography.bodySmall)
                Text("Original memo: ${pending.memo}", style = MaterialTheme.typography.bodySmall)
                Text(
                    "ICP Ledger: ${LedgerWire.CANISTER}",
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    "Retry is available for 23 hours from the original timestamp. Older transfers require transaction-history verification.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onRetry, enabled = !busy) { Text("Retry same transfer") }
        },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !busy) { Text("Cancel") } },
    )
}
