package org.taggr.android

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.fasterxml.jackson.databind.JsonNode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.ic4j.agent.android.InternetIdentityAuthenticator
import org.taggr.android.data.DraftImage
import org.taggr.android.data.DraftImages
import org.taggr.android.data.TaggrApi

@Composable
fun TaggrApp(
    model: FeedViewModel = viewModel(),
    account: AccountViewModel? = null,
    authenticator: InternetIdentityAuthenticator? = null,
    incomingLink: String? = null,
    consumeLink: (String) -> Unit = {},
) {
    if (account == null) {
        FeedScreen(model)
        return
    }
    val state by account.state.collectAsStateWithLifecycle()
    if (!state.acceptedTerms) {
        SafetyGate(account)
        return
    }
    // Resolve the saved account before consuming its restored navigation state.
    if (state.restoring) {
        Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.Center) {
            CircularProgressIndicator()
        }
        return
    }
    val retirement by account.retirementState.collectAsStateWithLifecycle()
    val routeState = key(state.principal) { rememberSaveableStateHolder() }
    var transactionTarget by rememberSaveable(state.principal) { mutableStateOf<String?>(null) }
    var proposalTarget by rememberSaveable(state.principal) { mutableStateOf<Long?>(null) }
    var proposals by rememberSaveable(state.principal) { mutableStateOf(false) }
    var invites by rememberSaveable(state.principal) { mutableStateOf(false) }
    var bookmarks by rememberSaveable(state.principal) { mutableStateOf(false) }
    var profile by rememberSaveable { mutableStateOf<String?>(null) }
    var profilePhotos by rememberSaveable { mutableStateOf(false) }
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var feedScrollRevision by rememberSaveable { mutableIntStateOf(0) }
    val unreadNotifications =
        remember(state.user) {
            try {
                org.taggr.android.data.Notifications.decode(state.user?.get("notifications"))
                    .entries
                    .count { !it.read }
            } catch (_: Exception) {
                0
            }
        }
    var composing by rememberSaveable { mutableStateOf(false) }
    var parent by rememberSaveable { mutableStateOf<Long?>(null) }
    var editId by rememberSaveable { mutableStateOf<Long?>(null) }
    var search by rememberSaveable { mutableStateOf(false) }
    var searchTerm by rememberSaveable(state.principal) { mutableStateOf("") }
    var realm by rememberSaveable { mutableStateOf<String?>(null) }
    var tag by rememberSaveable { mutableStateOf<List<String>?>(null) }
    var postReturn by
        rememberSaveable(state.principal, stateSaver = PostReturnRoute.Saver) {
            mutableStateOf(PostReturnRoute())
        }
    var hasPostReturn by rememberSaveable(state.principal) { mutableStateOf(false) }
    var contentOwner by rememberSaveable { mutableStateOf(state.principal) }
    // Keep route state registered while the restored account's records are checked.
    if (state.principal != null && retirement.restoring) {
        Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.Center) {
            CircularProgressIndicator()
        }
        return
    }
    if (
        state.principal != null &&
            (retirement.blocked ||
                retirement.record != null ||
                state.user?.path("deactivated")?.asBoolean() == true)
    ) {
        LaunchedEffect(state.principal, retirement.record?.stage) { model.discardCachedContent() }
        RetiredAccountScreen(account, retirement)
        return
    }
    val openPost: (Long) -> Unit = { id ->
        if (
            !hasPostReturn ||
                tab != 0 ||
                profile != null ||
                realm != null ||
                tag != null ||
                search ||
                transactionTarget != null ||
                proposals ||
                bookmarks ||
                invites
        ) {
            postReturn =
                PostReturnRoute(
                    tab,
                    profile,
                    profilePhotos,
                    realm,
                    tag,
                    search,
                    transactionTarget,
                    proposals,
                    proposalTarget,
                    bookmarks,
                    invites,
                )
            hasPostReturn = true
        }
        profile = null
        profilePhotos = false
        realm = null
        tag = null
        search = false
        proposals = false
        proposalTarget = null
        transactionTarget = null
        bookmarks = false
        invites = false
        model.openPostById(id)
        tab = 0
    }
    val returnFromPost: () -> Unit = {
        model.closePost()
        if (hasPostReturn) {
            val source = postReturn
            tab = source.tab
            profile = source.profile
            profilePhotos = source.photos
            realm = source.realm
            tag = source.tags
            search = source.search
            transactionTarget = source.transaction
            proposals = source.proposals
            proposalTarget = source.proposal
            bookmarks = source.bookmarks
            invites = source.invites
        }
        hasPostReturn = false
    }
    LaunchedEffect(profile) { if (profile == null) profilePhotos = false }
    val openProposal: (Long) -> Unit = { id ->
        proposalTarget = id
        proposals = true
        invites = false
        bookmarks = false
    }
    LaunchedEffect(state.principal, state.restoring) {
        if (state.restoring) return@LaunchedEffect
        if (contentOwner == state.principal) {
            model.restoreFocusedPost()
            return@LaunchedEffect
        }
        contentOwner = state.principal
        composing = false
        editId = null
        hasPostReturn = false
        model.discardCachedContent()
        model.selectMode(org.taggr.android.data.FeedMode.HOT)
        model.refresh()
    }
    val navigateLink: (TaggrLink) -> Unit = { destination ->
        composing = false
        parent = null
        editId = null
        transactionTarget = null
        proposalTarget = null
        proposals = false
        invites = false
        bookmarks = false
        profile = null
        profilePhotos = false
        realm = null
        tag = null
        search = false
        hasPostReturn = false
        model.closePost()
        tab = 0
        when (destination) {
            is TaggrLink.Feed -> model.selectMode(destination.mode)
            is TaggrLink.Post -> model.openPostById(destination.id)
            is TaggrLink.Profile -> {
                profile = destination.handle
                profilePhotos = destination.photos
            }
            is TaggrLink.Realm -> realm = destination.name
            is TaggrLink.Tags -> tag = destination.tags
            is TaggrLink.Search -> {
                searchTerm = destination.query
                search = true
            }
            is TaggrLink.Transactions -> transactionTarget = destination.account
            is TaggrLink.Proposal -> {
                proposalTarget = destination.id
                proposals = true
            }
            TaggrLink.Inbox -> tab = 2
            TaggrLink.Account -> tab = 3
            TaggrLink.Bookmarks -> bookmarks = true
            TaggrLink.Invites -> invites = true
            TaggrLink.Proposals -> proposals = true
        }
    }
    LaunchedEffect(incomingLink, state.restoring, state.principal) {
        if (state.restoring) return@LaunchedEffect
        val url = incomingLink ?: return@LaunchedEffect
        TaggrLinks.parse(url, org.taggr.android.data.TaggrRuntime.domain)?.let(navigateLink)
        consumeLink(url)
    }
    val externalUriHandler = LocalUriHandler.current
    CompositionLocalProvider(
        LocalUriHandler provides
            TaggrUriHandler(
                org.taggr.android.data.TaggrRuntime.domain,
                navigate = { destination ->
                    when (destination) {
                        is TaggrLink.Post -> openPost(destination.id)
                        is TaggrLink.Profile -> {
                            profile = destination.handle
                            profilePhotos = destination.photos
                        }
                        else -> navigateLink(destination)
                    }
                },
                external = externalUriHandler,
            ),
        LocalRealmOpen provides
            { name ->
                profile = null
                profilePhotos = false
                transactionTarget = null
                proposals = false
                bookmarks = false
                invites = false
                tag = null
                search = false
                realm = name
                tab = 1
                hasPostReturn = false
                model.closePost()
            },
        org.taggr.android.ui.LocalPostOpen provides openPost,
        org.taggr.android.ui.LocalPostViewer provides state.user?.path("id")?.asLong(-1),
        LocalPollAccount provides account,
        LocalPollProfile provides { id -> profile = id.toString() },
    ) {
        Scaffold(
            bottomBar = {
                NavigationBar(containerColor = MaterialTheme.colorScheme.surface) {
                    listOf("Feed", "Realms", "Inbox", "Account").forEachIndexed { index, title ->
                        NavigationBarItem(
                            selected = tab == index,
                            onClick = {
                                if (index == 0) feedScrollRevision++
                                hasPostReturn = false
                                model.closePost()
                                transactionTarget = null
                                tab = index
                                search = false
                                profile = null
                                realm = null
                                tag = null
                                bookmarks = false
                                invites = false
                                proposals = false
                            },
                            icon = { org.taggr.android.ui.RootTabIcon(index, unreadNotifications) },
                            label = { Text(title) },
                            colors =
                                NavigationBarItemDefaults.colors(
                                    selectedIconColor = MaterialTheme.colorScheme.secondary,
                                    selectedTextColor = MaterialTheme.colorScheme.secondary,
                                    indicatorColor = MaterialTheme.colorScheme.surfaceVariant,
                                ),
                        )
                    }
                }
            }
        ) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
                state.error?.let { message ->
                    Surface(color = MaterialTheme.colorScheme.errorContainer) {
                        Column(Modifier.fillMaxWidth().padding(12.dp)) {
                            Text(message)
                            TextButton(onClick = account::dismissMessage) { Text("Dismiss") }
                        }
                    }
                }
                state.notice?.let { notice ->
                    Surface(color = MaterialTheme.colorScheme.secondaryContainer) {
                        Row(Modifier.fillMaxWidth().padding(12.dp)) {
                            Text(notice, Modifier.weight(1f))
                            TextButton(onClick = account::dismissMessage) { Text("Dismiss") }
                        }
                    }
                }
                when {
                    transactionTarget != null && profile != null ->
                        ProfileScreen(
                            account,
                            profile!!,
                            { profile = null },
                            openPost,
                        )
                    transactionTarget != null ->
                        TransactionsScreen(
                            account,
                            transactionTarget!!,
                            { transactionTarget = null },
                            {
                                profile = it
                            },
                        )
                    profile != null && realm == null ->
                        ProfileScreen(
                            account,
                            profile!!,
                            { profile = null },
                            openPost,
                            initialPhotos = profilePhotos,
                        )
                    proposals ->
                        routeState.SaveableStateProvider("proposals") {
                            ProposalsScreen(
                                account,
                                { proposals = false },
                                openPost,
                                {
                                    profile = it.toString()
                                    proposals = false
                                },
                                {
                                    realm = it
                                    proposals = false
                                },
                                initialProposal = proposalTarget,
                                openTransactions = { transactionTarget = it },
                            )
                        }
                    invites ->
                        InvitesScreen(account, { invites = false }) {
                            profile = it.toString()
                            invites = false
                        }
                    bookmarks -> BookmarksScreen(account, { bookmarks = false }, openPost)
                    realm != null ->
                        RealmProfileRoute(
                            account,
                            realm!!,
                            profile,
                            { realm = null },
                            { profile = null },
                            openPost,
                            openProfile = { profile = it },
                        )
                    tag != null ->
                        TagPostsScreen(
                            account,
                            tag!!,
                            { tag = null },
                            openPost,
                        )
                    search ->
                        routeState.SaveableStateProvider("search") {
                            SearchScreen(
                                account.api,
                                term = searchTerm,
                                changeTerm = { searchTerm = it },
                                openPost = openPost,
                                back = { search = false },
                                openProfile = { profile = it },
                                openRealm = { realm = it },
                                openTag = { tag = listOf(it) },
                                openTransactions = { transactionTarget = it },
                            )
                        }
                    tab == 0 ->
                        FeedScreen(
                            model,
                            account,
                            composePost = { replyTo ->
                                if (state.user != null) {
                                    parent = replyTo
                                    editId = null
                                    composing = true
                                } else tab = 3
                            },
                            search = { search = true },
                            openProfile = { profile = it },
                            openProposal = openProposal,
                            backFromPost = returnFromPost,
                            scrollToTopRevision = feedScrollRevision,
                            editPost = { id ->
                                editId = id
                                parent = null
                                composing = true
                            },
                        )
                    tab == 1 -> RealmsScreen(account, openPost)
                    tab == 2 ->
                        InboxScreen(
                            state,
                            account,
                            openPost = openPost,
                            openProfile = { profile = it },
                            openProposal = openProposal,
                        )
                    else ->
                        AccountScreen(
                            state,
                            account,
                            signIn = { authenticator?.let(account::signIn) },
                            openTransactions = { transactionTarget = it },
                            openBookmarks = { bookmarks = true },
                            openInvites = { invites = true },
                            openProposals = {
                                routeState.removeState("proposals")
                                proposalTarget = null
                                proposals = true
                            },
                        )
                }
            }
        }
    }
    if (composing)
        PostComposer(account, parent, editId, onDismiss = { composing = false }) { id ->
            composing = false
            model.refresh()
            openPost(id)
        }
}

