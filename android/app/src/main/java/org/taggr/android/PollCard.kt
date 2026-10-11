package org.taggr.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.math.BigInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import org.taggr.android.data.*
import org.taggr.android.ui.markdownText

internal val LocalPollAccount = staticCompositionLocalOf<AccountViewModel?> { null }
internal val LocalPollProfile = staticCompositionLocalOf<(Long) -> Unit> { {} }

@Composable
internal fun PollCard(post: TaggrPost) {
    val account = LocalPollAccount.current
    val openProfile = LocalPollProfile.current
    if (account == null) {
        post.poll?.let {
            PollContent(
                it,
                PollPresentation(
                    it,
                    post.pollTimestampMillis,
                    null,
                    BigInteger.ZERO,
                    false,
                    System.currentTimeMillis(),
                ),
                emptyMap(),
                0,
                false,
                { _, _ -> },
                {},
                {},
            )
        }
        return
    }
    val state by account.state.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    var current by remember(post.id, post.poll) { mutableStateOf(post) }
    var changing by
        rememberSaveable(post.id, state.principal, current.poll) { mutableStateOf(false) }
    var revision by remember(post.id, state.principal) { mutableIntStateOf(0) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var revote by remember { mutableStateOf<BigInteger?>(null) }
    var decimals by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }
    var names by remember(post.id) { mutableStateOf<Map<BigInteger, String>>(emptyMap()) }
    var namesRequested by remember(post.id) { mutableStateOf<Set<BigInteger>>(emptySet()) }
    var awaitingResult by remember(post.id, state.principal) { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    val pendingHere =
        financial.pending?.let {
            it.method == "vote_on_poll" &&
                com.fasterxml.jackson.databind.ObjectMapper().readTree(it.arguments)[0].asLong() ==
                    post.id
        } == true
    LaunchedEffect(pendingHere) {
        if (pendingHere) awaitingResult = true
        else if (awaitingResult) {
            awaitingResult = false
            revision++
        }
    }
    LaunchedEffect(post.id) {
        while (isActive) {
            now = System.currentTimeMillis()
            delay(60000)
        }
    }
    LaunchedEffect(state.principal, revision) {
        error = null
        refreshing = true
        try {
            val config = account.api.jsonQuery("config")
            revote = TaggrPoll.unsigned(config.required("poll_revote_deadline_hours"))
            val decimalNode = config.required("token_decimals")
            require(decimalNode.isIntegralNumber && decimalNode.asInt(-1) in 0..18)
            decimals = decimalNode.asInt()
            if (revision > 0)
                current = account.api.posts(listOf(post.id)).single { it.id == post.id }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            error = "Poll settings or updated results could not be loaded."
        } finally {
            refreshing = false
        }
    }
    LaunchedEffect(namesRequested, state.principal, revision) {
        val ids = namesRequested.filter {
            TaggrPoll.resolvableUser(it) && it.toLong() != state.user?.path("id")?.asLong(-1)
        }
        if (ids.isNotEmpty())
            try {
                val result = account.api.jsonQuery("users_data", listOf(ids))
                require(result.isObject)
                names =
                    ids.mapNotNull { id ->
                            result[id.toString()]
                                ?.takeIf {
                                    it.isTextual &&
                                        it.asText().isNotBlank() &&
                                        it.asText().length <= 256
                                }
                                ?.let { id to it.asText() }
                        }
                        .toMap()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                error = "Some voter names could not be loaded."
            }
    }
    val poll = current.poll ?: return
    if (current.restriction != null || !account.safety.allowed(current)) return
    val userId = state.user?.path("id")?.asLong(-1)?.takeIf { it >= 0 && revote != null }
    val presentation =
        PollPresentation(
            poll,
            current.pollTimestampMillis,
            userId,
            revote ?: BigInteger.ZERO,
            changing,
            now,
        )
    val blocked =
        state.busy ||
            refreshing ||
            financial.restoring ||
            financial.blocked ||
            financial.pending != null
    if (refreshing)
        LinearProgressIndicator(Modifier.fillMaxWidth().testTag("poll-loading-${post.id}"))
    PollContent(
        poll,
        presentation,
        names +
            listOfNotNull(
                    userId?.let {
                        BigInteger.valueOf(it) to state.user!!.path("name").asText(it.toString())
                    }
                )
                .toMap(),
        decimals,
        blocked,
        { option, anonymous ->
            val owner = state.principal ?: return@PollContent
            account.voteOnPoll(current, owner, option, anonymous, changing) {
                changing = false
                awaitingResult = false
                revision++
            }
        },
        { changing = true },
        { id ->
            if (TaggrPoll.resolvableUser(id) && account.safety.allowedUser(id.toLong()))
                openProfile(id.toLong())
        },
        namesNeeded = { namesRequested = it },
        visibleVoter = { !TaggrPoll.resolvableUser(it) || account.safety.allowedUser(it.toLong()) },
    )
    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    if (error != null && !refreshing) TextButton(onClick = { revision++ }) { Text("Retry poll") }
    if (pendingHere)
        TextButton(onClick = account::checkFinancial, enabled = !state.busy) {
            Text("Check vote result")
        }
}

@Composable
internal fun PollContent(
    poll: TaggrPoll,
    presentation: PollPresentation,
    names: Map<BigInteger, String>,
    decimals: Int,
    blocked: Boolean,
    vote: (Int, Boolean) -> Unit,
    change: () -> Unit,
    openProfile: (BigInteger) -> Unit,
    namesNeeded: (Set<BigInteger>) -> Unit = {},
    visibleVoter: (BigInteger) -> Boolean = { true },
) {
    var selected by
        rememberSaveable(poll, presentation.userId, presentation.changing) {
            mutableStateOf<Int?>(null)
        }
    var optionCount by remember(poll.options) { mutableIntStateOf(20) }
    val voterCounts = remember(poll) { mutableStateMapOf<Int, Int>() }
    val displayed = presentation.displayedVotes
    val ids =
        (0 until minOf(optionCount, poll.options.size))
            .flatMap { index ->
                displayed[index].orEmpty().filter(visibleVoter).take(voterCounts[index] ?: 20)
            }
            .filter(TaggrPoll::resolvableUser)
            .toSet()
    LaunchedEffect(ids) { namesNeeded(ids) }
    Surface(shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp)) {
        Column(
            Modifier.fillMaxWidth().padding(12.dp).testTag("poll"),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Poll", style = MaterialTheme.typography.labelLarge)
            poll.options.take(optionCount).forEachIndexed { index, option ->
                if (presentation.voting)
                    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        RadioButton(
                            selected == index,
                            { selected = index },
                            enabled = !blocked,
                            modifier = Modifier.testTag("poll-option-$index"),
                        )
                        Text(markdownText(option), Modifier.weight(1f))
                    }
                else {
                    val voters = displayed[index].orEmpty()
                    Column(
                        Modifier.fillMaxWidth()
                            .background(
                                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.65f),
                                RoundedCornerShape(8.dp),
                            )
                            .padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Row {
                            Text(
                                markdownText(option),
                                Modifier.weight(1f),
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                "${voters.size} (${presentation.percentage(index)}%)",
                                Modifier.padding(start = 8.dp),
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Box(
                            Modifier.fillMaxWidth()
                                .height(6.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                        ) {
                            val fraction = presentation.percentage(index).coerceIn(0, 100) / 100f
                            if (fraction > 0f)
                                Box(
                                    Modifier.fillMaxWidth(fraction)
                                        .fillMaxHeight()
                                        .clip(RoundedCornerShape(3.dp))
                                        .background(
                                            MaterialTheme.colorScheme.onSurfaceVariant.copy(
                                                alpha = 0.55f
                                            )
                                        )
                                )
                        }
                        val shown = voters.filter(visibleVoter).take(voterCounts[index] ?: 20)
                        if (shown.isNotEmpty()) {
                            val linkColor = MaterialTheme.colorScheme.primary
                            Text(
                                buildAnnotatedString {
                                    shown.forEachIndexed { position, id ->
                                        if (position > 0) append(", ")
                                        if (TaggrPoll.resolvableUser(id))
                                            withLink(
                                                LinkAnnotation.Clickable(
                                                    id.toString(),
                                                    TextLinkStyles(SpanStyle(color = linkColor)),
                                                    { openProfile(id) },
                                                )
                                            ) {
                                                append(names[id] ?: id.toString())
                                            }
                                        else append("N/A")
                                    }
                                },
                                Modifier.testTag("poll-voters-$index"),
                                style = MaterialTheme.typography.bodySmall,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    if (voters.count(visibleVoter) > (voterCounts[index] ?: 20))
                        TextButton(
                            onClick = { voterCounts[index] = (voterCounts[index] ?: 20) + 20 }
                        ) {
                            Text("More voters")
                        }
                }
            }
            if (poll.options.size > optionCount)
                TextButton(onClick = { optionCount += 20 }) { Text("More options") }
            if (presentation.voting) {
                Text(
                    "Anonymous votes cannot be changed.",
                    style = MaterialTheme.typography.bodySmall,
                )
                FlowRow {
                    TextButton(
                        onClick = { selected?.let { vote(it, true) } },
                        enabled = selected != null && !blocked,
                    ) {
                        Text("SUBMIT ANONYMOUSLY")
                    }
                    TextButton(
                        onClick = { selected?.let { vote(it, false) } },
                        enabled = selected != null && !blocked,
                    ) {
                        Text("SUBMIT")
                    }
                }
            }
            if (!presentation.expired) {
                Text(presentation.expirationText)
                if (presentation.canChange)
                    TextButton(onClick = change, enabled = !blocked) { Text("CHANGE VOTE") }
            } else if (poll.weightedByTokens.isEmpty()) Text("RESULTS ARE PENDING")
            else {
                Text("RESULTS BY VOTING POWER")
                poll.options.take(optionCount).forEachIndexed { index, option ->
                    presentation.votingPower(index, decimals)?.let { amount ->
                        Row {
                            Text(markdownText(option), Modifier.weight(1f))
                            Text(java.text.NumberFormat.getIntegerInstance().format(amount))
                        }
                    }
                }
            }
        }
    }
}
