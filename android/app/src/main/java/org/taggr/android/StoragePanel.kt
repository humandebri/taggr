package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import org.taggr.android.data.*

@Composable
internal fun StoragePanel(account: AccountViewModel) {
    val state by account.state.collectAsStateWithLifecycle()
    val creation by account.creationState.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    val transfers by account.transferState.collectAsStateWithLifecycle()
    val topUp by account.topUpState.collectAsStateWithLifecycle()
    var creating by remember(state.principal) { mutableStateOf<StorageCreationQuote?>(null) }
    val bucket = state.user?.get("bucket")?.takeUnless { it.isNull }?.asText()
    var management by
        remember(bucket, state.principal) { mutableStateOf<StorageManagementQuote?>(null) }
    var input by rememberSaveable(state.principal) { mutableStateOf("") }
    var quote by remember(state.principal) { mutableStateOf<StorageQuote?>(null) }
    var snapshot by remember(bucket, state.principal) { mutableStateOf<StorageStatus?>(null) }
    var loading by remember(bucket, state.principal) { mutableStateOf(false) }
    var error by remember(bucket, state.principal) { mutableStateOf<String?>(null) }
    var revision by remember(bucket, state.principal) { mutableIntStateOf(0) }
    LaunchedEffect(bucket, state.principal, revision) {
        if (bucket.isNullOrEmpty()) return@LaunchedEffect
        loading = true
        error = null
        try {
            snapshot = account.api.storageStatus(bucket)
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            error = "Storage status timed out. Try again."
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: "Storage status unavailable"
        } finally {
            loading = false
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Storage", style = MaterialTheme.typography.titleLarge)
        creation.pending?.let { pending ->
            Text("Storage creation: ${pending.phase.name.lowercase().replace('_', ' ')}")
            pending.block?.let { Text("Payment block: $it") }
            pending.bucket?.let { Text("Created canister: $it") }
            if (pending.failure != null) {
                StorageCreationFailureDetails(pending)
                TextButton(
                    onClick = { account.acknowledgeStorageFailure(pending) },
                    enabled = !state.busy,
                ) {
                    Text("Save result and close")
                }
            } else if (pending.payment == null) {
                Text("No payment has been dispatched. Review the price again before continuing.")
                TextButton(onClick = account::cancelStoragePreparation, enabled = !state.busy) {
                    Text("Cancel preparation")
                }
            } else {
                Text("Continue using the recorded payment. No new payment will be sent.")
                TextButton(onClick = account::resumeStorageCreation, enabled = !state.busy) {
                    Text("Check and continue")
                }
            }
        }
        if (creation.pending == null)
            creation.receipt?.let {
                Text("Last creation result", style = MaterialTheme.typography.titleMedium)
                StorageCreationFailureDetails(it)
            }
        if (creation.blocked)
            Text(
                "Storage creation could not be restored. Financial actions are blocked.",
                color = MaterialTheme.colorScheme.error,
            )
        StorageTopUpPanel(account, bucket) { revision++ }
        if (!bucket.isNullOrEmpty()) {
            Text(bucket)
            snapshot?.let { StorageMetrics(it) }
            if (loading) CircularProgressIndicator()
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            TextButton(onClick = { revision++ }, enabled = !loading && !state.busy) {
                Text("Refresh storage")
            }
            snapshot?.let { status ->
                StorageManagementControls(
                    status,
                    state.principal,
                    !state.busy &&
                        !state.restoring &&
                        !loading &&
                        !topUp.restoring &&
                        !topUp.blocked &&
                        topUp.pending == null &&
                        !creation.restoring &&
                        !creation.blocked &&
                        creation.pending == null &&
                        !financial.restoring &&
                        !financial.blocked &&
                        financial.pending == null &&
                        !transfers.restoring &&
                        !transfers.blocked &&
                        transfers.pending == null,
                ) { action ->
                    account.prepareStorageManagement(action) { management = it }
                }
            }
        } else if (state.user != null) {
            Text("Create storage to attach images to posts.")
            TextButton(
                onClick = { account.prepareStorageCreation { creating = it } },
                enabled =
                    !state.busy &&
                        !creation.restoring &&
                        !creation.blocked &&
                        creation.pending == null,
            ) {
                Text("Review creation price")
            }
            Text("Or register an existing TAGGR storage canister.")
            OutlinedTextField(
                input,
                { input = it },
                label = { Text("Storage canister ID") },
                singleLine = true,
                enabled = !state.busy,
            )
            TextButton(
                onClick = { account.prepareStorage(input) { quote = it } },
                enabled =
                    !state.busy &&
                        input.isNotBlank() &&
                        !creation.restoring &&
                        !creation.blocked &&
                        creation.pending == null,
            ) {
                Text("Review storage")
            }
        } else Text("Create your TAGGR account to configure storage.")
    }
    creating?.let { value ->
        StorageCreationConfirmation(
            value,
            if (
                account.api.configuration.rootKey.contentEquals(
                    org.ic4j.agent.Agent.mainnetRootKey()
                )
            )
                "Internet Computer mainnet"
            else "Test network: ${account.api.configuration.apiBaseURL.host}",
            state.busy,
            { creating = null },
        ) {
            creating = null
            account.createStorage(value)
        }
    }
    quote?.let { value ->
        StorageConfirmation(
            value,
            account.api.configuration.canisterId,
            if (
                account.api.configuration.rootKey.contentEquals(
                    org.ic4j.agent.Agent.mainnetRootKey()
                )
            )
                "Internet Computer mainnet"
            else "Test network: ${account.api.configuration.apiBaseURL.host}",
            state.busy,
            { quote = null },
        ) {
            quote = null
            account.registerStorage(value)
        }
    }
    management?.let { value ->
        StorageManagementConfirmation(
            value,
            account.api.configuration.canisterId,
            if (
                account.api.configuration.rootKey.contentEquals(
                    org.ic4j.agent.Agent.mainnetRootKey()
                )
            )
                "Internet Computer mainnet"
            else "Test network: ${account.api.configuration.apiBaseURL.host}",
            state.busy,
            { management = null },
        ) {
            management = null
            account.manageStorage(value) { revision++ }
        }
    }
}

@Composable
internal fun StorageManagementControls(
    status: StorageStatus,
    owner: String?,
    ready: Boolean,
    review: (StorageManagementAction) -> Unit,
) {
    val controlled = owner != null && owner in status.controllers
    if (status.moduleHash != null && !status.compatible)
        TextButton(
            onClick = { review(StorageManagementAction.UPGRADE) },
            enabled = ready && controlled,
        ) {
            Text("Upgrade storage")
        }
    if (StorageProvisioning.BLACKHOLE !in status.controllers)
        TextButton(
            onClick = { review(StorageManagementAction.ADD_BLACKHOLE) },
            enabled = ready && controlled && status.compatible,
        ) {
            Text("Add Blackhole controller")
        }
}

@Composable
internal fun StorageManagementConfirmation(
    quote: StorageManagementQuote,
    taggr: String,
    network: String,
    busy: Boolean,
    dismiss: () -> Unit,
    confirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) dismiss() },
        title = { Text(quote.action.title) },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Storage: ${quote.snapshot.bucket}")
                Text("Signed by: ${quote.owner}")
                Text(network)
                Text("TAGGR: $taggr")
                if (quote.action == StorageManagementAction.UPGRADE) {
                    Text(
                        "Installs the current TAGGR storage code using an upgrade. Existing files are retained."
                    )
                    Text("Current module: ${quote.snapshot.moduleHash}")
                    Text("Approved module: ${quote.snapshot.expectedHash}")
                } else {
                    Text(
                        "Adds the TAGGR Blackhole controller for storage management and file authorization. Existing controllers are retained."
                    )
                    Text("New controller: ${StorageProvisioning.BLACKHOLE}")
                }
                Text("Existing controllers:")
                quote.snapshot.controllers.forEach { Text(it) }
            }
        },
        confirmButton = {
            TextButton(onClick = confirm, enabled = !busy) { Text(quote.action.confirm) }
        },
        dismissButton = { TextButton(onClick = dismiss, enabled = !busy) { Text("Cancel") } },
    )
}

