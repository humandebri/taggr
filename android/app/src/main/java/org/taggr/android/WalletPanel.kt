package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fasterxml.jackson.databind.JsonNode
import org.ic4j.agent.android.ICPAmount
import org.taggr.android.data.WalletAmounts
import org.taggr.android.data.WalletSnapshot

@Composable
internal fun WalletPanel(
    user: JsonNode?,
    account: AccountViewModel,
    recoveryOnly: Boolean = false,
) {
    val wallet by account.walletState.collectAsStateWithLifecycle()
    var sending by remember { mutableStateOf(false) }
    var replaying by remember { mutableStateOf<org.taggr.android.data.PendingTransfer?>(null) }
    val transfers by account.transferState.collectAsStateWithLifecycle()
    val creation by account.creationState.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    val invoice by account.invoiceState.collectAsStateWithLifecycle()
    val purchase by account.purchaseState.collectAsStateWithLifecycle()
    var purchasing by remember { mutableStateOf<org.taggr.android.data.CreditPurchaseQuote?>(null) }
    purchasing?.let { quote ->
        CreditPurchaseConfirmation(
            quote,
            if (
                account.api.configuration.rootKey.contentEquals(
                    org.ic4j.agent.Agent.mainnetRootKey()
                )
            )
                "Internet Computer mainnet"
            else "Test network: ${account.api.configuration.apiBaseURL.host}",
            identityBusy = account.state.collectAsStateWithLifecycle().value.busy,
            dismiss = { purchasing = null },
        ) {
            purchasing = null
            account.purchaseCredits(quote)
        }
    }
    var withdrawing by remember { mutableStateOf<org.taggr.android.data.WithdrawQuote?>(null) }
    val identity by account.state.collectAsStateWithLifecycle()
    if (sending) SendICPDialog(account) { sending = false }
    replaying?.let { pending ->
        ReplayConfirmation(
            pending,
            if (
                account.api.configuration.rootKey.contentEquals(
                    org.ic4j.agent.Agent.mainnetRootKey()
                )
            )
                "Internet Computer mainnet"
            else "Test network: ${account.api.configuration.apiBaseURL.host}",
            identity.busy,
            { replaying = null },
        ) {
            replaying = null
            account.replayTransfer(pending) {}
        }
    }
    withdrawing?.let { quote ->
        WithdrawConfirmation(
            quote,
            account.api.configuration.canisterId,
            if (
                account.api.configuration.rootKey.contentEquals(
                    org.ic4j.agent.Agent.mainnetRootKey()
                )
            )
                "Internet Computer mainnet"
            else "Test network: ${account.api.configuration.apiBaseURL.host}",
            identity.busy,
            { withdrawing = null },
        ) {
            withdrawing = null
            account.withdrawRewards(quote)
        }
    }
    LaunchedEffect(identity.principal) { account.reloadWallet() }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Wallet", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        WalletMetrics(user, wallet.snapshot, showCredits = !recoveryOnly)
        wallet.snapshot?.let {
            Text(
                "Transfer fee: ${ICPAmount.format(it.feeE8s)}",
                style = MaterialTheme.typography.bodySmall,
            )
        }
        if (wallet.loading) CircularProgressIndicator()
        wallet.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        TextButton(
            onClick = {
                account.dismissMessage()
                sending = true
            },
            enabled =
                !identity.busy &&
                    !transfers.restoring &&
                    !transfers.blocked &&
                    transfers.pending == null &&
                    !financial.restoring &&
                    !financial.blocked &&
                    financial.pending == null &&
                    !purchase.restoring &&
                    !purchase.blocked &&
                    purchase.pending == null &&
                    !creation.restoring &&
                    !creation.blocked &&
                    creation.pending == null,
        ) {
            Text("Send ICP")
        }
        TextButton(
            onClick = {
                account.dismissMessage()
                account.prepareWithdrawal { withdrawing = it }
            },
            enabled =
                user != null &&
                    !identity.busy &&
                    !transfers.restoring &&
                    !transfers.blocked &&
                    transfers.pending == null &&
                    !financial.restoring &&
                    !financial.blocked &&
                    financial.pending == null &&
                    !purchase.restoring &&
                    !purchase.blocked &&
                    purchase.pending == null &&
                    !creation.restoring &&
                    !creation.blocked &&
                    creation.pending == null,
        ) {
            Text("Withdraw rewards")
        }
        if (!recoveryOnly)
            CreditInvoicePanel(
                invoice,
                enabled =
                    user != null &&
                        !account.api.snsRestricted &&
                        !identity.busy &&
                        !transfers.restoring &&
                        !transfers.blocked &&
                        transfers.pending == null &&
                        !financial.restoring &&
                        !financial.blocked &&
                        financial.pending == null &&
                        !purchase.restoring &&
                        !purchase.blocked &&
                        purchase.pending == null &&
                        !creation.restoring &&
                        !creation.blocked &&
                        creation.pending == null,
                prepare = account::prepareCreditInvoice,
            )
        if (!recoveryOnly || purchase.pending != null || purchase.blocked || purchase.restoring)
            CreditPurchasePanel(
                purchase,
                identity.busy,
                ready =
                    identity.principal != null &&
                        !transfers.restoring &&
                        !transfers.blocked &&
                        transfers.pending == null &&
                        !financial.restoring &&
                        !financial.blocked &&
                        financial.pending == null &&
                        !creation.restoring &&
                        !creation.blocked &&
                        creation.pending == null,
                prepare = { account.prepareCreditPurchase { purchasing = it } },
                resume = account::resumeCreditPurchase,
                close = account::closeCreditPurchase,
                invoiceReady =
                    user != null &&
                        !account.api.snsRestricted &&
                        !invoice.restoring &&
                        !invoice.blocked,
            )
        financial.pending?.let {
            Text(
                "Pending ${when (it.method) { "withdraw_rewards" -> "reward withdrawal"
 "create_invite", "update_invite" -> "invite change"
                            "vote_on_proposal" -> "proposal vote"
                            "toggle_following_post" -> "discussion follow change"
 "edit_realm" -> "Realm settings change"
 "create_realm" -> "Realm creation"
 "toggle_realm_membership" -> "Realm membership change"
 else -> "credit mint" }}. Check the result before another financial operation.",
                style = MaterialTheme.typography.bodySmall,
            )
        }
        if (financial.blocked)
            Text(
                "The financial operation record could not be loaded. New operations are blocked until it can be checked.",
                color = MaterialTheme.colorScheme.error,
            )
        if (financial.pending != null || financial.blocked)
            TextButton(onClick = account::checkFinancial, enabled = !identity.busy) {
                Text("Check financial result")
            }
        transfers.pending?.let { pending ->
            Text(
                "Pending transfer: ${ICPAmount.format(pending.quote.amount)} to ${pending.quote.recipient}",
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                "Check this result before sending again.",
                style = MaterialTheme.typography.bodySmall,
            )
            TextButton(
                onClick = {
                    account.dismissMessage()
                    replaying = pending
                },
                enabled = !identity.busy && !transfers.restoring && !transfers.blocked,
            ) {
                Text("Review same-transfer retry")
            }
        }
        if (transfers.blocked)
            Text(
                "The pending transfer record could not be loaded. New transfers are blocked until it can be checked.",
                color = MaterialTheme.colorScheme.error,
            )
        if (transfers.pending != null || transfers.blocked)
            TextButton(onClick = account::checkTransfer, enabled = !identity.busy) {
                Text("Check transfer result")
            }
        TextButton(onClick = account::reloadWallet, enabled = !wallet.loading && !identity.busy) {
            Text("Refresh wallet")
        }
    }
}

