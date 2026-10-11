package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fasterxml.jackson.databind.ObjectMapper
import org.taggr.android.data.*
import org.taggr.android.ui.markdownText

@Composable
internal fun RealmCreationEditor(
    account: AccountViewModel,
    close: () -> Unit,
    openRealm: (String) -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    var values by
        rememberSaveable(state.principal) {
            mutableStateOf(
                RealmCreationDraft.defaults(state.user?.path("id")?.asText().orEmpty()).values
            )
        }
    var quote by remember(state.principal) { mutableStateOf<RealmCreationQuote?>(null) }
    var defaultsLoaded by rememberSaveable(state.principal) { mutableStateOf(false) }
    var limitsError by remember(state.principal) { mutableStateOf<String?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    LaunchedEffect(state.principal, revision) {
        try {
            val limits = RealmCreationLimits.decode(account.api.jsonQuery("config"))
            if (!defaultsLoaded) {
                values = values + ("downvotes" to limits.defaultDownvotes.toString())
                defaultsLoaded = true
            }
            limitsError = null
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            limitsError = e.message
        }
    }
    val pending = financial.pending?.takeIf { it.method == "create_realm" }
    val pendingName =
        remember(pending) { pending?.let { ObjectMapper().readTree(it.arguments)[0].asText() } }
    quote?.let { frozen ->
        RealmCreationConfirmation(
            frozen,
            account.api.configuration.canisterId,
            account.api.configuration.apiBaseURL.toString(),
            state.busy,
            confirm = {
                quote = null
                account.createRealm(frozen)
            },
            cancel = { quote = null },
        )
    }
    RealmCreationForm(
        draft = RealmCreationDraft(values),
        busy = state.busy,
        ready =
            defaultsLoaded &&
                !financial.restoring &&
                !financial.blocked &&
                financial.pending == null &&
                state.user != null &&
                !account.api.snsRestricted,
        pendingName = pendingName,
        blocked = financial.blocked,
        createdName = state.createdRealm,
        error = state.error ?: limitsError,
        notice = state.notice,
        change = { values = it.values },
        close = close,
        review = { account.prepareRealmCreation(RealmCreationDraft(values)) { quote = it } },
        check = account::checkFinancial,
        reload = { revision++ },
        join = { name -> account.setRealmMembership(name, true) { openRealm(name) } },
        open = openRealm,
        membershipPending = financial.pending?.method == "toggle_realm_membership",
        createdJoined =
            state.createdRealm?.let { name ->
                state.user?.path("realms")?.any { it.asText().equals(name, ignoreCase = true) }
            } == true,
    )
}

@Composable
internal fun RealmCreationForm(
    draft: RealmCreationDraft,
    busy: Boolean,
    ready: Boolean,
    pendingName: String?,
    blocked: Boolean,
    createdName: String?,
    error: String?,
    notice: String?,
    change: (RealmCreationDraft) -> Unit,
    close: () -> Unit,
    review: () -> Unit,
    check: () -> Unit,
    reload: () -> Unit,
    join: (String) -> Unit,
    open: (String) -> Unit,
    membershipPending: Boolean = false,
    createdJoined: Boolean = false,
) {
    Dialog(
        onDismissRequest = { if (!busy) close() },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(Modifier.fillMaxSize()) {
            Column(
                Modifier.safeDrawingPadding().padding(20.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Create Realm", style = MaterialTheme.typography.headlineSmall)
                    TextButton(onClick = close, enabled = !busy) { Text("Close") }
                }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                notice?.let { Text(it) }
                when {
                    createdName != null -> {
                        Text("/$createdName was created.")
                        Button(onClick = { open(createdName) }, enabled = !busy) {
                            Text("Open Realm")
                        }
                        if (!createdJoined)
                            TextButton(onClick = { join(createdName) }, enabled = !busy && ready) {
                                Text("Join Realm")
                            }
                        if (membershipPending)
                            TextButton(onClick = check, enabled = !busy) {
                                Text("Check membership result")
                            }
                    }
                    pendingName != null || blocked -> {
                        Text(
                            if (pendingName != null)
                                "Creation of /$pendingName is unconfirmed. Check the original request before creating again."
                            else
                                "The pending operation could not be loaded. Check it before creating a Realm."
                        )
                        TextButton(onClick = check, enabled = !busy) {
                            Text("Check creation result")
                        }
                    }
                    else -> {
                        val enabled = !busy && ready
                        @Composable
                        fun field(key: String, label: String, multiline: Boolean = false) {
                            OutlinedTextField(
                                draft.values.getValue(key),
                                { change(RealmCreationDraft(draft.values + (key to it))) },
                                label = { Text(label) },
                                enabled = enabled,
                                singleLine = !multiline,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        @Composable
                        fun flag(key: String, label: String) {
                            Row(
                                Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text(label, Modifier.weight(1f))
                                Switch(
                                    draft.flag(key),
                                    {
                                        change(
                                            RealmCreationDraft(
                                                draft.values + (key to it.toString())
                                            )
                                        )
                                    },
                                    enabled = enabled,
                                )
                            }
                        }
                        Text("Identity", style = MaterialTheme.typography.titleMedium)
                        field("name", "Realm name")
                        field("description", "Description", true)
                        if (draft.values.getValue("description").isNotEmpty())
                            Text(
                                remember(draft.values["description"]) {
                                    markdownText(draft.values.getValue("description"))
                                }
                            )
                        field("color", "Label color (#RRGGBB)")
                        Text(
                            "Logo can be added after creation.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        Text(
                            "Controllers and whitelist",
                            style = MaterialTheme.typography.titleMedium,
                        )
                        field("controllers", "Controllers (names or IDs, comma separated)", true)
                        field("whitelist", "Whitelist (names or IDs, comma separated)", true)
                        Text("Moderation", style = MaterialTheme.typography.titleMedium)
                        flag("adult", "Adult content")
                        flag("filterComments", "Apply posting rules to comments")
                        field("penalty", "Cleanup penalty")
                        field("downvotes", "Maximum downvotes")
                        flag("safe", "Safe users only")
                        field("age", "Minimum account age (days)")
                        field("balance", "Minimum token balance (whole tokens)")
                        field("followers", "Minimum followers")
                        Text("Theme", style = MaterialTheme.typography.titleMedium)
                        flag("ownTheme", "Use own theme")
                        if (draft.flag("ownTheme"))
                            for (key in realmThemeDefaults.keys) field(
                                "theme_$key",
                                "$key (#RRGGBB)",
                            )
                        TextButton(onClick = reload, enabled = !busy) {
                            Text("Reload creation settings")
                        }
                        Button(onClick = review, enabled = enabled) { Text("Review creation") }
                    }
                }
            }
        }
    }
}

@Composable
internal fun RealmCreationConfirmation(
    quote: RealmCreationQuote,
    canister: String,
    network: String,
    busy: Boolean,
    confirm: () -> Unit,
    cancel: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) cancel() },
        title = { Text("Create /${quote.name}?") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("Creation costs ${quote.limits.cost} credits.")
                Text("Signing account: ${quote.owner}")
                Text("Network: $network")
                Text("TAGGR: $canister")
                Text(
                    "Controllers: ${ObjectMapper().readTree(quote.payloadJson)["controllers"].joinToString { it.asText() }}"
                )
                Text(
                    "This confirmation expires in two minutes. The Realm will be joined after creation is confirmed."
                )
            }
        },
        confirmButton = {
            Button(onClick = confirm, enabled = !busy) {
                Text("Create for ${quote.limits.cost} credits")
            }
        },
        dismissButton = { TextButton(onClick = cancel, enabled = !busy) { Text("Cancel") } },
    )
}
