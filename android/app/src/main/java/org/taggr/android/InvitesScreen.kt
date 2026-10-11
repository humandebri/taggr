package org.taggr.android

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.net.URI
import kotlinx.coroutines.CancellationException
import org.taggr.android.data.*

@Composable
internal fun InvitesScreen(
    account: AccountViewModel,
    back: () -> Unit,
    openProfile: (Long) -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    var rows by remember(state.principal) { mutableStateOf<List<TaggrInvite>>(emptyList()) }
    var names by remember(state.principal) { mutableStateOf<Map<Long, String>>(emptyMap()) }
    var minimum by remember(state.principal) { mutableStateOf<ULong?>(null) }
    var loading by remember(state.principal) { mutableStateOf(false) }
    var error by remember(state.principal) { mutableStateOf<String?>(null) }
    var revision by remember(state.principal) { mutableIntStateOf(0) }
    var editing by remember(state.principal) { mutableStateOf<TaggrInvite?>(null) }
    var editor by remember(state.principal) { mutableStateOf(false) }
    LaunchedEffect(state.principal, state.user?.path("id"), revision, state.busy) {
        if (state.busy || state.principal == null || state.user == null) return@LaunchedEffect
        loading = true
        error = null
        try {
            rows = Invites.decode(account.api.jsonQuery("invites", signed = true))
            minimum =
                WithdrawQuote.unsigned(account.api.jsonQuery("config"), "min_credits_for_inviting")
            val ids = rows.flatMap { it.joined }.distinct().filter(account.safety::allowedUser)
            names =
                if (ids.isEmpty()) emptyMap()
                else {
                    val users = account.api.jsonQuery("users_data", listOf(ids))
                    require(users.isObject) { "Participant names unavailable" }
                    users
                        .fields()
                        .asSequence()
                        .mapNotNull { (key, value) ->
                            key.toLongOrNull()
                                ?.takeIf {
                                    it in ids && value.isTextual && value.asText().isNotBlank()
                                }
                                ?.let { it to value.asText() }
                        }
                        .toMap()
                }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: "Invites unavailable"
        } finally {
            loading = false
        }
    }
    val context = LocalContext.current
    val origin = remember {
        URI(
            "${if (account.api.configuration.apiBaseURL.scheme == "http") "http" else "https"}://${TaggrRuntime.domain}"
        )
    }
    BackHandler(onBack = back)
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Row {
                TextButton(onClick = back) { Text("Back") }
                Text("Invites", style = MaterialTheme.typography.headlineSmall)
            }
        }
        item {
            if (state.user == null) Text("Sign in and create your TAGGR account to manage invites.")
            else {
                Text(
                    "Credits are charged when an invite is used. It stops working if your balance is insufficient."
                )
                TextButton(
                    onClick = {
                        editing = null
                        editor = true
                    },
                    enabled =
                        !state.busy &&
                            !loading &&
                            minimum != null &&
                            error == null &&
                            !financial.restoring &&
                            !financial.blocked &&
                            financial.pending == null,
                ) {
                    Text("Create invite")
                }
            }
            if (loading) CircularProgressIndicator()
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            TextButton(onClick = { revision++ }, enabled = !loading && !state.busy) {
                Text("Refresh invites")
            }
            if (financial.pending?.method in listOf("create_invite", "update_invite")) {
                Text("An invite change is pending. Check its result before trying again.")
                TextButton(onClick = account::checkFinancial, enabled = !state.busy) {
                    Text("Check invite result")
                }
            }
            if (state.user != null && rows.isEmpty() && !loading && error == null)
                Text("No invites.")
        }
        items(rows, key = { it.code }) { row ->
            val url = Invites.url(row.code, origin)
            InviteCard(
                row,
                url,
                !state.busy &&
                    !loading &&
                    minimum != null &&
                    error == null &&
                    !financial.restoring &&
                    financial.pending == null &&
                    !financial.blocked,
                copy = { text ->
                    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                        .setPrimaryClip(ClipData.newPlainText("TAGGR invite", text))
                },
                share = {
                    context.startActivity(
                        Intent.createChooser(
                            Intent(Intent.ACTION_SEND)
                                .setType("text/plain")
                                .putExtra(Intent.EXTRA_TEXT, url),
                            "Share invite",
                        )
                    )
                },
                edit = {
                    editing = row
                    editor = true
                },
                openProfile = { if (account.safety.allowedUser(it)) openProfile(it) },
                visibleUser = account.safety::allowedUser,
                name = { names[it] ?: "User #$it" },
            )
        }
    }
    if (editor && minimum != null)
        InviteEditor(
            editing,
            minimum!!,
            state.busy,
            financial.pending != null,
            { editor = false },
            serverError = state.error,
        ) { draft ->
            state.principal?.let {
                account.saveInvite(it, editing, draft) {
                    editor = false
                    revision++
                }
            }
        }
}

