package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.ic4j.agent.android.ICPAmount
import org.taggr.android.data.WithdrawQuote

@Composable
internal fun WithdrawConfirmation(
    quote: WithdrawQuote,
    canister: String,
    network: String,
    busy: Boolean,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text("Withdraw rewards") },
        text = {
            Column(
                Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Rewards: ${ICPAmount.format(quote.grossE8s)}")
                Text("Fee: ${ICPAmount.format(quote.feeE8s)}")
                Text("You receive: ${ICPAmount.format(quote.netE8s)}")
                Text("Recipient: ${quote.recipient}")
                Text("Rewards are sent to this TAGGR account's principal.")
                Text("Signed by: ${quote.owner}")
                Text(network)
                Text("TAGGR: $canister")
            }
        },
        confirmButton = { TextButton(onClick = onConfirm, enabled = !busy) { Text("Withdraw") } },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !busy) { Text("Cancel") } },
    )
}
