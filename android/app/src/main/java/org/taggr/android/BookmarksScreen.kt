package org.taggr.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.taggr.android.data.*
import org.taggr.android.ui.PostContent

@Composable
internal fun BookmarksScreen(
    account: AccountViewModel,
    back: () -> Unit,
    openPost: (Long) -> Unit,
) {
    val state by account.state.collectAsStateWithLifecycle()
    val decoded =
        remember(state.user) { runCatching { BookmarkIDs.decode(state.user?.get("bookmarks")) } }
    val ids = decoded.getOrDefault(emptyList())
    var revision by rememberSaveable(state.principal) { mutableIntStateOf(0) }
    val pager =
        rememberPostPager(account, state.principal, ids, revision) { page, _ ->
            require(state.principal != null && state.user != null) {
                "Sign in to view your bookmarks."
            }
            val selected = BookmarkIDs.page(ids, page)
            val rows = account.api.posts(selected).associateBy { it.id }
            PostPage(selected.mapNotNull { rows[it] }, 0, BookmarkIDs.hasMore(ids, page))
        }
    val paging by pager.state.collectAsStateWithLifecycle()
    LaunchedEffect(state.principal) { if (state.principal != null) account.reload() }
    LaunchedEffect(pager, state.user != null) {
        if (state.user != null && decoded.isSuccess) pager.refresh()
    }
    BackHandler(onBack = back)
    BookmarksContent(
        state.principal != null && state.user != null,
        paging.copy(posts = paging.posts.filter { account.safety.allowed(it) }),
        state.busy,
        listError = decoded.exceptionOrNull()?.message,
        back = back,
        refresh = {
            revision++
            account.reload()
        },
        loadMore = pager::loadMore,
        openPost = openPost,
        remove = { id -> state.principal?.let { account.setBookmark(id, false, it) } },
    )
}

@Composable
internal fun BookmarksContent(
    signedIn: Boolean,
    paging: PagedPostsState,
    busy: Boolean,
    listError: String? = null,
    back: () -> Unit,
    refresh: () -> Unit,
    loadMore: () -> Unit,
    openPost: (Long) -> Unit,
    remove: (Long) -> Unit,
) {
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { TextButton(onClick = back) { Text("Back") } }
        item { Text("Bookmarks", style = MaterialTheme.typography.headlineLarge) }
        if (!signedIn) item { Text("Sign in to view your bookmarks.") }
        else {
            item {
                TextButton(onClick = refresh, enabled = !busy && !paging.loading) {
                    Text("Refresh bookmarks")
                }
            }
            if (listError != null) item { Text(listError, color = MaterialTheme.colorScheme.error) }
            items(paging.posts, key = { it.id }) { post ->
                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = MaterialTheme.shapes.medium,
                ) {
                    Column(
                        Modifier.fillMaxWidth().padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            post.author,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.secondary,
                        )
                        if (post.restriction == null) PostContent(post, false)
                        else Text(post.restriction)
                        TextButton(onClick = { openPost(post.id) }) { Text("Open conversation") }
                        TextButton(onClick = { remove(post.id) }, enabled = !busy) {
                            Text("Remove bookmark")
                        }
                    }
                }
            }
            if (listError == null) item { PagedPostsFooter(paging, loadMore) }
        }
    }
}
