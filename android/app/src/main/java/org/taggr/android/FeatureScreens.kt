package org.taggr.android

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fasterxml.jackson.databind.JsonNode
import kotlinx.coroutines.CancellationException
import org.taggr.android.data.TaggrRuntime
import org.taggr.android.ui.PostContent
import org.taggr.android.ui.markdownText

@Composable
internal fun TagPostsScreen(
    account: AccountViewModel,
    tag: List<String>,
    back: () -> Unit,
    openPost: (Long) -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val pager =
        rememberPostPager(account, tag, state.principal) { page, offset ->
            require(tag.none { it.equals("nsfw", true) }) {
                "Adult content is unavailable in this app."
            }
            account.api.tagPostPage(tag, page, offset)
        }
    val paging by pager.state.collectAsStateWithLifecycle()
    val posts = paging.posts
    BackHandler(onBack = back)
    LaunchedEffect(pager) { pager.refresh() }
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { TextButton(onClick = back) { Text("Back") } }
        item {
            Text(
                tag.joinToString(" + #", prefix = "#"),
                style = MaterialTheme.typography.headlineLarge,
            )
        }
        items(posts.filter { account.safety.allowed(it) }, key = { it.id }) { post ->
            Column {
                Text(
                    post.author,
                    color = MaterialTheme.colorScheme.secondary,
                    fontWeight = FontWeight.Bold,
                )
                if (post.restriction == null) PostContent(post, false) else Text(post.restriction)
                TextButton(onClick = { openPost(post.id) }) { Text("Open conversation") }
                HorizontalDivider()
            }
        }
        item { PagedPostsFooter(paging, pager::loadMore) }
    }
}

