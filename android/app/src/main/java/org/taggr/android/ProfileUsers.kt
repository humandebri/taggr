package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fasterxml.jackson.databind.JsonNode
import kotlinx.coroutines.CancellationException

internal enum class ProfileUserList(val title: String, val field: String) {
    Following("Follows", "followees"),
    Followers("Followers", "followers");

    fun ids(profile: JsonNode): List<Long> =
        profile
            .path(field)
            .filter { it.isIntegralNumber && it.canConvertToLong() }
            .map { it.asLong() }
            .filter {
                it >= 0 &&
                    it < 9007199254739991L &&
                    (this != Following || it != profile.path("id").asLong())
            }
            .distinct()
            .sorted()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ProfileUsersSheet(
    account: AccountViewModel,
    profile: JsonNode,
    kind: ProfileUserList,
    dismiss: () -> Unit,
    select: (Long) -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val changed = LocalProfileChanged.current
    val currentProfile = state.user?.takeIf { it.path("id") == profile.path("id") } ?: profile
    val ids = remember(currentProfile, kind) { kind.ids(currentProfile) }
    var count by remember(profile, kind) { mutableIntStateOf(50) }
    val visible = ids.take(count)
    var names by remember(profile, kind) { mutableStateOf<Map<Long, String>>(emptyMap()) }
    var loading by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    LaunchedEffect(visible, revision, state.principal) {
        val missing = visible.filter { it !in names }
        if (missing.isEmpty()) {
            failed = false
            return@LaunchedEffect
        }
        loading = true
        failed = false
        try {
            for (batch in missing.chunked(50)) {
                val response = account.api.jsonQuery("users_data", listOf(batch))
                names =
                    names +
                        batch
                            .mapNotNull { id ->
                                response
                                    .path(id.toString())
                                    .takeIf { it.isTextual && it.asText().isNotBlank() }
                                    ?.asText()
                                    ?.let { id to it }
                            }
                            .toMap()
            }
            failed = missing.any { it !in names }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            failed = true
        } finally {
            loading = false
        }
    }
    ModalBottomSheet(onDismissRequest = dismiss) {
        ProfileUsersContent(
            kind.title,
            visible,
            names,
            loading,
            failed,
            ids.size > count,
            state.user?.path("id")?.takeIf { it.isIntegralNumber }?.asLong(),
            state.user?.path("followees")?.map { it.asLong() }?.toSet().orEmpty(),
            state.busy,
            dismiss,
            { revision++ },
            { count += 50 },
            select,
            { id ->
                state.principal?.let { owner ->
                    account.setUserFollowing(
                        id,
                        state.user?.path("followees")?.any { it.asLong(-1) == id } != true,
                        owner,
                    ) {
                        changed()
                    }
                }
            },
        )
    }
}

@Composable
internal fun ProfileUsersContent(
    title: String,
    ids: List<Long>,
    names: Map<Long, String>,
    loading: Boolean,
    failed: Boolean,
    more: Boolean,
    viewer: Long?,
    following: Set<Long>,
    busy: Boolean,
    done: () -> Unit,
    retry: () -> Unit,
    loadMore: () -> Unit,
    select: (Long) -> Unit,
    toggle: (Long) -> Unit,
) {
    LazyColumn(
        Modifier.fillMaxWidth().testTag("profile-user-list"),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Row {
                Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                TextButton(onClick = done) { Text("Done") }
            }
        }
        if (loading)
            item {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text("Loading users")
            }
        if (failed)
            item {
                Text("Some names could not be loaded.")
                TextButton(onClick = retry, enabled = !loading) { Text("Retry") }
            }
        if (ids.isEmpty()) item { Text("No users") }
        items(ids, key = { it }) { id ->
            Surface(
                shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.surfaceVariant,
            ) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
                    TextButton(
                        onClick = { select(id) },
                        modifier = Modifier.weight(1f).testTag("profile-list-user-$id"),
                    ) {
                        Text("@${names[id] ?: id}", Modifier.fillMaxWidth())
                    }
                    if (viewer != null && viewer != id)
                        TextButton(onClick = { toggle(id) }, enabled = !busy) {
                            Text(if (id in following) "Unfollow" else "Follow")
                        }
                }
            }
        }
        if (more) item { TextButton(onClick = loadMore, enabled = !loading) { Text("More users") } }
    }
}
