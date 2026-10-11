package org.taggr.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.math.BigInteger
import kotlinx.coroutines.CancellationException
import org.taggr.android.data.*
import org.taggr.android.ui.PostContent

@Composable
internal fun ProposalsScreen(
    account: AccountViewModel,
    back: () -> Unit,
    openPost: (Long) -> Unit,
    openProfile: (Long) -> Unit,
    openRealm: (String) -> Unit,
    initialProposal: Long? = null,
    openTransactions: ((String) -> Unit)? = null,
) {
    val accountState by account.state.collectAsStateWithLifecycle()
    var filter by rememberSaveable { mutableStateOf("ALL") }
    var selected by
        rememberSaveable(initialProposal, accountState.principal) {
            mutableStateOf(initialProposal)
        }
    var revision by remember { mutableIntStateOf(0) }
    val pager =
        rememberPostPager(accountState.principal, filter, revision) { page, _ ->
            account.api.proposalPage(filter, page)
        }
    val paging by pager.state.collectAsStateWithLifecycle()
    LaunchedEffect(pager) { if (initialProposal == null) pager.refresh() }
    fun returnBack() {
        if (selected != null && initialProposal == null) selected = null else back()
    }
    BackHandler(onBack = ::returnBack)
    if (selected != null) {
        ProposalDetailScreen(
            account,
            selected!!,
            ::returnBack,
            openPost,
            openProfile,
            openRealm,
            openTransactions,
        )
        return
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row {
                TextButton(onClick = back) { Text("Back") }
                Text("Proposals", style = MaterialTheme.typography.headlineSmall)
            }
        }
        item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(TaggrProposal.filters) { value ->
                    FilterChip(filter == value, { filter = value }, label = { Text(value) })
                }
            }
        }
        item {
            TextButton(onClick = { revision++ }, enabled = !paging.loading) {
                Text("Refresh proposals")
            }
        }
        items(paging.posts.filter(account.safety::allowed), key = { it.id }) { post ->
            Surface(
                color = MaterialTheme.colorScheme.surfaceVariant,
                shape = MaterialTheme.shapes.medium,
            ) {
                Column(
                    Modifier.fillMaxWidth().padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(post.author, style = MaterialTheme.typography.titleMedium)
                    if (post.restriction == null) PostContent(post, false)
                    else Text(post.restriction)
                    post.proposalId
                        ?.takeIf { post.restriction == null }
                        ?.let { id ->
                            TextButton(onClick = { selected = id }) { Text("Proposal #$id") }
                        }
                    TextButton(onClick = { openPost(post.id) }) { Text("Open discussion") }
                }
            }
        }
        if (paging.posts.isEmpty() && !paging.loading && paging.error == null)
            item { Text("No proposals.") }
        item { PagedPostsFooter(paging, pager::loadMore) }
    }
}