@Composable
private fun AccountScreen(
    state: AccountState,
    account: AccountViewModel,
    signIn: () -> Unit,
    openBookmarks: () -> Unit,
    openInvites: () -> Unit,
    openProposals: () -> Unit,
    openTransactions: (String) -> Unit,
) {
    var name by rememberSaveable { mutableStateOf("") }
    val youtubeAccess by account.youtubeAccess.collectAsStateWithLifecycle()
    var invite by rememberSaveable { mutableStateOf("") }
    var editingProfile by rememberSaveable(state.principal) { mutableStateOf(false) }
    var passwordLogin by remember { mutableStateOf(false) }
    if (passwordLogin)
        PasswordSignInDialog(
            busy = state.busy,
            error = state.error,
            dismiss = { passwordLogin = false },
            signIn = { phrase -> account.signInWithPassword(phrase) { passwordLogin = false } },
        )
    if (editingProfile && state.user != null)
        ProfileEditor(account, onDismiss = { editingProfile = false })
    LazyColumn(
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item(key = "heading") {
            Text(
                "Account",
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold,
            )
        }
        if (state.restoring || state.busy) item(key = "progress") { CircularProgressIndicator() }
        if (state.principal == null) {
            item(key = "guest-description") {
                Text("Sign in to post, follow people and join realms.")
            }
            item(key = "sign-in") {
                Button(onClick = signIn, enabled = !state.busy && !state.restoring) {
                    Text("Continue with Internet Identity")
                }
                TextButton(
                    onClick = {
                        account.dismissMessage()
                        passwordLogin = true
                    },
                    enabled = !state.busy && !state.restoring,
                ) {
                    Text("Password")
                }
            }
        } else {
            item(key = "user-name") {
                Text(
                    state.user?.path("name")?.asText() ?: "Create your TAGGR account",
                    style = MaterialTheme.typography.titleLarge,
                )
            }
            item(key = "principal") {
                Text(
                    state.principal,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (state.user == null) {
                item(key = "new-user-name") {
                    OutlinedTextField(
                        name,
                        { name = it },
                        label = { Text("User name") },
                        singleLine = true,
                    )
                }
                item(key = "invite-code") {
                    OutlinedTextField(
                        invite,
                        { invite = it },
                        label = { Text("Invite code (optional)") },
                        singleLine = true,
                    )
                }
                item(key = "create-user") {
                    Button(
                        onClick = { account.createUser(name, invite) },
                        enabled = !state.busy && name.isNotBlank(),
                    ) {
                        Text("Create account")
                    }
                }
            } else {
                item(key = "badges") { org.taggr.android.ui.ProfileUserBadges(account, state.user) }
                item(key = "about") { Text(state.user.path("about").asText()) }
                item(key = "proposals") {
                    TextButton(onClick = openProposals, enabled = !state.busy) { Text("Proposals") }
                }
                item(key = "invites") {
                    TextButton(onClick = openInvites, enabled = !state.busy) { Text("Invites") }
                }
                item(key = "bookmarks") {
                    TextButton(onClick = openBookmarks, enabled = !state.busy) { Text("Bookmarks") }
                }
                item(key = "edit-profile") {
                    TextButton(onClick = { editingProfile = true }, enabled = !state.busy) {
                        Text("Edit profile")
                    }
                }

                item(key = "refresh-account") {
                    TextButton(onClick = account::reload, enabled = !state.busy) {
                        Text("Refresh account")
                    }
                }
            }
            item(key = "wallet") { WalletPanel(state.user, account) }
            item(key = "transactions") {
                TextButton(
                    onClick = { openTransactions(state.principal!!) },
                    enabled = !state.busy,
                ) {
                    Text("TAGGR transactions")
                }
            }
            item(key = "storage") { StoragePanel(account) }
            if (state.user != null) item(key = "retirement") { AccountRetirementPanel(account) }
            item(key = "sign-out") {
                TextButton(onClick = account::signOut, enabled = !state.busy) { Text("Sign out") }
            }
        }
        item(key = "divider") { HorizontalDivider() }
        item(key = "youtube") {
            key(state.principal) {
                YouTubeAccountPanel(
                    owner = state.principal,
                    currentOwner = { account.state.value.principal },
                    access = youtubeAccess,
                    changed = { account.setYouTubeAccess(state.principal, it) },
                )
            }
        }
        item(key = "policies") { org.taggr.android.ui.PolicyLinks() }
    }
}

@Composable
internal fun PostComposer(
    account: AccountViewModel,
    parent: Long?,
    editId: Long?,
    onDismiss: () -> Unit,
    inline: Boolean = false,
    completed: (Long) -> Unit,
) {
    val state by key(account) { account.state.collectAsStateWithLifecycle() }
    val owner = state.principal
    val submitArea = remember { BringIntoViewRequester() }
    val keyboardBottom = WindowInsets.ime.getBottom(LocalDensity.current)
    LaunchedEffect(inline, keyboardBottom) {
        if (inline && keyboardBottom > 0) submitArea.bringIntoView()
    }
    var editing by
        remember(owner, editId) { mutableStateOf<org.taggr.android.data.TaggrPost?>(null) }
    var text by rememberSaveable(owner, parent, editId) { mutableStateOf("") }
    var realm by rememberSaveable(owner, parent, editId) { mutableStateOf("") }
    var loading by remember(owner, parent, editId) { mutableStateOf(true) }
    var error by remember(owner, parent, editId) { mutableStateOf<String?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    var preview by rememberSaveable(owner, parent, editId) { mutableStateOf(false) }
    var images by remember(owner, parent, editId) { mutableStateOf<List<DraftImage>>(emptyList()) }
    var importing by remember(owner, parent, editId) { mutableStateOf(false) }
    var attachmentError by remember(owner, parent, editId) { mutableStateOf<String?>(null) }
    var youtube by rememberSaveable(owner, parent, editId) { mutableStateOf(false) }
    val context = LocalContext.current
    val scope = key(owner) { rememberCoroutineScope() }
    val imageScope = "${account.api.configuration.canisterId}/$owner/$parent/$editId"
    var imageTicket by rememberSaveable(owner, parent, editId) { mutableStateOf<String?>(null) }
    var imageSelection by
        remember(owner, parent, editId) {
            mutableStateOf<androidx.compose.ui.text.TextRange?>(null)
        }
    var imageSelectionRequest by
        remember(owner, parent, editId) {
            mutableStateOf<androidx.compose.ui.text.TextRange?>(null)
        }
    val picker =
        key(owner, parent, editId) {
            rememberLauncherForActivityResult(
                ActivityResultContracts.PickMultipleVisualMedia(DraftImages.MAX_COUNT)
            ) { uris ->
                val ticket = imageTicket
                imageTicket = null
                if (uris.isNotEmpty()) {
                    importing = true
                    scope.launch {
                        try {
                            val restored =
                                kotlinx.coroutines.withTimeoutOrNull(30_000) {
                                    while (loading) delay(25)
                                    true
                                } ?: false
                            require(restored && error == null) {
                                "The draft is still restoring. Choose the images again."
                            }
                            require(
                                account.state.value.principal == owner &&
                                    imageInsertionOffset(ticket, imageScope, text) != null
                            ) {
                                "The draft changed. Choose the images again."
                            }
                            require(images.size + uris.size <= DraftImages.MAX_COUNT) {
                                "Attach up to 20 images."
                            }
                            val limit =
                                account.api
                                    .jsonQuery("config")
                                    .path("max_blob_size_bytes")
                                    .asInt(DraftImages.MAX_BYTES)
                                    .coerceAtMost(DraftImages.MAX_BYTES)
                            val added = images.toMutableList()
                            for (uri in uris) added +=
                                DraftImages.import(
                                    context,
                                    uri,
                                    added.map { it.id }.toSet() +
                                        DraftImages.storedIds(editing?.files?.keys ?: emptySet()),
                                    limit,
                                )
                            val offset = imageInsertionOffset(ticket, imageScope, text)
                            require(account.state.value.principal == owner && offset != null) {
                                "The draft changed. Choose the images again."
                            }
                            val insertion =
                                insertDraftImages(
                                    text,
                                    added.drop(images.size).map { it.markdown },
                                    offset,
                                )
                            account.saveImages(parent, editId, added)
                            text = insertion.text
                            imageSelectionRequest = insertion.selection
                            images = added
                            account.saveDraft(parent, text, realm, editId)
                            attachmentError = null
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            attachmentError = e.message ?: "Image could not be attached."
                        } finally {
                            importing = false
                        }
                    }
                }
            }
        }
    val youtubeAccess by account.youtubeAccess.collectAsStateWithLifecycle()
    if (youtube && state.principal != null) {
        key(state.principal, parent, editId) {
            YouTubeUploadScreen(
                owner = state.principal!!,
                network = org.taggr.android.data.financialNetwork(account.api.configuration),
                canister = account.api.configuration.canisterId,
                draftSlot =
                    if (editId != null) "edit/$editId"
                    else if (parent != null) "reply/$parent" else "new",
                currentOwner = { account.state.value.principal },
                insert = { uploaded ->
                    text =
                        account.insertYouTubeUpload(
                            uploaded,
                            text,
                            if (editId != null) "edit/$editId"
                            else if (parent != null) "reply/$parent" else "new",
                        )
                },
                close = { youtube = false },
                initialAccess = youtubeAccess,
                connectionChanged = { account.setYouTubeAccess(state.principal!!, it) },
            )
        }
    }
    val slot =
        if (editId != null) "edit/$editId" else if (parent != null) "reply/$parent" else "new"
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val network = org.taggr.android.data.financialNetwork(account.api.configuration)
    val canister = account.api.configuration.canisterId
    val videoStore = remember { org.taggr.android.data.YouTubeUploadJobStore(context) }
    val videoCompletion =
        remember(videoStore, account) {
            org.taggr.android.data.YouTubeDraftCompletion(videoStore) {
                account.state.value.principal
            }
        }
    var videoChecking by
        remember(owner, slot, youtubeAccess) { mutableStateOf(youtubeAccess != null) }
    var videoUploading by
        remember(state.principal, slot) {
            mutableStateOf(
                org.taggr.android.data.YouTubeBackground.isRunningForDraft(
                    context,
                    state.principal,
                    network,
                    canister,
                    slot,
                )
            )
        }
    LaunchedEffect(owner, slot, lifecycle, youtubeAccess) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (isActive) {
                val connection = youtubeAccess
                if (
                    !loading &&
                        error == null &&
                        !state.busy &&
                        !state.postOutcomeUnknown &&
                        !youtube
                ) {
                    try {
                        if (owner != null && connection != null)
                            videoCompletion.consume(
                                org.taggr.android.data.YouTubeDraftTarget(
                                    owner,
                                    network,
                                    canister,
                                    connection.channel.id,
                                    slot,
                                ),
                                connection.account.name,
                            ) { uploaded ->
                                text = account.insertYouTubeUpload(uploaded, text, slot)
                            }
                    } catch (cancel: CancellationException) {
                        throw cancel
                    } catch (_: Exception) {
                        attachmentError =
                            "The completed video needs checking. Open Upload video to YouTube to continue."
                    } finally {
                        videoChecking = false
                    }
                }
                videoUploading =
                    org.taggr.android.data.YouTubeBackground.isRunningForDraft(
                        context,
                        state.principal,
                        network,
                        canister,
                        slot,
                    )
                delay(1000)
            }
        }
    }
    LaunchedEffect(owner, parent, editId, reload) {
        loading = true
        error = null
        try {
            editing =
                if (editId == null) null
                else account.api.posts(listOf(editId)).singleOrNull() ?: error("Post unavailable")
            require(
                editing == null ||
                    (editing!!.restriction == null &&
                        editing!!.authorId == state.user?.path("id")?.asLong())
            ) {
                "This post cannot be edited."
            }
            require(account.state.value.principal == owner) {
                "The account changed. Reopen the composer."
            }
            text = account.readDraft(parent, editing)
            realm = account.readDraftRealm(parent, editing)
            images = account.loadImages(parent, editId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message
        } finally {
            loading = false
        }
    }
    val editor: @Composable () -> Unit = {
        LazyColumn(
            modifier =
                Modifier.fillMaxWidth()
                    .then(if (inline) Modifier.heightIn(max = 400.dp) else Modifier),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (loading) item { CircularProgressIndicator() }
            error?.let {
                item {
                    Text(it, color = MaterialTheme.colorScheme.error)
                    TextButton(
                        onClick = { reload++ },
                        enabled = !loading && !state.busy && !importing,
                    ) {
                        Text("Retry")
                    }
                    if (
                        editId == null ||
                            (editing != null &&
                                editing?.restriction == null &&
                                editing?.authorId == state.user?.path("id")?.asLong())
                    ) {
                        TextButton(
                            onClick = {
                                importing = true
                                scope.launch {
                                    try {
                                        account.discardDraft(parent, editId)
                                        reload++
                                    } catch (e: CancellationException) {
                                        throw e
                                    } catch (e: Exception) {
                                        error = e.message
                                    } finally {
                                        importing = false
                                    }
                                }
                            },
                            enabled =
                                !loading &&
                                    !state.busy &&
                                    !importing &&
                                    !state.postOutcomeUnknown &&
                                    !videoUploading,
                        ) {
                            Text("Discard saved draft")
                        }
                    }
                }
            }
            item {
                TextButton(onClick = { preview = !preview }, enabled = !loading) {
                    Text(if (preview) "Write" else "Preview")
                }
            }
            item {
                if (preview) Text(remember(text) { org.taggr.android.ui.markdownText(text) })
                else
                    key(owner, parent, editId) {
                        MarkdownEditor(
                            text,
                            {
                                text = it
                                account.saveDraft(parent, it, realm, editId)
                            },
                            label = if (inline) "Reply here..." else "Write your post",
                            enabled = !state.busy && !importing && !loading && error == null,
                            selectionChanged = { imageSelection = it },
                            selectionRequest = imageSelectionRequest,
                            consumeSelectionRequest = { imageSelectionRequest = null },
                        )
                    }
            }
            if (parent == null && editing?.parent == null)
                item {
                    OutlinedTextField(
                        realm,
                        {
                            realm = it
                            account.saveDraft(parent, text, it, editId)
                        },
                        label = { Text("Realm (optional)") },
                        singleLine = true,
                        enabled = !state.busy && !importing && !loading && error == null,
                    )
                }
            item {
                TextButton(
                    onClick = {
                        imageTicket =
                            imageInsertionTicket(
                                imageScope,
                                text,
                                imageSelection?.min ?: text.length,
                            )
                        picker.launch(
                            PickVisualMediaRequest(
                                ActivityResultContracts.PickVisualMedia.ImageOnly
                            )
                        )
                    },
                    enabled =
                        !state.busy &&
                            !importing &&
                            !loading &&
                            error == null &&
                            images.size < DraftImages.MAX_COUNT,
                ) {
                    Text("Attach images")
                }
                TextButton(
                    onClick = { youtube = true },
                    enabled =
                        state.principal != null &&
                            state.user != null &&
                            !state.busy &&
                            !state.postOutcomeUnknown &&
                            !importing &&
                            !loading &&
                            error == null,
                ) {
                    Text("Upload video to YouTube")
                }
            }
            items(images, key = { it.id }) { image ->
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    val bitmap =
                        remember(image.id) {
                            val options =
                                android.graphics.BitmapFactory.Options().apply {
                                    inSampleSize =
                                        (maxOf(image.width, image.height) / 160)
                                            .coerceAtLeast(1)
                                            .takeHighestOneBit()
                                }
                            android.graphics.BitmapFactory.decodeByteArray(
                                image.bytes,
                                0,
                                image.bytes.size,
                                options,
                            )
                        }
                    DisposableEffect(bitmap) { onDispose { bitmap?.recycle() } }
                    bitmap?.let {
                        androidx.compose.foundation.Image(
                            it.asImageBitmap(),
                            "Attached image",
                            Modifier.size(64.dp),
                        )
                    }
                    TextButton(
                        onClick = {
                            importing = true
                            scope.launch {
                                try {
                                    val remaining = images.filter { it.id != image.id }
                                    account.saveImages(parent, editId, remaining)
                                    text = text.replace(image.markdown, "")
                                    images = remaining
                                    account.saveDraft(parent, text, realm, editId)
                                    attachmentError = null
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Exception) {
                                    attachmentError = e.message
                                } finally {
                                    importing = false
                                }
                            }
                        },
                        enabled = !state.busy && !importing,
                    ) {
                        Text("Remove")
                    }
                }
            }
            attachmentError?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
            if (importing) item { CircularProgressIndicator() }
            state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
            if (state.postOutcomeUnknown)
                item {
                    Text(
                        if (parent == null)
                            "Check your profile before sending again. Your draft is kept."
                        else "Check the conversation before sending again. Your draft is kept."
                    )
                    TextButton(
                        onClick = { account.recoverPost(completed) },
                        enabled = !state.busy,
                    ) {
                        Text("Check post result")
                    }
                }
            if (state.busy) item { CircularProgressIndicator() }
            if (videoUploading)
                item {
                    Text(
                        "A video is uploading for this draft. Wait for it to finish or pause the upload before posting.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
        }
    }
    val submit: @Composable () -> Unit = {
        PostSubmitAction(
            submit = {
                if (account.state.value.principal != owner) {
                    attachmentError = "The account changed. Reopen the composer."
                    return@PostSubmitAction
                }
                account.post(
                    text,
                    parent,
                    realm.takeIf { parent == null && editing?.parent == null },
                    completed,
                    editing,
                    images,
                )
            },
            videoUploading = videoUploading,
            label = if (inline) "Submit" else if (editId == null) "Post" else "Save",
            enabled =
                text.isNotBlank() &&
                    !state.busy &&
                    !importing &&
                    !state.postOutcomeUnknown &&
                    !videoChecking &&
                    !loading &&
                    error == null,
        )
    }
    val cancel: @Composable () -> Unit = {
        TextButton(onClick = onDismiss, enabled = !state.busy && !importing) { Text("Cancel") }
    }
    if (inline) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            editor()
            Row(
                Modifier.fillMaxWidth().bringIntoViewRequester(submitArea).padding(bottom = 8.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                cancel()
                submit()
            }
        }
    } else {
        AlertDialog(
            onDismissRequest = { if (!state.busy && !importing) onDismiss() },
            title = {
                Text(
                    if (editId != null) "Edit post" else if (parent == null) "New post" else "Reply"
                )
            },
            text = editor,
            confirmButton = submit,
            dismissButton = cancel,
        )
    }
}

@Composable
internal fun PostSubmitAction(
    label: String,
    enabled: Boolean,
    videoUploading: Boolean,
    submit: () -> Unit,
) {
    TextButton(onClick = submit, enabled = enabled && !videoUploading) { Text(label) }
}

@Composable
private fun RealmsScreen(account: AccountViewModel, openPost: (Long) -> Unit) {
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val api = account.api
    val identity by account.state.collectAsStateWithLifecycle()
    var controllerProfile by rememberSaveable(identity.principal) { mutableStateOf<String?>(null) }
    var creating by rememberSaveable(identity.principal) { mutableStateOf(false) }
    if (creating)
        RealmCreationEditor(
            account,
            { creating = false },
            { name ->
                selected = name
                creating = false
            },
        )
    if (selected != null) {
        RealmProfileRoute(
            account,
            selected!!,
            controllerProfile,
            { selected = null },
            { controllerProfile = null },
            { id ->
                controllerProfile = null
                selected = null
                openPost(id)
            },
            { controllerProfile = it },
        )
        return
    }
    var realms by remember { mutableStateOf<List<JsonNode>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var loading by remember { mutableStateOf(true) }
    LaunchedEffect(revision) {
        loading = true
        error = null
        try {
            realms =
                api.jsonQuery(
                        "all_realms",
                        listOf(org.taggr.android.data.TaggrRuntime.domain, "popularity", 0),
                    )
                    .toList()
                    .filter { !it[1].path("adult_content").asBoolean() }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message
        } finally {
            loading = false
        }
    }
    LazyColumn(
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Text(
                "Realms",
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold,
            )
        }
        item { TextButton(onClick = { revision++ }, enabled = !loading) { Text("Refresh") } }
        if (identity.user != null) {
            item {
                TextButton(
                    onClick = {
                        account.resetRealmCreationResult()
                        account.dismissMessage()
                        creating = true
                    },
                    enabled = !identity.busy,
                ) {
                    Text("Create Realm")
                }
            }
            val managed = identity.user?.path("controlled_realms")?.map { it.asText() }.orEmpty()
            if (managed.isNotEmpty())
                item {
                    Column {
                        Text("Your managed realms", style = MaterialTheme.typography.titleMedium)
                        for (name in managed) TextButton(onClick = { selected = name }) {
                            Text("/$name")
                        }
                    }
                }
        }
        if (loading) item { CircularProgressIndicator() }
        error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        items(realms, key = { it[0].asText() }) { row ->
            Surface(
                onClick = { selected = row[0].asText() },
                modifier = Modifier.testTag("realm-list-${row[0].asText()}"),
                color = MaterialTheme.colorScheme.surface,
                shape = MaterialTheme.shapes.medium,
            ) {
                Column(
                    Modifier.fillMaxWidth().padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        "/${row[0].asText()}",
                        color = MaterialTheme.colorScheme.secondary,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(row[1].path("description").asText(), maxLines = 4)
                    Text(
                        "${row[1].path("num_members").asText("0")} members",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
}

@Composable
private fun SearchScreen(
    api: TaggrApi,
    term: String,
    changeTerm: (String) -> Unit,
    openPost: (Long) -> Unit,
    back: () -> Unit,
    openProfile: (String) -> Unit,
    openRealm: (String) -> Unit,
    openTag: (String) -> Unit,
    openTransactions: (String) -> Unit,
) {
    var results by remember {
        mutableStateOf<List<org.taggr.android.data.SearchMatch>>(emptyList())
    }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    val transactionAccount =
        remember(term) {
            runCatching { org.taggr.android.data.TokenAccount.parse(term) }.getOrNull()
        }
    BackHandler(onBack = back)
    LaunchedEffect(term, revision) {
        results = emptyList()
        error = null
        if (term.length < 2 || transactionAccount != null) {
            loading = false
            return@LaunchedEffect
        }
        loading = true
        try {
            kotlinx.coroutines.delay(300)
            results = api.search(term)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message
        } finally {
            loading = false
        }
    }
    LazyColumn(
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { TextButton(onClick = back) { Text("Back") } }
        item { Text("Search", style = MaterialTheme.typography.headlineLarge) }
        item {
            Text(
                "@NAME users · /REALM realms · #TAG tags\nCombine @NAME /REALM WORD to search posts. Enter a Principal for transactions.",
                style = MaterialTheme.typography.bodySmall,
            )
        }
        item {
            OutlinedTextField(
                term,
                changeTerm,
                label = { Text("Search TAGGR") },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        transactionAccount?.let {
            item {
                TextButton(onClick = { openTransactions(it.address) }) { Text("View transactions") }
            }
        }
        if (loading) item { CircularProgressIndicator() }
        error?.let {
            item {
                Text(it, color = MaterialTheme.colorScheme.error)
                TextButton(onClick = { revision++ }) { Text("Retry") }
            }
        }
        items(results, key = { "${it.kind}/${it.target}" }) { match ->
            TextButton(
                modifier = Modifier.testTag("search-result-${match.kind}-${match.target}"),
                onClick = {
                    when (match.kind) {
                        "post" -> openPost(match.id)
                        "user" -> openProfile(match.target)
                        "realm" -> openRealm(match.target)
                        "tag" -> openTag(match.target)
                    }
                },
            ) {
                Column(Modifier.fillMaxWidth()) {
                    Text(match.title, fontWeight = FontWeight.Bold)
                    Text(match.snippet, maxLines = 4)
                }
            }
        }
        if (
            !loading &&
                error == null &&
                transactionAccount == null &&
                term.length >= 2 &&
                results.isEmpty()
        )
            item { Text("No results.") }
    }
}
