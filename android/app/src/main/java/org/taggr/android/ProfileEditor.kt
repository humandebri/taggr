package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fasterxml.jackson.databind.JsonNode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.taggr.android.data.ProfileDraft

@Composable
internal fun ProfileEditor(account: AccountViewModel, onDismiss: () -> Unit) {
    val state by account.state.collectAsStateWithLifecycle()
    var baseline by remember { mutableStateOf<JsonNode?>(null) }
    var draft by remember { mutableStateOf<ProfileDraft?>(null) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var saveFailed by remember { mutableStateOf(false) }
    var reconciliation by remember { mutableStateOf(false) }
    var confirmation by remember { mutableStateOf<String?>(null) }
    var validation by remember { mutableStateOf<String?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(reload) {
        loading = true
        error = null
        try {
            val user = account.api.currentUser() ?: error("Account unavailable")
            baseline = user
            if (draft == null) draft = ProfileDraft.from(user)
            reconciliation = false
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message
            reconciliation = true
        } finally {
            loading = false
        }
    }
    LaunchedEffect(draft?.name, baseline?.path("name")?.asText()) {
        validation = null
        val name = draft?.name ?: return@LaunchedEffect
        if (name != baseline?.path("name")?.asText() && name.isNotBlank()) {
            try {
                delay(300)
                val result = account.api.jsonQuery("validate_username", listOf(name))
                validation = result["Err"]?.asText() ?: "Available"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                validation = e.message
            }
        }
    }
    val busy = loading || state.busy
    Dialog(
        onDismissRequest = { if (!busy) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.safeDrawingPadding().imePadding()) {
                Row(
                    Modifier.fillMaxWidth().padding(8.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    TextButton(onClick = onDismiss, enabled = !busy) { Text("Close") }
                    Text(
                        "Edit profile",
                        Modifier.padding(top = 12.dp),
                        style = MaterialTheme.typography.titleLarge,
                    )
                    TextButton(
                        onClick = {
                            val value = draft ?: return@TextButton
                            val user = baseline ?: return@TextButton
                            loading = true
                            scope.launch {
                                try {
                                    value.validate()
                                    value.updateArguments(user)
                                    val messages = mutableListOf<String>()
                                    if (value.name != user.path("name").asText()) {
                                        val cost =
                                            account.api
                                                .jsonQuery("config")
                                                .path("identity_change_cost")
                                        require(cost.isIntegralNumber && cost.asLong() >= 0) {
                                            "Name-change cost unavailable. Reload account settings."
                                        }
                                        messages +=
                                            "Name change costs ${cost.asLong()} credits. Your old name will still route to your profile."
                                    }
                                    if (
                                        value.controllerIds != ProfileDraft.from(user).controllerIds
                                    ) {
                                        messages +=
                                            "Account Controllers will change from ${ProfileDraft.from(user).controllerIds.joinToString().ifEmpty { "none" }} to ${value.controllerIds.joinToString().ifEmpty { "none" }}."
                                    }
                                    confirmation =
                                        messages.joinToString("\n\n").ifEmpty {
                                            "Save your profile changes?"
                                        }
                                    error = null
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Exception) {
                                    error = e.message
                                } finally {
                                    loading = false
                                }
                            }
                        },
                        enabled = !busy && draft != null && baseline != null && !reconciliation,
                    ) {
                        Text("Save")
                    }
                }
                LazyColumn(
                    Modifier.weight(1f),
                    contentPadding = PaddingValues(20.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    draft?.let { value ->
                        item {
                            ProfileFields(
                                value,
                                enabled = !busy,
                                validation = validation,
                                onChange = { draft = it },
                            )
                        }
                        if (saveFailed && baseline != null && !reconciliation && !busy)
                            item {
                                val unsaved = value.unsavedFields(baseline!!)
                                Text(
                                    if (unsaved.isEmpty())
                                        "All requested values are present on the server."
                                    else
                                        "Values reloaded. Unsaved fields: ${unsaved.joinToString()}"
                                )
                            }
                        if (baseline != null && reconciliation)
                            item {
                                Text(
                                    "Verify the saved values before trying again. Your requested changes are kept in this editor."
                                )
                            }
                    }
                    error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
                    state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
                    if (busy) item { CircularProgressIndicator() }
                    item {
                        TextButton(onClick = { reload++ }, enabled = !busy) {
                            Text("Reload account to verify saved changes")
                        }
                    }
                }
            }
        }
    }
    confirmation?.let { message ->
        AlertDialog(
            onDismissRequest = { confirmation = null },
            title = { Text("Save account changes?") },
            text = { Text(message) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmation = null
                        account.saveProfile(draft!!, baseline!!, onDismiss) { current ->
                            if (current != null) baseline = current
                            saveFailed = true
                            reconciliation = true
                        }
                    },
                    enabled = !busy,
                ) {
                    Text("Save changes")
                }
            },
            dismissButton = { TextButton(onClick = { confirmation = null }) { Text("Cancel") } },
        )
    }
}

@Composable
internal fun ProfileFields(
    value: ProfileDraft,
    enabled: Boolean,
    validation: String?,
    onChange: (ProfileDraft) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        OutlinedTextField(
            value.name,
            { onChange(value.copy(name = it)) },
            label = { Text("Name") },
            singleLine = true,
            enabled = enabled,
            modifier = Modifier.fillMaxWidth(),
        )
        validation?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        OutlinedTextField(
            value.about,
            { onChange(value.copy(about = it)) },
            label = { Text("About") },
            enabled = enabled,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value.links,
            { onChange(value.copy(links = it)) },
            label = { Text("Label: https://example.com (one per line)") },
            enabled = enabled,
            modifier = Modifier.fillMaxWidth(),
        )
        Text("Usage mode", style = MaterialTheme.typography.titleMedium)
        listOf(
                "Credits" to "Convert rewards to credits",
                "Rewards" to "Receive ICP rewards",
                "Mining" to "Mine tokens",
            )
            .forEach { (mode, label) ->
                Row {
                    RadioButton(
                        selected = value.mode == mode,
                        onClick = { onChange(value.copy(mode = mode)) },
                        enabled = enabled,
                    )
                    TextButton(onClick = { onChange(value.copy(mode = mode)) }, enabled = enabled) {
                        Text(label)
                    }
                }
            }
        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Text("Participate in governance", Modifier.weight(1f).padding(top = 12.dp))
            Switch(
                value.governance,
                onCheckedChange = { onChange(value.copy(governance = it)) },
                enabled = enabled,
            )
        }
        OutlinedTextField(
            value.controllers,
            { onChange(value.copy(controllers = it)) },
            label = { Text("Controller Principal (one per line)") },
            enabled = enabled,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "Controllers can operate your TAGGR account. Only add Principals you trust.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
