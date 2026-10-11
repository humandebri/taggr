package org.taggr.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import org.taggr.android.AccountViewModel
import org.taggr.android.data.*

@Composable
internal fun ReactionDetails(
    account: AccountViewModel,
    post: TaggrPost,
    openProfile: (String) -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    var order by remember { mutableStateOf(ReactionGroup.defaultOrder) }
    var names by
        remember(post.id, state.principal) { mutableStateOf<Map<Long, String>>(emptyMap()) }
    var loading by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    val counts = remember(post.id, post.reactions) { mutableStateMapOf<Int, Int>() }
    val groups = ReactionGroup.groups(post.reactions, order)
    if (groups.isEmpty()) return
    val visible =
        groups
            .flatMap { it.users.filter(account.safety::allowedUser).take(counts[it.id] ?: 20) }
            .distinct()
            .filter { it < 9007199254739991L && account.safety.allowedUser(it) }
    LaunchedEffect(account, post.id) {
        try {
            val configured =
                account.api.jsonQuery("config").path("reactions").mapNotNull { row ->
                    row.get(0)?.takeIf { it.isIntegralNumber && it.asInt(-1) in 0..65535 }?.asInt()
                }
            order = configured.ifEmpty { ReactionGroup.defaultOrder }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            order = ReactionGroup.defaultOrder
        }
    }
    LaunchedEffect(visible, state.principal, revision) {
        loading = true
        failed = false
        try {
            val own = state.user?.path("id")?.asLong()
            val ownName = state.user?.path("name")?.asText()
            if (own != null && !ownName.isNullOrBlank()) names = names + (own to ownName)
            val missing = visible.filter { it !in names }
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
    ReactionDetailsContent(
        groups,
        names,
        counts,
        loading,
        failed,
        { revision++ },
        { id -> openProfile(id.toString()) },
        account.safety::allowedUser,
    )
}

@Composable
internal fun ReactionDetailsContent(
    groups: List<ReactionGroup>,
    names: Map<Long, String>,
    counts: MutableMap<Int, Int>,
    loading: Boolean,
    failed: Boolean,
    retry: () -> Unit,
    profile: (Long) -> Unit,
    allowed: (Long) -> Boolean = { true },
) {
    Column(
        Modifier.fillMaxWidth().padding(12.dp).testTag("reaction-details"),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            "REACTIONS",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (loading) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("Loading names", style = MaterialTheme.typography.bodySmall)
        }
        if (failed) {
            Text("Some names could not be loaded.", style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = retry, enabled = !loading) { Text("Retry names") }
        }
        groups.forEach { group ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "${group.emoji} ${group.users.size}",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Bold,
                )
                val users = group.users.filter(allowed)
                val color = MaterialTheme.colorScheme.primary
                Text(
                    buildAnnotatedString {
                        users.take(counts[group.id] ?: 20).forEachIndexed { index, id ->
                            if (index > 0) append(", ")
                            val name = names[id]
                            if (name != null && id < 9007199254739991L)
                                withLink(
                                    LinkAnnotation.Clickable(
                                        id.toString(),
                                        TextLinkStyles(SpanStyle(color = color)),
                                        { profile(id) },
                                    )
                                ) {
                                    append(name)
                                }
                            else append("@$id")
                        }
                    },
                    Modifier.testTag("reaction-voters-${group.id}"),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (users.size > (counts[group.id] ?: 20))
                    TextButton(onClick = { counts[group.id] = (counts[group.id] ?: 20) + 20 }) {
                        Text("More users")
                    }
            }
        }
    }
}
