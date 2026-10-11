package org.taggr.android

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.taggr.android.data.*

@Composable
internal fun RealmSettingsEditor(
    account: AccountViewModel,
    context: RealmEditContext,
    dismiss: () -> Unit,
    saved: () -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    val androidContext = LocalContext.current
    val scope = rememberCoroutineScope()
    var error by remember(context) { mutableStateOf<String?>(null) }
    var draft by remember(context) { mutableStateOf(RealmSettingsDraft.from(context.baseline)) }
    var importing by remember(context) { mutableStateOf(false) }
    val picker =
        rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
            if (uri != null)
                scope.launch {
                    importing = true
                    error = null
                    try {
                        val limit = ((context.maxLogoBytes / 4) * 3 - 2).coerceAtLeast(1)
                        val image = DraftImages.import(androidContext, uri, emptySet(), limit)
                        val logo = java.util.Base64.getEncoder().encodeToString(image.bytes)
                        require(logo.length <= context.maxLogoBytes) {
                            "Logo exceeds the Realm limit."
                        }
                        draft = draft.copy(logo = logo)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        error = e.message ?: "The selected logo could not be loaded."
                    } finally {
                        importing = false
                    }
                }
        }
    RealmSettingsForm(
        context.name,
        draft,
        context.maxPenalty,
        state.busy || importing,
        !financial.restoring && !financial.blocked && financial.pending == null,
        error ?: state.error,
        { draft = it },
        dismiss,
        {
            picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
        },
        save = {
            try {
                draft.payload(context.baseline, context.maxPenalty, context.maxLogoBytes)
            } catch (e: Exception) {
                error = e.message
                return@RealmSettingsForm
            }
            error = null
            account.saveRealmEdit(context, draft, saved)
        },
        pending = financial.pending?.method == "edit_realm",
        checkResult = account::checkFinancial,
        logoPreview = { RealmLogoPreview(draft.logo) },
    )
}

@Composable
internal fun RealmLogoPreview(encoded: String?) {
    var bitmap by remember(encoded) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(encoded) {
        bitmap = withContext(Dispatchers.Default) { encoded?.let(RealmLogo::decode) }
    }
    bitmap?.let { Image(it.asImageBitmap(), "Selected Realm logo", Modifier.size(64.dp)) }
}

@Composable
internal fun RealmSettingsForm(
    name: String,
    draft: RealmSettingsDraft,
    maxPenalty: ULong,
    busy: Boolean,
    ready: Boolean,
    error: String?,
    change: (RealmSettingsDraft) -> Unit,
    dismiss: () -> Unit,
    pickLogo: () -> Unit,
    save: () -> Unit,
    pending: Boolean = false,
    checkResult: () -> Unit = {},
    logoPreview: @Composable () -> Unit = {},
) {
    Dialog(onDismissRequest = { if (!busy) dismiss() }) {
        Surface(shape = MaterialTheme.shapes.large) {
            Column(
                Modifier.padding(16.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Manage /$name", style = MaterialTheme.typography.titleLarge)
                OutlinedTextField(
                    draft.description,
                    { change(draft.copy(description = it)) },
                    label = { Text("Description") },
                    enabled = !busy,
                )
                Text(
                    "${draft.description.toByteArray().size} / 2,000 UTF-8 bytes",
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedTextField(
                    draft.labelColor,
                    { change(draft.copy(labelColor = it)) },
                    label = { Text("Label color (#RRGGBB)") },
                    singleLine = true,
                    enabled = !busy,
                )
                logoPreview()
                TextButton(onClick = pickLogo, enabled = !busy) { Text("Replace logo") }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Adult content")
                    Switch(
                        draft.adultContent,
                        { change(draft.copy(adultContent = it)) },
                        enabled = !busy,
                    )
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Allow comments from everyone")
                    Switch(
                        !draft.commentsFiltering,
                        { change(draft.copy(commentsFiltering = !it)) },
                        enabled = !busy,
                    )
                }
                OutlinedTextField(
                    draft.cleanupPenalty,
                    { change(draft.copy(cleanupPenalty = it)) },
                    label = { Text("Cleanup penalty") },
                    singleLine = true,
                    enabled = !busy,
                )
                Text(
                    "Maximum cleanup penalty: $maxPenalty credits",
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedTextField(
                    draft.maxDownvotes,
                    { change(draft.copy(maxDownvotes = it)) },
                    label = { Text("Maximum downvotes") },
                    singleLine = true,
                    enabled = !busy,
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (pending) {
                    Text("Realm settings result is unknown. Check its result before saving again.")
                    TextButton(onClick = checkResult, enabled = !busy) {
                        Text("Check Realm update result")
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    TextButton(onClick = dismiss, enabled = !busy) { Text("Cancel") }
                    Button(onClick = save, enabled = !busy && ready) { Text("Save") }
                }
            }
        }
    }
}