@Composable
internal fun StorageMetrics(status: StorageStatus) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Status: ${status.status}")
        Text("Memory: ${status.memoryBytes} bytes")
        Text("Cycles: ${status.cycles}")
        Text("Daily burn: ${status.dailyBurn}")
        Text("Estimated days remaining: ${status.daysRemaining ?: "—"}")
        Text(
            if (status.compatible) "TAGGR storage is up to date"
            else "TAGGR storage code needs updating"
        )
        if (status.moduleHash == null) Text("No module installed")
        Text("Controllers:")
        status.controllers.forEach { Text(it) }
    }
}

@Composable
internal fun StorageConfirmation(
    quote: StorageQuote,
    taggr: String,
    network: String,
    busy: Boolean,
    dismiss: () -> Unit,
    confirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) dismiss() },
        title = { Text("Register storage") },
        text = {
            Column(
                Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Storage: ${quote.snapshot.bucket}")
                Text("Signed by: ${quote.owner}")
                Text(network)
                Text("TAGGR: $taggr")
                Text("Module: ${quote.snapshot.moduleHash}")
                Text("Controllers:")
                quote.snapshot.controllers.forEach { Text(it) }
                Text(
                    "This will become your TAGGR image storage. An existing registered storage canister cannot be replaced."
                )
            }
        },
        confirmButton = { TextButton(onClick = confirm, enabled = !busy) { Text("Register") } },
        dismissButton = { TextButton(onClick = dismiss, enabled = !busy) { Text("Cancel") } },
    )
}

