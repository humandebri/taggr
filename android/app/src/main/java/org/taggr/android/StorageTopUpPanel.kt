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
import org.taggr.android.data.*

@Composable
internal fun StorageTopUpPanel(account: AccountViewModel, bucket: String?, updated: () -> Unit) {
    val state by account.state.collectAsStateWithLifecycle()
    val topUp by account.topUpState.collectAsStateWithLifecycle()
    val creation by account.creationState.collectAsStateWithLifecycle()
    val purchase by account.purchaseState.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    val transfers by account.transferState.collectAsStateWithLifecycle()
    var amount by rememberSaveable(bucket, state.principal) { mutableStateOf("") }
    var quote by remember(bucket, state.principal) { mutableStateOf<StorageTopUpQuote?>(null) }
    val pending = topUp.pending
    LaunchedEffect(pending?.id, pending?.cycles) { if (pending?.cycles != null) updated() }
    if (topUp.blocked)
        Text(
            "Storage top-up could not be restored. Financial actions are blocked.",
            color = MaterialTheme.colorScheme.error,
        )
    if (pending != null) {
        StorageTopUpDetails(pending)
        when {
            pending.finished ->
                TextButton(
                    onClick = { account.acknowledgeStorageTopUp(pending) },
                    enabled = !state.busy,
                ) {
                    Text("Save top-up result and close")
                }
            pending.payment == null -> {
                Text("No payment has been dispatched. Review the amount again before continuing.")
                TextButton(
                    onClick = account::cancelStorageTopUpPreparation,
                    enabled = !state.busy,
                ) {
                    Text("Cancel top-up preparation")
                }
            }
            else -> {
                Text("Continue using the recorded payment. No new payment will be sent.")
                TextButton(onClick = account::resumeStorageTopUp, enabled = !state.busy) {
                    Text("Check top-up and continue")
                }
            }
        }
    } else topUp.receipt?.let { StorageTopUpDetails(it) }
    if (!bucket.isNullOrEmpty()) {
        val ready =
            !state.busy &&
                !state.restoring &&
                !account.api.snsRestricted &&
                !topUp.restoring &&
                !topUp.blocked &&
                pending == null &&
                !creation.restoring &&
                !creation.blocked &&
                creation.pending == null &&
                !purchase.restoring &&
                !purchase.blocked &&
                purchase.pending == null &&
                !financial.restoring &&
                !financial.blocked &&
                financial.pending == null &&
                !transfers.restoring &&
                !transfers.blocked &&
                transfers.pending == null
        OutlinedTextField(
            amount,
            { amount = it },
            label = { Text("Storage top-up amount (ICP)") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            enabled = ready,
        )
        TextButton(
            onClick = { account.prepareStorageTopUp(amount) { quote = it } },
            enabled = ready && amount.isNotBlank(),
        ) {
            Text("Review storage top-up")
        }
    }
    quote?.let { value ->
        val network =
            if (
                account.api.configuration.rootKey.contentEquals(
                    org.ic4j.agent.Agent.mainnetRootKey()
                )
            )
                "Internet Computer mainnet"
            else "Test network: ${account.api.configuration.apiBaseURL.host}"
        StorageTopUpConfirmation(value, network, state.busy, { quote = null }) {
            quote = null
            account.topUpStorage(value)
        }
    }
}

@Composable
internal fun StorageTopUpDetails(row: StorageTopUpRecord) {
    Text(
        if (row.finished) "Storage top-up result" else "Pending storage top-up",
        style = MaterialTheme.typography.titleMedium,
    )
    Text("Storage: ${row.quote.bucket}")
    Text("Amount: ${ICPAmount.format(row.quote.transfer.amount, units = false)} ICP")
    row.block?.let { Text("Payment block: $it") }
    row.cycles?.let { Text("Cycles added: $it") }
    row.failure?.let {
        Text(it.reason, color = MaterialTheme.colorScheme.error)
        if (it.kind == "Refunded") {
            Text(
                it.refundBlock?.let { block -> "Refund block: $block" }
                    ?: "No refund block was returned. The refunded amount has not been verified."
            )
            Text(
                "A processing fee may have been deducted. Check the refund before another payment."
            )
        }
        if (it.kind == "TransactionTooOld")
            Text(
                "This receipt is too old for CMC processing. Keep its payment block and verify transaction history before another payment."
            )
    }
}

@Composable
internal fun StorageTopUpConfirmation(
    quote: StorageTopUpQuote,
    network: String,
    busy: Boolean,
    dismiss: () -> Unit,
    confirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) dismiss() },
        title = { Text("Top up storage") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Storage: ${quote.bucket}")
                Text("Signed by: ${quote.transfer.owner}")
                Text(network)
                Text("TAGGR: ${quote.taggr}")
                Text("Amount: ${ICPAmount.format(quote.transfer.amount, units = false)} ICP")
                Text("Ledger fee: ${ICPAmount.format(quote.transfer.fee, units = false)} ICP")
                Text(
                    "Total: ${ICPAmount.format(quote.transfer.amount + quote.transfer.fee, units = false)} ICP"
                )
                Text("Recipient: ${quote.transfer.recipient}")
                Text(
                    "ICP is converted into cycles and sent to this storage. The number of cycles depends on the CMC conversion rate when the payment is processed."
                )
            }
        },
        dismissButton = { TextButton(onClick = dismiss, enabled = !busy) { Text("Cancel") } },
        confirmButton = { TextButton(onClick = confirm, enabled = !busy) { Text("Top up") } },
    )
}
