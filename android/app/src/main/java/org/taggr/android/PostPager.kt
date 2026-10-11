package org.taggr.android

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.taggr.android.data.PostPage
import org.taggr.android.data.TaggrPost

data class PagedPostsState(
    val posts: List<TaggrPost> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    val canLoadMore: Boolean = true,
)

/** Screen-owned paging; a failed request retries the same page and snapshot anchor. */
internal class PostPager(
    private val scope: CoroutineScope,
    private val loadPage: suspend (Int, Long) -> PostPage,
) : AutoCloseable {
    private val mutable = MutableStateFlow(PagedPostsState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    private var page = 0
    private var offset = 0L
    private var generation = 0
    private var closed = false

    fun refresh() {
        if (closed) return
        generation++
        job?.cancel()
        page = 0
        offset = 0
        mutable.value = PagedPostsState()
        loadMore()
    }

    fun loadMore() {
        val before = mutable.value
        if (closed || before.loading || !before.canLoadMore) return
        val version = generation
        mutable.value = before.copy(loading = true, error = null)
        job = scope.launch {
            try {
                val result = loadPage(page, offset)
                if (closed || version != generation) return@launch
                if (page == 0) offset = result.anchor
                page++
                mutable.value =
                    PagedPostsState(
                        (before.posts + result.posts).distinctBy { it.id },
                        canLoadMore = result.hasMore,
                    )
            } catch (_: TimeoutCancellationException) {
                if (!closed && version == generation)
                    mutable.value = before.copy(error = "Loading timed out. Try again.")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!closed && version == generation)
                    mutable.value =
                        before.copy(error = e.message ?: "Couldn't load posts. Try again.")
            }
        }
    }

    override fun close() {
        closed = true
        generation++
        job?.cancel()
    }
}