@Composable
internal fun StorageCreationConfirmation(
    quote: StorageCreationQuote,
    network: String,
    busy: Boolean,
    dismiss: () -> Unit,
    confirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) dismiss() },
        title = { Text("Create image storage") },
        text = {
            Column(
                Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(network)
                Text("Paid from: ${quote.transfer.owner}")
                Text("Ledger: ${LedgerWire.CANISTER}")
                Text("CMC recipient: ${quote.transfer.recipient}")
                Text(
                    "Creation price: ${org.ic4j.agent.android.ICPAmount.format(quote.transfer.amount)}"
                )
                Text("Ledger fee: ${org.ic4j.agent.android.ICPAmount.format(quote.transfer.fee)}")
                Text(
                    "Total: ${org.ic4j.agent.android.ICPAmount.format(quote.transfer.amount + quote.transfer.fee)}"
                )
                Text("TAGGR: ${quote.taggr}")
                Text("Controllers: ${quote.transfer.owner}, ${StorageProvisioning.BLACKHOLE}")
                Text(
                    "This pays for a new canister, installs TAGGR storage and registers it as your image storage. Registration cannot be replaced. More cycles may be needed over time."
                )
            }
        },
        confirmButton = {
            TextButton(onClick = confirm, enabled = !busy) { Text("Pay and create") }
        },
        dismissButton = { TextButton(onClick = dismiss, enabled = !busy) { Text("Cancel") } },
    )
}

@Composable
internal fun StorageCreationFailureDetails(record: StorageCreationRecord) {
    val failure = record.failure ?: return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            if (failure.kind == StorageCreationFailureKind.PAYMENT_REJECTED) "Payment rejected"
            else "Creation failed: CMC refund result"
        )
        Text(failure.reason)
        if (failure.kind == StorageCreationFailureKind.CMC_REFUNDED) {
            Text("Original payment block: ${record.block}")
            Text(
                if (failure.refundBlock != null) "Refund block: ${failure.refundBlock}"
                else "CMC supplied no refund block. The refund amount has not been verified."
            )
        }
        Text(
            "No new payment was sent. Starting again requires reviewing and confirming a new payment."
        )
    }
}