@Composable
internal fun SafetyGate(account: AccountViewModel) {
    var agrees by rememberSaveable { mutableStateOf(false) }
    LazyColumn(
        contentPadding = PaddingValues(24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        item {
            Text(
                "Terms & safety",
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold,
            )
        }
        item {
            Text(
                "Objectionable content and abusive behavior are not tolerated. Do not post pornography, exploitation, threats, hateful abuse, harassment, or illegal material. NSFW posts are unavailable in this app."
            )
        }
        item {
            Text(
                "Use Report on a post or profile to send concerns. No tokens or credits are required. Block immediately hides a user's content."
            )
        }
        item { org.taggr.android.ui.PolicyLinks() }
        item {
            Row(Modifier.clickable { agrees = !agrees }) {
                Checkbox(agrees, { agrees = it })
                Text("I agree to the Terms of Use and safety rules", Modifier.padding(top = 12.dp))
            }
        }
        item {
            Button(onClick = account::acceptTerms, enabled = agrees) { Text("Agree and continue") }
        }
    }
}

@Composable
internal fun ProfileScreen(
    account: AccountViewModel,
    handle: String,
    back: () -> Unit,
    openPost: (Long) -> Unit,
    initialPhotos: Boolean = false,
) {
    var profilePath by rememberSaveable(handle) { mutableStateOf(listOf(handle)) }
    val currentHandle = profilePath.last()
    val returnBack: () -> Unit = {
        if (profilePath.size > 1) profilePath = profilePath.dropLast(1) else back()
    }
    var realmList by remember(currentHandle) { mutableStateOf<ProfileStatistic?>(null) }
    val openRealm = LocalRealmOpen.current
    var tokenDecimals by remember(account.api) { mutableStateOf<Int?>(null) }
    LaunchedEffect(account.api) {
        try {
            val value = account.api.jsonQuery("config").get("token_decimals")
            if (
                value != null &&
                    value.isIntegralNumber &&
                    value.canConvertToInt() &&
                    value.asInt() in 0..255
            )
                tokenDecimals = value.asInt()
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (_: Exception) {
            /* Counts remain available without a balance denomination. */
        }
    }
    var userList by remember(currentHandle) { mutableStateOf<ProfileUserList?>(null) }
    var photos by
        rememberSaveable(currentHandle, initialPhotos) {
            mutableStateOf(initialPhotos && profilePath.size == 1)
        }
    val state by account.state.collectAsStateWithLifecycle()
    val changed = LocalProfileChanged.current
    var sendCredits by remember(currentHandle, state.principal) { mutableStateOf(false) }
    var revision by remember(currentHandle) { mutableIntStateOf(0) }
    var user by
        remember(currentHandle, state.principal, revision) { mutableStateOf<JsonNode?>(null) }
    var error by
        remember(currentHandle, state.principal, revision) { mutableStateOf<String?>(null) }
    var loading by remember(currentHandle, state.principal, revision) { mutableStateOf(true) }
    val userId = user?.path("id")?.asLong()
    val pager =
        rememberPostPager(account, currentHandle, state.principal, revision, userId) { page, offset
            ->
            val id = userId ?: error("User unavailable")
            if (account.safety.allowedUser(id)) account.api.userPostPage(id, page, offset)
            else org.taggr.android.data.PostPage(emptyList(), 0, false)
        }
    val paging by pager.state.collectAsStateWithLifecycle()
    LaunchedEffect(pager, userId, photos) { if (userId != null && !photos) pager.refresh() }
    BackHandler(onBack = returnBack)
    LaunchedEffect(currentHandle, revision, state.principal) {
        loading = true
        error = null
        try {
            val loaded =
                account.api.jsonQuery("user", listOf(TaggrRuntime.domain, listOf(currentHandle)))
            require(!loaded.isNull) { "User not found" }
            user = loaded
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message
        } finally {
            loading = false
        }
    }
    if (photos && userId != null) {
        AccountPhotosScreen(
            account,
            userId,
            user!!.path("name").asText(),
            { photos = false },
            openPost,
        )
        return
    }
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { TextButton(onClick = returnBack) { Text("Back") } }
        if (loading) item { CircularProgressIndicator() }
        error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        user?.let { loadedProfile ->
            val profile =
                state.user?.takeIf { it.path("id") == loadedProfile.path("id") } ?: loadedProfile
            item {
                Surface(
                    Modifier.fillMaxWidth(),
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.surface,
                ) {
                    Column(
                        Modifier.padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            profile.path("name").asText(),
                            modifier = Modifier.testTag("profile-name"),
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Black,
                        )
                        org.taggr.android.ui.ProfileUserBadges(account, profile)
                        val about =
                            if (account.safety.allowedUser(profile.path("id").asLong()))
                                profile.path("about").asText()
                            else "This user's content is hidden."
                        if (about.isNotEmpty())
                            androidx.compose.foundation.text.selection.SelectionContainer {
                                Text(remember(about) { markdownText(about) })
                            }
                    }
                }
            }
            item {
                Row {
                    TextButton(onClick = { photos = false }, enabled = photos) { Text("Posts") }
                    TextButton(onClick = { photos = true }, enabled = !photos) { Text("Photos") }
                }
            }
            item {
                val statistics =
                    remember(profile, tokenDecimals) { profileStatistics(profile, tokenDecimals) }
                ProfileStatisticsGrid(statistics, { userList = it }, { realmList = it })
            }
            item {
                ProfileDetails(profile, account.safety.allowedUser(profile.path("id").asLong()))
            }
            item {
                FlowRow {
                    if (
                        state.user != null &&
                            state.user?.path("id")?.asLong() != profile.path("id").asLong()
                    ) {
                        val following =
                            state.user?.path("followees")?.any {
                                it.asLong() == profile.path("id").asLong()
                            } == true
                        TextButton(
                            onClick = {
                                state.principal?.let { owner ->
                                    account.setUserFollowing(
                                        profile.path("id").asLong(),
                                        !following,
                                        owner,
                                    ) {
                                        revision++
                                        changed()
                                    }
                                }
                            },
                            enabled = !state.busy,
                        ) {
                            Text(if (following) "Unfollow" else "Follow")
                        }
                    }
                    ProfileMuteControl(
                        state.principal != null &&
                            state.user != null &&
                            state.user?.path("id") != profile.path("id"),
                        state.user?.path("filters")?.path("users")?.any {
                            it.asLong(-1) == profile.path("id").asLong()
                        } == true,
                        state.busy || state.restoring,
                        identity = profile.path("id").asLong() to state.principal,
                    ) { selected ->
                        state.principal?.let { owner ->
                            account.setUserMuted(profile.path("id").asLong(), selected, owner) {
                                revision++
                                changed()
                            }
                        }
                    }
                    org.taggr.android.ui.UserBlockControl(
                        target = profile.path("id").asLong(),
                        name = profile.path("name").asText(),
                        viewer = state.user?.path("id")?.asLong(-1),
                        scope = state.principal,
                        blocked = account.safety.blocked(profile.path("id").asLong()),
                        busy = state.busy || state.restoring,
                    ) { selected ->
                        account.blockUser(profile.path("id").asLong(), selected) {
                            revision++
                            changed()
                        }
                    }
                    if (
                        state.user != null &&
                            state.user?.path("id")?.asLong() != profile.path("id").asLong()
                    )
                        TextButton(onClick = { sendCredits = true }, enabled = !state.busy) {
                            Text("Send credits")
                        }
                    if (state.user?.path("id")?.asLong(-1) != profile.path("id").asLong())
                        org.taggr.android.ui.ReportAction(
                            account,
                            profile.path("id").asLong(),
                            null,
                        )
                }
            }
        }
        items(paging.posts.filter { account.safety.allowed(it) }, key = { it.id }) { post ->
            Column(
                Modifier.fillMaxWidth().clickable { openPost(post.id) }.padding(vertical = 12.dp)
            ) {
                if (post.restriction == null) PostContent(post, false) else Text(post.restriction)
                HorizontalDivider()
            }
        }
        if (user != null) item { PagedPostsFooter(paging, pager::loadMore) }
        if (error != null && !loading)
            item { TextButton(onClick = { revision++ }) { Text("Retry") } }
    }
    realmList?.let { selection ->
        ProfileRealmsSheet(selection, { realmList = null }) { name ->
            realmList = null
            openRealm?.invoke(name)
        }
    }
    if (sendCredits && state.user != null)
        user?.let { profile ->
            ProfileCreditTransfer(
                account,
                profile.path("id").asLong(),
                profile.path("name").asText(),
            ) {
                sendCredits = false
                revision++
            }
        }
    userList?.let { kind ->
        user?.let { profile ->
            ProfileUsersSheet(account, profile, kind, { userList = null }) { id ->
                userList = null
                profilePath = profilePath + id.toString()
            }
        }
    }
}