@Composable
private fun ProposalDetailScreen(
    account: AccountViewModel,
    id: Long,
    back: () -> Unit,
    openPost: (Long) -> Unit,
    openProfile: (Long) -> Unit,
    openRealm: (String) -> Unit,
    openTransactions: ((String) -> Unit)? = null,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    val transfers by account.transferState.collectAsStateWithLifecycle()
    val creation by account.creationState.collectAsStateWithLifecycle()
    val operationsReady =
        !financial.restoring &&
            !financial.blocked &&
            financial.pending == null &&
            !transfers.restoring &&
            !transfers.blocked &&
            transfers.pending == null &&
            !creation.restoring &&
            !creation.blocked &&
            creation.pending == null
    var input by rememberSaveable(id, state.principal) { mutableStateOf("") }
    var voteError by remember(id, state.principal) { mutableStateOf<String?>(null) }
    var confirmation by remember(id, state.principal) { mutableStateOf<ProposalVote?>(null) }
    var maximum by remember(id) { mutableStateOf(0uL) }
    val canonical =
        ProposalVotes.canonical(
            account.api.configuration.apiBaseURL,
            TaggrRuntime.domain,
            account.api.configuration.canisterId,
        )
    var proposal by remember(id, state.principal) { mutableStateOf<TaggrProposal?>(null) }
    var names by remember(id, state.principal) { mutableStateOf<Map<Long, String>>(emptyMap()) }
    var post by remember(id, state.principal) { mutableStateOf<TaggrPost?>(null) }
    var decimals by remember(id) { mutableIntStateOf(0) }
    var threshold by remember(id) { mutableIntStateOf(0) }
    var loading by remember(id, state.principal) { mutableStateOf(true) }
    var error by remember(id, state.principal) { mutableStateOf<String?>(null) }
    var revision by remember(id, state.principal) { mutableIntStateOf(0) }
    LaunchedEffect(id, state.principal, revision, state.busy) {
        if (state.busy) return@LaunchedEffect
        loading = true
        error = null
        proposal = null
        post = null
        names = emptyMap()
        try {
            val value = account.api.proposal(id)
            val discussion =
                account.api.posts(listOf(value.postId)).firstOrNull { it.id == value.postId }
            val config = account.api.jsonQuery("config")
            decimals =
                config
                    .required("token_decimals")
                    .also { require(it.isIntegralNumber && it.asInt() in 0..255) }
                    .asInt()
            threshold =
                config
                    .required("proposal_approval_threshold")
                    .also { require(it.isIntegralNumber && it.asInt() in 1..99) }
                    .asInt()
            maximum = WithdrawQuote.unsigned(config, "max_funding_amount")
            val ids =
                (listOf(value.proposer) +
                        value.bulletins.map { it.user } +
                        listOfNotNull(value.payload.user))
                    .distinct()
                    .filter(account.safety::allowedUser)
            if (
                discussion != null &&
                    discussion.restriction == null &&
                    account.safety.allowed(discussion) &&
                    ids.isNotEmpty()
            ) {
                val users = account.api.jsonQuery("users_data", listOf(ids))
                require(users.isObject) { "Participant names unavailable" }
                names =
                    users
                        .fields()
                        .asSequence()
                        .mapNotNull { (key, name) ->
                            key.toLongOrNull()
                                ?.takeIf {
                                    it in ids && name.isTextual && name.asText().isNotBlank()
                                }
                                ?.let { it to name.asText() }
                        }
                        .toMap()
            }
            proposal = value
            post = discussion
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: "Proposal unavailable"
        } finally {
            loading = false
        }
    }
    fun prepare(adopted: Boolean) {
        try {
            val current = proposal ?: error("Proposal unavailable")
            val owner = state.principal ?: error("Sign in to vote")
            val userId =
                state.user?.path("id")?.asLong(-1)?.takeIf { it >= 0 }
                    ?: error("Create your TAGGR account first.")
            require(ProposalVotes.canVote(current, userId, owner, canonical))
            val data = ProposalVotes.data(current, adopted, input, decimals, maximum)
            confirmation =
                ProposalVote(
                    owner,
                    userId,
                    financialNetwork(account.api.configuration),
                    current.id,
                    current.postId,
                    current.payload,
                    adopted,
                    data,
                    System.currentTimeMillis(),
                )
            voteError = null
        } catch (e: Exception) {
            voteError = e.message ?: "Vote cannot be prepared"
        }
    }
    confirmation?.let { vote ->
        ProposalVoteConfirmation(vote, state.busy, { confirmation = null }) {
            confirmation = null
            account.voteOnProposal(vote) { revision++ }
        }
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            TextButton(onClick = back) { Text("Back") }
            Text("Proposal #$id", style = MaterialTheme.typography.headlineSmall)
        }
        item {
            if (loading) CircularProgressIndicator()
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            TextButton(onClick = { revision++ }, enabled = !loading) { Text("Refresh proposal") }
        }
        item {
            proposal?.let {
                ProposalDetails(
                    it,
                    post?.takeIf(account.safety::allowed),
                    decimals,
                    threshold,
                    openPost,
                    openProfile,
                    openRealm,
                    account.safety::allowedUser,
                    openTransactions,
                    name = { names[it] ?: "User #$it" },
                )
            }
        }
        item {
            proposal
                ?.takeIf {
                    post?.restriction == null && post != null && account.safety.allowed(post!!)
                }
                ?.let { value ->
                    ProposalVoteControls(
                        value,
                        state.principal,
                        state.user?.path("id")?.asLong(-1),
                        canonical,
                        decimals,
                        maximum,
                        !loading && !state.busy && operationsReady,
                        input,
                        { input = it },
                        ::prepare,
                    )
                    if (
                        value.bulletins.any { it.user == state.user?.path("id")?.asLong(-1) } &&
                            state.user?.path("id")?.asLong(-1) !in post!!.watchers
                    ) {
                        TextButton(
                            onClick = { account.followProposal(value.id) },
                            enabled = !state.busy && operationsReady,
                        ) {
                            Text("Follow discussion")
                        }
                    }
                }
            voteError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (financial.pending?.method in listOf("vote_on_proposal", "toggle_following_post")) {
                Text(
                    "A vote or discussion follow is pending. Check its result before another action."
                )
                TextButton(onClick = account::checkFinancial, enabled = !state.busy) {
                    Text("Check vote result")
                }
            }
        }
    }
}