@Composable
internal fun InviteCard(
    row: TaggrInvite,
    url: String,
    enabled: Boolean,
    copy: (String) -> Unit,
    share: () -> Unit,
    edit: () -> Unit,
    openProfile: (Long) -> Unit,
    visibleUser: (Long) -> Boolean = { true },
    name: (Long) -> String = { "User #$it" },
) {
    Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.medium) {
        Column(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(row.code.uppercase(), style = MaterialTheme.typography.titleMedium)
            Text("Credits: ${row.credits} · Per user: ${row.perUser}")
            Text("Realm: ${row.realm ?: "Global"}")
            Text(if (row.credits == 0uL) "Stopped" else "Active")
            LazyRow {
                items(row.joined.filter(visibleUser), key = { it }) { id ->
                    TextButton(onClick = { openProfile(id) }) { Text(name(id)) }
                }
            }
            Row {
                TextButton(onClick = { copy(row.code.uppercase()) }) { Text("Copy code") }
                TextButton(onClick = { copy(url) }) { Text("Copy URL") }
            }
            Row {
                TextButton(onClick = share) { Text("Share") }
                TextButton(onClick = edit, enabled = enabled) { Text("Edit") }
            }
            InviteQRCode(url)
        }
    }
}

@Composable
internal fun InviteQRCode(url: String) {
    val matrix = remember(url) { InviteQR.matrix(url) }
    Canvas(
        Modifier.size(180.dp).background(Color.White).semantics {
            contentDescription = "Invite QR code"
        }
    ) {
        val unit = size.width / matrix.width
        for (y in 0 until matrix.height) for (x in 0 until matrix.width) if (matrix[x, y])
            drawRect(Color.Black, Offset(x * unit, y * unit), Size(unit, unit))
    }
}

@Composable
internal fun InviteEditor(
    entry: TaggrInvite?,
    minimum: ULong,
    busy: Boolean,
    uncertain: Boolean,
    dismiss: () -> Unit,
    serverError: String? = null,
    save: (InviteDraft) -> Unit,
) {
    var credits by remember(entry?.code) { mutableStateOf((entry?.credits ?: minimum).toString()) }
    var each by remember(entry?.code) { mutableStateOf((entry?.perUser ?: minimum).toString()) }
    var realm by remember(entry?.code) { mutableStateOf(entry?.realm ?: "") }
    var error by remember(entry?.code) { mutableStateOf<String?>(null) }
    var stopping by remember { mutableStateOf(false) }
    fun submit(stop: Boolean) {
        try {
            val amount =
                if (stop) 0uL
                else credits.toULongOrNull() ?: error("Enter valid whole credit amounts.")
            val perUser = each.toULongOrNull() ?: error("Enter valid whole credit amounts.")
            require(
                perUser > 0uL &&
                    amount % perUser == 0uL &&
                    (entry != null || (amount > 0uL && perUser >= minimum))
            ) {
                "Total credits must be a multiple of credits per user and meet the minimum."
            }
            require(amount != 0uL || entry?.joined?.isNotEmpty() == true) {
                "An unused invite cannot be stopped."
            }
            save(InviteDraft(amount, perUser, Invites.realm(realm)))
        } catch (e: Exception) {
            error = e.message
        }
    }
    AlertDialog(
        onDismissRequest = { if (!busy) dismiss() },
        title = { Text(if (entry == null) "Create invite" else "Edit invite") },
        text = {
            Column(
                Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedTextField(
                    credits,
                    { credits = it },
                    label = { Text("Total credits") },
                    enabled = !busy && !uncertain,
                    singleLine = true,
                )
                if (entry == null)
                    OutlinedTextField(
                        each,
                        { each = it },
                        label = { Text("Credits per user") },
                        enabled = !busy && !uncertain,
                        singleLine = true,
                    )
                else Text("Credits per user: ${entry.perUser}")
                OutlinedTextField(
                    realm,
                    { realm = it },
                    label = { Text("Realm (optional)") },
                    enabled = !busy && !uncertain,
                    singleLine = true,
                )
                Text("Minimum per user: $minimum credits")
                if (entry?.canStop == true)
                    TextButton(onClick = { stopping = true }, enabled = !busy && !uncertain) {
                        Text("Stop invite")
                    }
                else if (entry != null && entry.joined.isEmpty())
                    Text("Unused invites cannot be stopped by the current API.")
                if (uncertain) Text("Check the pending invite result before saving again.")
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                serverError
                    ?.takeUnless { it == error }
                    ?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(onClick = { submit(false) }, enabled = !busy && !uncertain) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = dismiss, enabled = !busy) { Text("Close") } },
    )
    if (stopping)
        AlertDialog(
            onDismissRequest = { stopping = false },
            title = { Text("Stop this invite?") },
            text = { Text("Remaining credits become zero. Existing invitation history is kept.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        stopping = false
                        submit(true)
                    },
                    enabled = !busy && !uncertain,
                ) {
                    Text("Stop invite")
                }
            },
            dismissButton = { TextButton(onClick = { stopping = false }) { Text("Cancel") } },
        )
}