@Composable
internal fun RealmProfileRoute(
    account: AccountViewModel,
    name: String,
    profile: String?,
    back: () -> Unit,
    backProfile: () -> Unit,
    openPost: (Long) -> Unit,
    openProfile: (String) -> Unit,
) {
    key(name) {
        Box(Modifier.fillMaxSize()) {
            Box(
                Modifier.fillMaxSize()
                    .then(
                        if (profile != null) Modifier.alpha(0f).clearAndSetSemantics {}
                        else Modifier
                    )
            ) {
                CompositionLocalProvider(
                    LocalPollProfile provides { id -> openProfile(id.toString()) },
                    org.taggr.android.ui.LocalVideoActive provides (profile == null),
                ) {
                    RealmScreen(
                        account,
                        name,
                        back,
                        openPost,
                        openProfile,
                        active = profile == null,
                    )
                }
            }
            if (profile != null)
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    ProfileScreen(account, profile, backProfile, openPost)
                }
        }
    }
}

@Composable
internal fun RealmScreen(
    account: AccountViewModel,
    name: String,
    back: () -> Unit,
    openPost: (Long) -> Unit,
    openProfile: ((String) -> Unit)? = null,
    active: Boolean = true,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val financial by account.financialState.collectAsStateWithLifecycle()
    var editing by
        remember(name, state.principal) {
            mutableStateOf<org.taggr.android.data.RealmEditContext?>(null)
        }
    var revision by remember(name) { mutableIntStateOf(0) }
    editing?.let { context ->
        RealmSettingsEditor(account, context, { editing = null }) {
            editing = null
            revision++
        }
    }
    var realm by remember(name, state.principal, revision) { mutableStateOf<JsonNode?>(null) }
    var error by remember(name, state.principal, revision) { mutableStateOf<String?>(null) }
    var loading by remember(name, state.principal, revision) { mutableStateOf(true) }
    val contentAvailable = realm != null && realm?.path("adult_content")?.asBoolean() != true
    val details =
        remember(realm) {
            realm?.let {
                runCatching { org.taggr.android.data.RealmDetails.decode(it) }.getOrNull()
            }
        }
    var controllerNames by
        remember(name, state.principal) { mutableStateOf<Map<ULong, String>>(emptyMap()) }
    LaunchedEffect(details?.controllers, state.principal) {
        controllerNames = emptyMap()
        val ids = details?.controllers.orEmpty()
        if (ids.isNotEmpty() && contentAvailable) {
            try {
                val rows =
                    account.api.jsonQuery(
                        "users_data",
                        listOf(ids.map { java.math.BigInteger(it.toString()) }),
                    )
                require(rows.isObject)
                controllerNames =
                    ids.mapNotNull { id ->
                            val label =
                                rows
                                    .path(id.toString())
                                    .takeIf {
                                        it.isTextual &&
                                            it.asText().isNotBlank() &&
                                            it.asText().length <= 256
                                    }
                                    ?.asText()
                            if (
                                label != null &&
                                    id <= Long.MAX_VALUE.toULong() &&
                                    account.safety.allowedUser(id.toLong())
                            )
                                id to label
                            else null
                        }
                        .toMap()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {}
        }
    }

    val pager =
        rememberPostPager(account, name, state.principal, revision, contentAvailable) { page, offset
            ->
            account.api.realmPostPage(name, page, offset)
        }
    val paging by pager.state.collectAsStateWithLifecycle()
    LaunchedEffect(pager, contentAvailable) { if (contentAvailable) pager.refresh() }
    BackHandler(enabled = active, onBack = back)
    LaunchedEffect(name, revision, state.principal, state.busy) {
        if (state.busy) return@LaunchedEffect
        loading = true
        error = null
        try {
            val loaded =
                account.api.jsonQuery("realms", listOf(listOf(name))).firstOrNull()
                    ?: error("Realm not found")
            realm = loaded
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            realm = null
            error = e.message
        } finally {
            loading = false
        }
    }
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { TextButton(onClick = back) { Text("Back") } }
        if (!contentAvailable)
            item {
                Text(
                    "/$name",
                    style = MaterialTheme.typography.headlineLarge,
                    fontWeight = FontWeight.Bold,
                )
            }
        if (loading) item { CircularProgressIndicator() }
        error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        state.notice?.let { item { Text(it) } }
        realm?.let { value ->
            if (
                state.user != null &&
                    value.path("controllers").any {
                        it.asLong(-1) == state.user?.path("id")?.asLong(-1)
                    }
            )
                item {
                    TextButton(
                        onClick = { account.prepareRealmEdit(name) { editing = it } },
                        enabled = !state.busy,
                    ) {
                        Text("Manage Realm")
                    }
                }
            if (contentAvailable) {
                item {
                    if (details != null)
                        RealmDetailsCard(name, details, controllerNames, openProfile)
                    else Text("Realm details are unavailable. Refresh to try again.")
                }
                item {
                    val context = LocalContext.current
                    TextButton(
                        onClick = {
                            val url =
                                "https://${TaggrRuntime.domain}/#/realm/${android.net.Uri.encode(name)}"
                            context.startActivity(
                                Intent.createChooser(
                                    Intent(Intent.ACTION_SEND)
                                        .setType("text/plain")
                                        .putExtra(Intent.EXTRA_TEXT, url),
                                    "Share Realm",
                                )
                            )
                        }
                    ) {
                        Text("Share Realm")
                    }
                }
            } else item { Text("Adult content is unavailable in this app.") }
            if (contentAvailable)
                item {
                    RealmMembershipControls(
                        signedIn = state.user != null,
                        joined =
                            state.user?.path("realms")?.any {
                                it.asText().equals(name, ignoreCase = true)
                            } == true,
                        busy = state.busy,
                        ready =
                            !financial.restoring && !financial.blocked && financial.pending == null,
                        pending = financial.pending?.method == "toggle_realm_membership",
                        blocked = financial.blocked,
                        change = { joined ->
                            account.setRealmMembership(
                                name,
                                joined,
                                if (joined) value.deepCopy() else null,
                            ) {
                                revision++
                            }
                        },
                        checkResult = account::checkFinancial,
                        name = name,
                        cleanupPenalty =
                            value
                                .path("cleanup_penalty")
                                .takeIf {
                                    it.isIntegralNumber &&
                                        it.bigIntegerValue().signum() >= 0 &&
                                        it.bigIntegerValue().bitLength() <= 64
                                }
                                ?.asText()
                                ?.toULongOrNull(),
                    )
                }
        }
        items(
            paging.posts.filter { contentAvailable && account.safety.allowed(it) },
            key = { it.id },
        ) { post ->
            Column(Modifier.padding(vertical = 12.dp)) {
                Text(
                    post.author,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.secondary,
                )
                if (post.restriction == null) PostContent(post, false) else Text(post.restriction)
                TextButton(onClick = { openPost(post.id) }) { Text("Open conversation") }
                HorizontalDivider()
            }
        }
        if (contentAvailable) {
            if (!paging.loading && paging.posts.isEmpty() && paging.error == null)
                item { Text("No posts") }
            item { PagedPostsFooter(paging, pager::loadMore) }
        }
        if (error != null && !loading)
            item { TextButton(onClick = { revision++ }) { Text("Retry") } }
    }
}

@Composable
internal fun rememberPostPager(
    vararg keys: Any?,
    load: suspend (Int, Long) -> org.taggr.android.data.PostPage,
): PostPager {
    val scope = rememberCoroutineScope()
    val pager = remember(*keys) { PostPager(scope, load) }
    DisposableEffect(pager) { onDispose { pager.close() } }
    return pager
}

@Composable
internal fun PagedPostsFooter(state: PagedPostsState, loadMore: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (state.loading) CircularProgressIndicator()
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (!state.loading && state.canLoadMore)
            TextButton(onClick = loadMore) {
                Text(if (state.error == null) "Load more" else "Retry")
            }
        if (!state.loading && state.error == null && !state.canLoadMore)
            Text(if (state.posts.isEmpty()) "No posts yet." else "You've reached the end.")
    }
}