@Composable
internal fun ProposalDetails(
    proposal: TaggrProposal,
    post: TaggrPost?,
    decimals: Int,
    threshold: Int,
    openPost: (Long) -> Unit,
    openProfile: (Long) -> Unit,
    openRealm: (String) -> Unit,
    visibleUser: (Long) -> Boolean = { true },
    openTransactions: ((String) -> Unit)? = null,
    name: (Long) -> String = { "User #$it" },
) {
    val uriHandler = LocalUriHandler.current
    if (post == null || post.restriction != null || post.id != proposal.postId) {
        Text("Proposal unavailable.")
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            "${proposal.payload.title} · ${proposal.status.uppercase()}",
            style = MaterialTheme.typography.titleLarge,
        )
        if (visibleUser(proposal.proposer))
            TextButton(onClick = { openProfile(proposal.proposer) }) {
                Text("Proposer: ${name(proposal.proposer)}")
            }
        Text(
            java.time.Instant.ofEpochMilli((proposal.timestamp / 1_000_000uL).toLong())
                .atZone(java.time.ZoneId.systemDefault())
                .toLocalDate()
                .toString()
        )
        PostContent(post, false)
        TextButton(onClick = { openPost(post.id) }) { Text("Open discussion") }
        val payload = proposal.payload
        when (payload.kind) {
            "Release" -> {
                Text("Commit: ${payload.commit}")
                if (proposal.status != "Open") Text("Build hash: ${payload.hash}")
                TextButton(
                    onClick = {
                        val url =
                            android.net.Uri.Builder()
                                .scheme("https")
                                .authority("github.com")
                                .appendPath("TaggrNetwork")
                                .appendPath("taggr")
                                .appendPath("commit")
                                .appendPath(payload.commit)
                                .build()
                                .toString()
                        uriHandler.openUri(url)
                    }
                ) {
                    Text("Source commit")
                }
            }
            "Funding" -> {
                if (openTransactions != null)
                    TextButton(onClick = { openTransactions(payload.recipient!!) }) {
                        Text("Recipient: ${payload.recipient}")
                    }
                else Text("Recipient: ${payload.recipient}")
                Text(
                    "Funding: ${WalletAmounts.token(BigInteger(payload.amount.toString()), decimals)}"
                )
            }
            "Rewards" -> {
                if (openTransactions != null)
                    TextButton(onClick = { openTransactions(payload.recipient!!) }) {
                        Text("Recipient: ${payload.recipient}")
                    }
                else Text("Recipient: ${payload.recipient}")
                if (proposal.status == "Executed")
                    Text(
                        "Minted: ${WalletAmounts.token(BigInteger(payload.amount.toString()), decimals)}"
                    )
            }
            "ICPTransfer" -> {
                Text("Recipient: ${payload.recipient}")
                Text("ICP: ${WalletAmounts.token(BigInteger(payload.amount.toString()), 8)}")
            }
            "AddRealmController" -> {
                TextButton(onClick = { openRealm(payload.realm!!) }) {
                    Text("Realm: /${payload.realm}")
                }
                if (visibleUser(payload.user!!))
                    TextButton(onClick = { openProfile(payload.user) }) {
                        Text("Controller: ${name(payload.user)}")
                    }
            }
            else -> Text("UNSUPPORTED PROPOSAL TYPE")
        }
        Text(
            "EFFECTIVE VOTING POWER: ${TaggrProposal.displayedPower(BigInteger(proposal.votingPower.toString()), decimals)}"
        )
        proposal.executionDays(threshold)?.let { Text("Execution deadline: $it DAYS") }
        for (adopted in listOf(true, false)) {
            Text(
                "${if (adopted) "ACCEPTED" else "REJECTED"}: ${TaggrProposal.displayedPower(proposal.power(adopted), decimals)} (${proposal.percentage(adopted)})"
            )
            LazyRow {
                items(
                    proposal.bulletins.filter { it.adopted == adopted && visibleUser(it.user) },
                    key = { it.user },
                ) { vote ->
                    TextButton(onClick = { openProfile(vote.user) }) { Text(name(vote.user)) }
                }
            }
        }
    }
}