@Composable
internal fun WalletMetrics(
    user: JsonNode?,
    snapshot: WalletSnapshot?,
    showCredits: Boolean = true,
) {
    fun unsigned(field: String): java.math.BigInteger? =
        user
            ?.get(field)
            ?.takeIf { it.isIntegralNumber && it.bigIntegerValue().signum() >= 0 }
            ?.bigIntegerValue()
    val token =
        snapshot?.let { value ->
            unsigned("balance")?.let { WalletAmounts.token(it, value.tokenDecimals) }
        } ?: "—"
    val credits = unsigned("cycles")?.toString() ?: "—"
    val balance = snapshot?.let { ICPAmount.format(it.balanceE8s, units = false) } ?: "—"
    val rewards =
        unsigned("treasury_e8s")
            ?.takeIf { it.bitLength() <= 64 }
            ?.let { ICPAmount.format(it.toString().toULong(), units = false) } ?: "—"
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        (listOf("TAGGR" to token) +
                (if (showCredits) listOf("Credits" to credits) else emptyList()) +
                listOf("ICP" to balance, "Rewards" to rewards))
            .chunked(2)
            .forEach { row ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    row.forEach { (title, value) ->
                        Surface(
                            Modifier.weight(1f),
                            shape = MaterialTheme.shapes.medium,
                            color = MaterialTheme.colorScheme.surfaceVariant,
                        ) {
                            Column(Modifier.padding(12.dp)) {
                                Text(title, style = MaterialTheme.typography.labelMedium)
                                Text(
                                    value,
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold,
                                )
                            }
                        }
                    }
                }
            }
    }
}

@Composable
internal fun CreditInvoicePanel(state: CreditInvoiceState, enabled: Boolean, prepare: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Credits", style = MaterialTheme.typography.titleMedium)
        state.receipt?.invoice?.let { invoice ->
            Text(
                if (invoice.paid) "Payment confirmed: ${ICPAmount.format(invoice.paidE8s)}"
                else "Invoice for 1,000 credits: ${ICPAmount.format(invoice.amountE8s)}"
            )
            if (!invoice.paid) Text("Awaiting payment", style = MaterialTheme.typography.bodySmall)
        }
        if (state.restoring) CircularProgressIndicator()
        if (state.blocked)
            Text(
                "The saved invoice could not be restored. Check the financial result before continuing.",
                color = MaterialTheme.colorScheme.error,
            )
        TextButton(onClick = prepare, enabled = enabled && !state.restoring && !state.blocked) {
            Text(
                if (state.receipt?.invoice?.paid == false) "Check credit invoice"
                else "Prepare credit invoice"
            )
        }
    }
}
