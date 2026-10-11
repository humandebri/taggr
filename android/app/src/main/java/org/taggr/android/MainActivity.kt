package org.taggr.android

import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.CreationExtras
import org.ic4j.agent.android.InternetIdentityAuthenticator
import org.taggr.android.data.FeedMode
import org.taggr.android.data.TaggrPost
import org.taggr.android.ui.TaggrTheme

class MainActivity : ComponentActivity() {
    private lateinit var authenticator: InternetIdentityAuthenticator
    private val links
        get() = ViewModelProvider(this)[IncomingLinksViewModel::class.java]

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) links.accept(intent)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        authenticator = InternetIdentityAuthenticator(this)
        val account = ViewModelProvider(this)[AccountViewModel::class.java]
        val feeds =
            ViewModelProvider(
                this,
                object : ViewModelProvider.Factory {
                    override fun <T : androidx.lifecycle.ViewModel> create(
                        modelClass: Class<T>,
                        extras: CreationExtras,
                    ): T {
                        @Suppress("UNCHECKED_CAST")
                        return FeedViewModel(
                            account.api,
                            ownsRepository = false,
                            savedState = extras.createSavedStateHandle(),
                        )
                            as T
                    }
                },
            )[FeedViewModel::class.java]
        setContent {
            val pending = links.pending.collectAsStateWithLifecycle().value
            TaggrTheme { TaggrApp(feeds, account, authenticator, pending, links::consumed) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // The saved link queue owns new URLs; keep the Activity's original launch intent.
        links.accept(intent)
    }

    override fun onResume() {
        super.onResume()
        ViewModelProvider(this)[AccountViewModel::class.java].checkSessionExpiry()
    }

    override fun onDestroy() {
        authenticator.close()
        super.onDestroy()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedScreen(
    model: FeedViewModel,
    account: AccountViewModel? = null,
    composePost: (Long?) -> Unit = {},
    search: () -> Unit = {},
    openProfile: (String) -> Unit = {},
    editPost: (Long) -> Unit = {},
    openProposal: ((Long) -> Unit)? = null,
    backFromPost: () -> Unit = model::closePost,
    scrollToTopRevision: Int = 0,
) {
    val feed = model.feed.collectAsStateWithLifecycle().value
    val detail = model.detail.collectAsStateWithLifecycle().value
    val replies = model.replies.collectAsStateWithLifecycle().value
    val accountState = account?.state?.collectAsStateWithLifecycle()?.value
    val scroll = rememberLazyListState()
    LaunchedEffect(feed.mode, scrollToTopRevision) { scroll.scrollToItem(0) }
    BackHandler(enabled = detail != null, onBack = backFromPost)

    Scaffold(
        modifier = Modifier.imePadding(),
        containerColor = MaterialTheme.colorScheme.background,
        floatingActionButton = {
            if (detail == null)
                org.taggr.android.ui.FeedComposeButton(
                    signedIn = accountState?.principal != null,
                    hasUser = accountState?.user != null,
                    ready = accountState?.busy == false && accountState.restoring == false,
                    open = { composePost(null) },
                )
        },
        topBar = {
            TopAppBar(
                colors =
                    androidx.compose.material3.TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.surface
                    ),
                title = {
                    Text(
                        if (detail == null) "TAGGR" else "Conversation",
                        fontWeight = FontWeight.Black,
                        color = MaterialTheme.colorScheme.onBackground,
                    )
                },
                navigationIcon = {
                    if (detail != null) TextButton(onClick = backFromPost) { Text("Back") }
                },
                actions = {
                    if (detail == null) {
                        TextButton(onClick = search) { Text("Search") }
                        TextButton(onClick = model::refresh, enabled = !feed.loading) {
                            Text("Refresh")
                        }
                    } else if (account == null) org.taggr.android.ui.PostShareButton(detail.post.id)
                },
            )
        },
    ) { padding ->
        if (detail != null) {
            val conversationScroll = androidx.compose.foundation.lazy.rememberLazyListState()
            androidx.compose.runtime.LaunchedEffect(
                detail.post.id,
                detail.ancestors.map { it.id },
            ) {
                conversationScroll.scrollToItem(
                    detail.ancestors.size +
                        (if (detail.ancestors.isEmpty()) 0 else 1) +
                        (if (detail.contextIncomplete) 1 else 0)
                )
            }
            LazyColumn(Modifier.fillMaxSize().padding(padding), state = conversationScroll) {
                if (detail.ancestors.isNotEmpty())
                    item {
                        Text(
                            "Earlier in this conversation",
                            Modifier.padding(16.dp),
                            style = MaterialTheme.typography.titleMedium,
                        )
                    }
                items(detail.ancestors, key = { "ancestor-${it.id}" }) { ancestor ->
                    PostRow(
                        ancestor,
                        expanded = true,
                        openProfile = openProfile,
                        openProposal = openProposal,
                        onClick = { model.openPost(ancestor) },
                    )
                    HorizontalDivider()
                }
                if (detail.contextIncomplete)
                    item { Text("Some earlier posts are unavailable.", Modifier.padding(16.dp)) }
                item {
                    PostRow(
                        detail.post,
                        expanded = true,
                        showStats = account == null,
                        openProfile = openProfile,
                        openProposal = openProposal,
                    )
                }
                item {
                    if (account != null) {
                        org.taggr.android.ui.PostEngagementBar(
                            account,
                            detail.post,
                            reply = { composePost(detail.post.id) },
                            edit = { editPost(detail.post.id) },
                            changed = {
                                model.refresh()
                                if (account.safety.blocked(detail.post.authorId)) model.closePost()
                                else model.openPost(detail.post)
                            },
                            openProfile = openProfile,
                        )
                    }
                }
                item { HorizontalDivider() }
                item {
                    Text(
                        "Replies",
                        Modifier.padding(16.dp),
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
                if (detail.loading) item { Loading() }
                detail.error?.let { message ->
                    item { Retry(message) { model.openPost(detail.post) } }
                }
                if (!detail.loading && detail.error == null && detail.replies.isEmpty()) {
                    item {
                        Text(
                            "No replies yet.",
                            Modifier.padding(16.dp),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                items(
                    replyFeedRows(
                        detail.replies.filter { account?.safety?.allowed(it) != false },
                        replies,
                        detail.ancestors.mapTo(mutableSetOf(detail.post.id)) { it.id },
                        allowed = { account?.safety?.allowed(it) != false },
                    ),
                    key = { "reply-${it.post.id}" },
                ) { row ->
                    ExpandableFeedPost(
                        row,
                        model,
                        account,
                        replies[row.post.id],
                        composePost,
                        editPost,
                        openProfile,
                        openProposal,
                    )
                }
            }
        } else {
            Column(Modifier.fillMaxSize().padding(padding)) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    FeedMode.entries.forEach { mode ->
                        androidx.compose.material3.FilterChip(
                            selected = feed.mode == mode,
                            onClick = { model.selectMode(mode) },
                            label = {
                                Text("#${mode.title.lowercase()}", fontWeight = FontWeight.Bold)
                            },
                            colors =
                                androidx.compose.material3.FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = MaterialTheme.colorScheme.tertiary,
                                    selectedLabelColor = MaterialTheme.colorScheme.onTertiary,
                                ),
                        )
                    }
                }
                LazyColumn(
                    Modifier.fillMaxSize().testTag("home-feed"),
                    state = scroll,
                    contentPadding = PaddingValues(bottom = 16.dp),
                ) {
                    items(
                        replyFeedRows(
                            feed.posts.filter { account?.safety?.allowed(it) != false },
                            replies,
                            allowed = { account?.safety?.allowed(it) != false },
                        ),
                        key = { it.post.id },
                    ) { row ->
                        ExpandableFeedPost(
                            row,
                            model,
                            account,
                            replies[row.post.id],
                            composePost,
                            editPost,
                            openProfile,
                            openProposal,
                        )
                    }
                    if (feed.loading) item { Loading() }
                    feed.error?.let { message ->
                        item {
                            Retry(message) {
                                if (feed.posts.isEmpty()) model.refresh() else model.loadMore()
                            }
                        }
                    }
                    if (!feed.loading && feed.error == null) {
                        if (feed.posts.isEmpty()) {
                            item { Text("No posts yet.", Modifier.padding(16.dp)) }
                        } else if (feed.canLoadMore) {
                            item {
                                TextButton(
                                    onClick = model::loadMore,
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Text("Load more")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ExpandableFeedPost(
    row: ReplyFeedRow,
    model: FeedViewModel,
    account: AccountViewModel?,
    replies: PostRepliesState?,
    composePost: (Long?) -> Unit,
    editPost: (Long) -> Unit,
    openProfile: (String) -> Unit,
    openProposal: ((Long) -> Unit)?,
) {
    val post = row.post
    if (account?.safety?.allowed(post) == false) return
    Column(Modifier.padding(start = (row.depth.coerceAtMost(4) * 12).dp)) {
        PostRow(
            post,
            showStats = account == null,
            onClick = { model.openPost(post) },
            openProfile = openProfile,
            openProposal = openProposal,
        )
        if (account != null)
            org.taggr.android.ui.PostEngagementBar(
                account,
                post,
                reply = { composePost(post.id) },
                edit = { editPost(post.id) },
                changed = model::refresh,
                openProfile = openProfile,
                repliesExpanded = replies != null,
                toggleReplies = { model.toggleReplies(post) },
                submitted = {
                    model.refresh()
                    model.expandReplies(post, reloadParent = true)
                },
            )
        else if (post.replyCount > 0)
            TextButton(
                onClick = { model.toggleReplies(post) },
                modifier =
                    Modifier.semantics {
                        contentDescription = if (replies != null) "Hide replies" else "Show replies"
                    },
            ) {
                Text("${post.replyCount} replies")
            }
        if (replies?.loading == true) Loading()
        replies?.error?.let { message -> Retry(message) { model.expandReplies(post) } }
        if (replies != null && !replies.loading && replies.error == null && replies.posts.isEmpty())
            Text("No replies available.", Modifier.padding(16.dp))
        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
    }
}

@Composable
private fun PostRow(
    post: TaggrPost,
    expanded: Boolean = false,
    showStats: Boolean = true,
    onClick: (() -> Unit)? = null,
    openProfile: (String) -> Unit = {},
    openProposal: ((Long) -> Unit)? = null,
) {
    val openRealm = LocalRealmOpen.current
    Column(
        modifier =
            Modifier.fillMaxWidth()
                .testTag("post-row-${post.id}")
                .then(
                    if (onClick != null)
                        Modifier.clickable(
                            onClick = onClick,
                            onClickLabel = "Open post by ${post.author}",
                        )
                    else Modifier
                )
                .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                post.author,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.secondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier =
                    Modifier.weight(1f).clickable(onClickLabel = "Open profile") {
                        openProfile(post.author)
                    },
            )
            org.taggr.android.ui.PostTimestamp(post.timestampMillis)
            post.realm
                ?.takeIf { it.isNotBlank() }
                ?.let { realm ->
                    Text(
                        realm,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier =
                            Modifier.widthIn(max = 110.dp)
                                .then(
                                    if (openRealm != null)
                                        Modifier.clickable(onClickLabel = "Open realm $realm") {
                                                openRealm(realm)
                                            }
                                            .semantics { contentDescription = "Open realm $realm" }
                                    else Modifier
                                ),
                    )
                }
        }
        org.taggr.android.ui.UserBadgeRow(post.authorBadges)
        val text = post.restriction ?: if (expanded) post.body else post.timelineBody
        if (post.restriction != null) {
            Text(text, style = MaterialTheme.typography.bodyLarge)
        } else {
            org.taggr.android.ui.PostContent(post, expanded, showAuthorBadges = false)
            ProposalLink(post, openProposal)
        }
        if (showStats)
            Text(
                "${post.replyCount} replies · ${post.reactionCount} reactions" +
                    (if (post.reposts.isNotEmpty()) " · ${post.reposts.size} reposts" else "") +
                    (if (post.tipCount > 0) " · ${post.tipCount} tips" else ""),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
    }
}

@Composable
private fun Loading() {
    Row(Modifier.fillMaxWidth().padding(24.dp), horizontalArrangement = Arrangement.Center) {
        CircularProgressIndicator()
    }
}

@Composable
private fun Retry(message: String, retry: () -> Unit) {
    Column(Modifier.padding(16.dp)) {
        Text(message, color = MaterialTheme.colorScheme.error)
        TextButton(onClick = retry) { Text("Try again") }
    }
}
