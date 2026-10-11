package org.taggr.android

import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.taggr.android.data.PostPage
import org.taggr.android.data.TaggrPost
import org.taggr.android.ui.postImageUrls

data class AccountPhoto(
    val postId: Long,
    val timestampMillis: Long,
    val url: String,
    val caption: String,
    val ordinal: Int,
    val source: TaggrPost? = null,
) {
    val id
        get() = "$postId/$url"
}

data class PhotoYear(val year: Int, val photos: List<AccountPhoto>)

internal fun photoYears(
    photos: List<AccountPhoto>,
    zone: ZoneId = ZoneId.systemDefault(),
): List<PhotoYear> =
    photos
        .groupBy { Instant.ofEpochMilli(it.timestampMillis).atZone(zone).year }
        .map { (year, rows) ->
            PhotoYear(
                year,
                rows.sortedWith(
                    compareByDescending<AccountPhoto> { it.timestampMillis }
                        .thenByDescending { it.postId }
                        .thenBy { it.ordinal }
                ),
            )
        }
        .sortedByDescending { it.year }

internal fun photosFrom(posts: List<TaggrPost>, viewerId: Long? = null): List<AccountPhoto> =
    posts
        .filter { it.restriction == null && !it.hiddenForViewer(viewerId) }
        .flatMap { post ->
            postImageUrls(post, post.body).mapIndexed { index, url ->
                AccountPhoto(post.id, post.timestampMillis, url, post.body, index, post)
            }
        }
        .distinctBy { it.id }

data class PhotoPageState(
    val photos: List<AccountPhoto> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    val canLoadMore: Boolean = true,
)

/** Keeps photo metadata only; scans image-free pages and retries the exact failed page/anchor. */
internal class PhotoPager(
    private val scope: CoroutineScope,
    private val viewerId: Long? = null,
    private val loadPage: suspend (Int, Long) -> PostPage,
) : AutoCloseable {
    private val mutable = MutableStateFlow(PhotoPageState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    private var page = 0
    private var anchor = 0L
    private var generation = 0
    private var closed = false

    fun refresh() {
        if (closed) return
        generation++
        job?.cancel()
        page = 0
        anchor = 0
        mutable.value = PhotoPageState()
        loadMore()
    }

    fun loadMore() {
        if (closed || mutable.value.loading || !mutable.value.canLoadMore) return
        val version = generation
        val previousIDs = mutable.value.photos.map { it.id }.toSet()
        mutable.value = mutable.value.copy(loading = true, error = null)
        job = scope.launch {
            try {
                while (!closed && version == generation) {
                    val result = loadPage(page, anchor)
                    if (closed || version != generation) return@launch
                    if (page == 0) anchor = result.anchor
                    page++
                    val returnedPosts = result.posts.map { it.id }.toSet()
                    val incoming = photosFrom(result.posts, viewerId)
                    val photos =
                        (mutable.value.photos.filterNot { it.postId in returnedPosts } + incoming)
                            .distinctBy { it.id }
                    mutable.value =
                        PhotoPageState(photos, loading = true, canLoadMore = result.hasMore)
                    if (!result.hasMore || incoming.any { it.id !in previousIDs }) break
                    yield()
                }
            } catch (_: TimeoutCancellationException) {
                if (!closed && version == generation)
                    mutable.value =
                        mutable.value.copy(error = "Loading photos timed out. Try again.")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!closed && version == generation)
                    mutable.value =
                        mutable.value.copy(error = e.message ?: "Couldn't load photos. Try again.")
            } finally {
                if (!closed && version == generation)
                    mutable.value = mutable.value.copy(loading = false)
            }
        }
    }

    override fun close() {
        closed = true
        generation++
        job?.cancel()
    }
}
