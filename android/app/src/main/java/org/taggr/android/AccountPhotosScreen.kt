package org.taggr.android

import android.content.Intent
import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.taggr.android.data.PostPage
import org.taggr.android.ui.ImageLoader
import org.taggr.android.ui.markdownText

@Composable
internal fun AccountPhotosScreen(
    account: AccountViewModel,
    userId: Long,
    name: String,
    back: () -> Unit,
    openPost: (Long) -> Unit,
) {
    val identity by account.state.collectAsStateWithLifecycle()
    val allowed = account.safety.allowedUser(userId)
    val scope = rememberCoroutineScope()
    val viewerId = identity.user?.path("id")?.asLong(-1)
    val pager =
        remember(userId, identity.principal, allowed, viewerId) {
            PhotoPager(scope, viewerId) { page, anchor ->
                if (account.safety.allowedUser(userId))
                    account.api.userPostPage(userId, page, anchor)
                else PostPage(emptyList(), 0, false)
            }
        }
    DisposableEffect(pager) { onDispose { pager.close() } }
    LaunchedEffect(pager) { pager.refresh() }
    val state by pager.state.collectAsStateWithLifecycle()
    val photos =
        if (allowed)
            state.photos.filter {
                it.source?.let { post ->
                    account.safety.allowed(post) &&
                        !post.hiddenForViewer(identity.user?.path("id")?.asLong(-1))
                } != false
            }
        else emptyList()
    PhotoLibraryContent(
        name,
        state.copy(photos = photos),
        back,
        pager::refresh,
        pager::loadMore,
        openPost,
    )
}

@Composable
internal fun PhotoLibraryContent(
    name: String,
    state: PhotoPageState,
    back: () -> Unit,
    refresh: () -> Unit,
    more: () -> Unit,
    openPost: (Long) -> Unit,
    image: @Composable (AccountPhoto, Modifier, ContentScale) -> Unit = { photo, modifier, scale ->
        PhotoImage(photo, modifier, scale)
    },
    viewerImage: @Composable (AccountPhoto, Modifier, (Boolean) -> Unit, () -> Unit) -> Unit =
        { photo, modifier, zoom, dismiss ->
            PhotoImage(photo, modifier, ContentScale.Fit, zoom, dismiss)
        },
) {
    var selected by rememberSaveable(name) { mutableStateOf<String?>(null) }
    val groups = remember(state.photos) { photoYears(state.photos) }
    val ordered = remember(groups) { groups.flatMap { it.photos } }
    BackHandler(onBack = back)
    LazyVerticalGrid(
        GridCells.Fixed(3),
        Modifier.fillMaxSize().testTag("photo-library"),
        contentPadding = PaddingValues(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = back) { Text("Profile") }
                TextButton(onClick = refresh, enabled = !state.loading) { Text("Refresh photos") }
            }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            Text(
                "$name's Photos",
                Modifier.padding(12.dp),
                style = MaterialTheme.typography.headlineMedium,
            )
        }
        for (group in groups) {
            item(key = "year-${group.year}", span = { GridItemSpan(maxLineSpan) }) {
                Text(
                    group.year.toString(),
                    Modifier.padding(top = 18.dp, bottom = 8.dp, start = 10.dp),
                    style = MaterialTheme.typography.titleLarge,
                )
            }
            items(group.photos, key = { it.id }) { photo ->
                image(
                    photo,
                    Modifier.fillMaxWidth()
                        .aspectRatio(1f)
                        .testTag("photo-${photo.postId}-${photo.ordinal}")
                        .clickable(onClickLabel = "Open image from post ${photo.postId}") {
                            selected = photo.id
                        },
                    ContentScale.Crop,
                )
            }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (state.loading) CircularProgressIndicator()
                state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (!state.loading && state.canLoadMore)
                    TextButton(onClick = more) {
                        Text(if (state.error == null) "Load more photos" else "Retry photos")
                    }
                if (!state.loading && !state.canLoadMore && ordered.isEmpty())
                    Text("No posted images. Images attached to posts will appear here.")
                if (!state.loading && !state.canLoadMore && ordered.isNotEmpty())
                    Text("You've reached the end.")
            }
        }
    }
    val index = ordered.indexOfFirst { it.id == selected }
    if (index >= 0)
        PhotoCollectionDialog(ordered, index, { selected = null }, openPost, viewerImage)
}

@Composable
internal fun PhotoImage(
    photo: AccountPhoto,
    modifier: Modifier,
    scale: ContentScale,
    zoomChanged: ((Boolean) -> Unit)? = null,
    backgroundTap: () -> Unit = {},
) {
    var bitmap by remember(photo.id) { mutableStateOf<Bitmap?>(null) }
    var error by remember(photo.id) { mutableStateOf<String?>(null) }
    var revision by remember(photo.id) { mutableIntStateOf(0) }
    LaunchedEffect(photo.id, revision) {
        error = null
        try {
            bitmap = ImageLoader.load(photo.url)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            error = "Image unavailable"
        }
    }
    Box(modifier, contentAlignment = androidx.compose.ui.Alignment.Center) {
        bitmap?.let {
            if (zoomChanged != null)
                ZoomablePhoto(
                    it,
                    "Image from post ${photo.postId}",
                    Modifier.fillMaxSize(),
                    zoomChanged,
                    backgroundTap,
                )
            else
                Image(
                    it.asImageBitmap(),
                    "Image from post ${photo.postId}",
                    Modifier.fillMaxSize(),
                    contentScale = scale,
                )
        }
            ?: if (error != null) TextButton(onClick = { revision++ }) { Text("Retry image") }
            else CircularProgressIndicator()
    }
}

@Composable
private fun PhotoCollectionDialog(
    photos: List<AccountPhoto>,
    initialIndex: Int,
    close: () -> Unit,
    openPost: (Long) -> Unit,
    image: @Composable (AccountPhoto, Modifier, (Boolean) -> Unit, () -> Unit) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var sharing by remember { mutableStateOf(false) }
    val errors = remember { mutableStateMapOf<String, String>() }
    ImagePagerDialog(
        photos,
        initialIndex,
        close,
        image,
        trailing = { photo ->
            TextButton(
                onClick = {
                    scope.launch {
                        sharing = true
                        errors.remove(photo.id)
                        try {
                            context.startActivity(
                                Intent.createChooser(
                                    photoShareIntent(context, photo),
                                    "Share image",
                                )
                            )
                        } catch (e: CancellationException) {
                            throw e
                        } catch (_: Exception) {
                            errors[photo.id] = "The image could not be shared. Try again."
                        } finally {
                            sharing = false
                        }
                    }
                },
                enabled = !sharing,
            ) {
                Text(if (sharing) "Preparing image" else "Share image")
            }
        },
        footer = { photo ->
            errors[photo.id]?.let { Text(it, Modifier.padding(12.dp), color = Color.White) }
            Text(
                java.time.Instant.ofEpochMilli(photo.timestampMillis)
                    .atZone(java.time.ZoneId.systemDefault())
                    .toLocalDate()
                    .toString(),
                Modifier.padding(horizontal = 16.dp),
                color = Color.White,
            )
            Text("Post #${photo.postId}", Modifier.padding(horizontal = 16.dp), color = Color.White)
            Text(
                remember(photo.caption) { markdownText(photo.caption) },
                Modifier.padding(16.dp),
                maxLines = 3,
                color = Color.White,
            )
            TextButton(
                onClick = {
                    close()
                    openPost(photo.postId)
                }
            ) {
                Text("Open conversation")
            }
        },
    )
}