@Composable
internal fun ProposalVoteControls(
    proposal: TaggrProposal,
    owner: String?,
    userId: Long?,
    canonical: Boolean,
    decimals: Int,
    maximum: ULong,
    enabled: Boolean,
    input: String,
    setInput: (String) -> Unit,
    prepare: (Boolean) -> Unit,
) {
    if (ProposalVotes.canVote(proposal, userId, owner, canonical)) {
        if (proposal.payload.kind == "Release")
            OutlinedTextField(
                input,
                setInput,
                label = { Text("Reproducible build hash (required to accept)") },
                enabled = enabled,
                singleLine = true,
            )
        if (proposal.payload.kind == "Rewards") {
            OutlinedTextField(
                input,
                setInput,
                label = { Text("Reward amount in whole tokens") },
                enabled = enabled,
                singleLine = true,
            )
            Text("Maximum: ${WalletAmounts.token(BigInteger(maximum.toString()), decimals)} tokens")
        }
        Row {
            TextButton(onClick = { prepare(false) }, enabled = enabled) { Text("REJECT") }
            TextButton(onClick = { prepare(true) }, enabled = enabled) { Text("ACCEPT") }
        }
    } else if (proposal.status == "Open" && !canonical)
        Text("Voting is unavailable on custom domains.")
    else if (proposal.status == "Open" && owner == null) Text("Sign in to vote.")
}

@Composable
internal fun ProposalVoteConfirmation(
    vote: ProposalVote,
    busy: Boolean,
    dismiss: () -> Unit,
    confirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) dismiss() },
        title = { Text(if (vote.adopted) "Accept proposal?" else "Reject proposal?") },
        text = {
            Column {
                Text("Proposal #${vote.proposalId}")
                Text("Signed by: ${vote.owner}")
                if (vote.data.isNotEmpty()) Text("Vote data: ${vote.data}")
            }
        },
        confirmButton = {
            TextButton(onClick = confirm, enabled = !busy) {
                Text(if (vote.adopted) "ACCEPT" else "REJECT")
            }
        },
        dismissButton = { TextButton(onClick = dismiss, enabled = !busy) { Text("Cancel") } },
    )
}
