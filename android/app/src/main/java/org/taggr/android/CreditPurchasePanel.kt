package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.ic4j.agent.android.ICPAmount
import org.taggr.android.data.CreditPurchaseQuote

@Composable
internal fun CreditPurchasePanel(
    state: CreditPurchaseState,
    busy: Boolean,
    ready: Boolean,
    prepare: () -> Unit,
    resume: () -> Unit,
    close: () -> Unit,
    invoiceReady: Boolean = true,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        state.receipt?.let { receipt ->
            if (receipt.result != null)
                Text("Credits purchased: ${receipt.quote.credits} · Ledger block ${receipt.block}")
            receipt.paymentFailure?.let { Text("Last purchase payment rejected: $it") }
        }
        state.pending?.let { row ->
            Text(
                when {
                    row.result != null -> "Credit purchase confirmed. Save the result to continue."
                    row.paymentFailure != null -> "Payment rejected: ${row.paymentFailure}"
                    row.settlement != null ->
                        "Waiting for the credit mint result. No payment will be repeated."
                    row.block != null ->
                        "Payment confirmed at block ${row.block}. Credit mint pending."
                    row.payment != null ->
                        "Waiting for the payment result. No payment will be repeated."
                    else -> "Purchase prepared. No payment has been dispatched."
                }
            )
            Text("${ICPAmount.format(row.quote.transfer.amount)} for ${row.quote.credits} credits")
            if (row.payment != null && !row.finished)
                TextButton(onClick = resume, enabled = ready && !busy) {
                    Text("Check / continue credit purchase")
                }
            if (row.payment == null || row.finished)
                TextButton(onClick = close, enabled = !busy) {
                    Text(
                        if (row.finished) "Save purchase result" else "Cancel purchase preparation"
                    )
                }
        }
        if (state.blocked)
            Text(
                "The purchase record could not be restored. New financial operations are blocked.",
                color = MaterialTheme.colorScheme.error,
            )
        if (state.blocked)
            TextButton(onClick = resume, enabled = ready && !busy && !state.restoring) {
                Text("Reload credit purchase")
            }
        if (state.pending == null)
            TextButton(
                onClick = prepare,
                enabled = ready && invoiceReady && !busy && !state.restoring && !state.blocked,
            ) {
                Text("Buy credits with ICP")
            }
    }
}

@Composable
internal fun CreditPurchaseConfirmation(
    quote: CreditPurchaseQuote,
    network: String,
    identityBusy: Boolean,
    dismiss: () -> Unit,
    pay: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!identityBusy) dismiss() },
        title = { Text("Buy ${quote.credits} credits") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(network)
                Text("Wallet owner: ${quote.transfer.owner}")
                Text("ICP ledger: ${org.taggr.android.data.LedgerWire.CANISTER}")
                Text("TAGGR: ${quote.invoice.canister}")
                Text("Invoice recipient: ${quote.transfer.recipient}")
                Text("Payment: ${ICPAmount.format(quote.transfer.amount)}")
                Text("Fee: ${ICPAmount.format(quote.transfer.fee)}")
                Text("Total: ${ICPAmount.format(quote.transfer.amount + quote.transfer.fee)}")
                Text(
                    "This confirmation expires after 2 minutes. If interrupted, check the saved purchase result before making another payment."
                )
            }
        },
        confirmButton = {
            TextButton(onClick = pay, enabled = !identityBusy) { Text("Pay and buy credits") }
        },
        dismissButton = {
            TextButton(onClick = dismiss, enabled = !identityBusy) { Text("Cancel") }
        },
    )
}
