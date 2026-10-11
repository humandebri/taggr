package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import org.taggr.android.data.*

@Composable
internal fun ProfileCreditTransfer(
    account: AccountViewModel,
    recipientId: Long,
    name: String,
    dismiss: () -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    var amount by rememberSaveable(recipientId, state.principal) { mutableStateOf("") }
    var fee by remember { mutableStateOf<ULong?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var quote by
        remember(recipientId, state.principal) { mutableStateOf<CreditTransferQuote?>(null) }
    var sent by rememberSaveable(recipientId, state.principal) { mutableStateOf(false) }
    var awaiting by remember(recipientId, state.principal) { mutableStateOf(false) }
    val pendingHere =
        financial.pending?.let {
            it.method == "transfer_credits" &&
                com.fasterxml.jackson.databind.ObjectMapper().readTree(it.arguments)[0].asLong() ==
                    recipientId
        } == true
    LaunchedEffect(pendingHere, state.notice) {
        if (pendingHere) {
            awaiting = true
            quote = null
        } else if (awaiting && state.notice == "Credits sent.") {
            sent = true
            awaiting = false
        }
    }
    LaunchedEffect(revision, state.principal) {
        fee = null
        try {
            fee = WithdrawQuote.unsigned(account.api.jsonQuery("config"), "credit_transaction_fee")
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            fee = null
        }
    }
    val balance =
        state.user?.let { runCatching { WithdrawQuote.unsigned(it, "cycles") }.getOrNull() }
    val blocked =
        state.busy ||
            state.restoring ||
            financial.restoring ||
            financial.blocked ||
            financial.pending != null ||
            state.user == null ||
            state.user?.path("id")?.asLong() == recipientId ||
            account.api.snsRestricted
    AlertDialog(
        onDismissRequest = { if (!state.busy) dismiss() },
        title = { Text("Send credits") },
        text = {
            Column {
                if (financial.pending != null && !pendingHere)
                    Text("Check the pending account operation from Account before sending credits.")
                CreditTransferForm(
                    name,
                    amount,
                    { amount = it },
                    balance,
                    fee,
                    blocked,
                    sent,
                    pendingHere,
                    state.error,
                    { revision++ },
                    {
                        account.prepareCreditTransfer(recipientId, amount) {
                            fee = it.fee
                            quote = it
                        }
                    },
                    { account.checkFinancial() },
                    state.busy,
                )
            }
        },
        confirmButton = { TextButton(onClick = dismiss, enabled = !state.busy) { Text("Done") } },
    )
    quote?.let { reviewed ->
        AlertDialog(
            onDismissRequest = { if (!state.busy) quote = null },
            title = { Text("Send credits to @${reviewed.recipientName}?") },
            text = {
                Text(
                    "Send ${reviewed.amount} credits plus ${reviewed.fee} credits fee. Total deducted: ${reviewed.total} credits."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        account.sendCredits(reviewed) {
                            sent = true
                            quote = null
                        }
                    },
                    enabled = !blocked && !sent,
                ) {
                    Text("Send")
                }
            },
            dismissButton = {
                TextButton(onClick = { quote = null }, enabled = !state.busy) { Text("Cancel") }
            },
        )
    }
}

@Composable
internal fun CreditTransferForm(
    recipient: String,
    amount: String,
    edit: (String) -> Unit,
    balance: ULong?,
    fee: ULong?,
    blocked: Boolean,
    sent: Boolean,
    pending: Boolean,
    error: String?,
    reload: () -> Unit,
    review: () -> Unit,
    check: () -> Unit,
    busy: Boolean = false,
) {
    val total =
        CreditTransferQuote.parse(amount)
            ?.let { value ->
                fee?.let { runCatching { CreditTransferQuote.total(value, it) }.getOrNull() }
            }
            ?.takeIf { balance != null && it <= balance }
    Column(
        Modifier.verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        Text("Recipient: @$recipient")
        OutlinedTextField(
            amount,
            edit,
            Modifier.testTag("profile-credits-amount"),
            label = { Text("Credits") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            enabled = !blocked && !sent,
        )
        balance?.let { Text("Available credits: $it") }
        if (fee != null) Text("Fee: $fee credits") else Text("The transfer fee is unavailable.")
        TextButton(onClick = reload, enabled = !blocked && !sent) { Text("Reload fee") }
        if (total != null) Text("Total deducted: $total credits")
        else if (amount.isNotEmpty())
            Text("Enter a positive whole number within your balance, including the fee.")
        if (pending) {
            Text("The transfer result is unknown. Check its result before sending again.")
            TextButton(onClick = check, enabled = pending && !busy) {
                Text("Check transfer result")
            }
        }
        if (sent) Text("Credits sent")
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        TextButton(onClick = review, enabled = total != null && !blocked && !sent && !pending) {
            Text("Review transfer")
        }
    }
}
