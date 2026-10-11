package org.taggr.android

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.taggr.android.data.FeedMode
import org.taggr.android.data.PostRepository
import org.taggr.android.data.TaggrApi
import org.taggr.android.data.TaggrPost

data class FeedState(
    val mode: FeedMode = FeedMode.HOT,
    val posts: List<TaggrPost> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    val canLoadMore: Boolean = true,
)

data class DetailState(
    val post: TaggrPost,
    val replies: List<TaggrPost> = emptyList(),
    val ancestors: List<TaggrPost> = emptyList(),
    val contextIncomplete: Boolean = false,
    val loading: Boolean = true,
    val error: String? = null,
)

data class PostRepliesState(
    val loading: Boolean = true,
    val posts: List<TaggrPost> = emptyList(),
    val error: String? = null,
)

internal data class ReplyFeedRow(val post: TaggrPost, val depth: Int)

// Iterative traversal keeps deep threads off the call stack and each post in one lazy row.
internal fun replyFeedRows(
    roots: List<TaggrPost>,
    replies: Map<Long, PostRepliesState>,
    hidden: Set<Long> = emptySet(),
    allowed: (TaggrPost) -> Boolean = { true },
): List<ReplyFeedRow> {
    val result = mutableListOf<ReplyFeedRow>()
    val seen = hidden.toMutableSet()
    val rootIDs = roots.mapTo(mutableSetOf()) { it.id }
    val pending = java.util.ArrayDeque<ReplyFeedRow>()
    roots.asReversed().forEach { pending.addLast(ReplyFeedRow(it, 0)) }
    while (pending.isNotEmpty()) {
        val row = pending.removeLast()
        if (!seen.add(row.post.id) || !allowed(row.post)) continue
        result.add(row)
        replies[row.post.id]?.posts?.asReversed()?.forEach {
            if (it.id !in rootIDs) pending.addLast(ReplyFeedRow(it, row.depth + 1))
        }
    }
    return result
}

class FeedViewModel(
    private val repository: PostRepository = TaggrApi(),
    private val ownsRepository: Boolean = true,
    private val savedState: SavedStateHandle? = null,
) : ViewModel() {
    private val mutableFeed = MutableStateFlow(FeedState())
    val feed = mutableFeed.asStateFlow()
    private val mutableDetail = MutableStateFlow<DetailState?>(null)
    val detail = mutableDetail.asStateFlow()
    private val mutableReplies = MutableStateFlow<Map<Long, PostRepliesState>>(emptyMap())
    val replies = mutableReplies.asStateFlow()
    private val replyJobs = mutableMapOf<Long, Job>()
    private var repliesGeneration = 0

    fun toggleReplies(post: TaggrPost) {
        if (post.id in mutableReplies.value) {
            val removed = mutableSetOf<Long>()
            val pending = java.util.ArrayDeque<Long>()
            pending.add(post.id)
            while (pending.isNotEmpty()) {
                val id = pending.removeLast()
                if (!removed.add(id)) continue
                mutableReplies.value[id]?.posts?.forEach { pending.add(it.id) }
            }
            removed.forEach { replyJobs.remove(it)?.cancel() }
            mutableReplies.value = mutableReplies.value - removed
        } else expandReplies(post)
    }

    fun expandReplies(post: TaggrPost, reloadParent: Boolean = false) {
        if (post.restriction != null || post.viewerBlocked) return
        if (
            !reloadParent &&
                post.id in mutableReplies.value &&
                mutableReplies.value[post.id]?.error == null
        )
            return
        replyJobs.remove(post.id)?.cancel()
        val generation = repliesGeneration
        val pending = PostRepliesState()
        mutableReplies.value = mutableReplies.value + (post.id to pending)
        val job =
            viewModelScope.launch(start = CoroutineStart.LAZY) {
                fun active() =
                    generation == repliesGeneration && mutableReplies.value[post.id] === pending
                try {
                    val parent =
                        if (reloadParent)
                            repository.posts(listOf(post.id)).firstOrNull { it.id == post.id }
                        else post
                    val children =
                        parent
                            ?.takeIf { it.restriction == null && !it.viewerBlocked }
                            ?.children
                            .orEmpty()
                    val loaded = if (children.isEmpty()) emptyList() else repository.posts(children)
                    if (active())
                        mutableReplies.value =
                            mutableReplies.value +
                                (post.id to
                                    PostRepliesState(
                                        loading = false,
                                        posts =
                                            loaded
                                                .filter {
                                                    it.id in children && it.parent == post.id
                                                }
                                                .distinctBy { it.id },
                                    ))
                } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
                    if (active())
                        mutableReplies.value =
                            mutableReplies.value +
                                (post.id to
                                    PostRepliesState(
                                        loading = false,
                                        error = "Loading timed out. Try again.",
                                    ))
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    if (active())
                        mutableReplies.value =
                            mutableReplies.value +
                                (post.id to
                                    PostRepliesState(
                                        loading = false,
                                        error = "Couldn't load replies. Try again.",
                                    ))
                } finally {
                    if (replyJobs[post.id] === coroutineContext[Job]) replyJobs.remove(post.id)
                }
            }
        replyJobs[post.id] = job
        job.start()
    }

    private fun clearReplies() {
        repliesGeneration++
        replyJobs.values.forEach { it.cancel() }
        replyJobs.clear()
        mutableReplies.value = emptyMap()
    }

    private var feedJob: Job? = null
    private var detailJob: Job? = null
    private var detailGeneration = 0
    private var page = 0
    private var offset = 0L

    init {
        refresh()
    }

    fun discardCachedContent() {
        savedState?.set<Long?>("taggr.focused-post", null)
        clearReplies()
        feedJob?.cancel()
        detailJob?.cancel()
        detailGeneration++
        mutableFeed.value = FeedState()
        mutableDetail.value = null
        page = 0
        offset = 0L
    }

    fun selectMode(mode: FeedMode) {
        if (mode == mutableFeed.value.mode) return
        mutableFeed.value = FeedState(mode = mode)
        refresh()
    }

    fun refresh() {
        clearReplies()
        feedJob?.cancel()
        page = 0
        offset = 0L
        load(reset = true)
    }

    fun loadMore() {
        if (mutableFeed.value.loading || !mutableFeed.value.canLoadMore) return
        load(reset = false)
    }

    private fun load(reset: Boolean) {
        val before = mutableFeed.value
        mutableFeed.value = before.copy(loading = true, error = null)
        feedJob = viewModelScope.launch {
            try {
                val result = repository.feedPage(before.mode, page, offset)
                val posts = result.posts
                if (reset) offset = result.anchor
                page += 1
                mutableFeed.value =
                    before.copy(
                        posts = (if (reset) posts else before.posts + posts).distinctBy { it.id },
                        loading = false,
                        canLoadMore = result.hasMore,
                    )
            } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
                mutableFeed.value =
                    before.copy(loading = false, error = "Loading timed out. Try again.")
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                mutableFeed.value =
                    before.copy(
                        loading = false,
                        error = "Couldn't load posts. Check your connection and try again.",
                    )
            }
        }
    }

    fun openPost(post: TaggrPost) {
        savedState?.set("taggr.focused-post", post.id)
        clearReplies()
        val version = ++detailGeneration
        detailJob?.cancel()
        mutableDetail.value = DetailState(post)
        detailJob = viewModelScope.launch {
            try {
                val chain = repository.thread(post.id)
                if (version != detailGeneration) return@launch
                val current = chain.lastOrNull()?.takeIf { it.id == post.id }
                if (current == null) {
                    mutableDetail.value =
                        DetailState(
                            post.copy(
                                body = "",
                                children = emptyList(),
                                restriction = "Post unavailable",
                            ),
                            loading = false,
                        )
                    return@launch
                }
                require(chain.map { it.id }.distinct().size == chain.size) {
                    "Invalid conversation"
                }
                val ancestors = chain.dropLast(1)
                val incomplete =
                    chain.first().parent != null ||
                        chain.zipWithNext().any { (parent, child) -> child.parent != parent.id }
                val ready =
                    DetailState(current, ancestors = ancestors, contextIncomplete = incomplete)
                mutableDetail.value = ready
                val replies =
                    if (current.restriction == null) repository.posts(current.children)
                    else emptyList()
                if (version == detailGeneration)
                    mutableDetail.value = ready.copy(replies = replies, loading = false)
            } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
                if (version == detailGeneration)
                    mutableDetail.value =
                        mutableDetail.value?.copy(
                            loading = false,
                            error = "Loading timed out. Try again.",
                        )
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (version == detailGeneration)
                    mutableDetail.value =
                        mutableDetail.value?.copy(
                            loading = false,
                            error = "Couldn't load this conversation. Try again.",
                        )
            }
        }
    }

    fun openPostById(id: Long) {
        savedState?.set("taggr.focused-post", id)
        val version = ++detailGeneration
        detailJob?.cancel()
        detailJob = viewModelScope.launch {
            try {
                val post =
                    repository.posts(listOf(id)).firstOrNull { it.id == id }
                        ?: error("Post not found")
                if (version == detailGeneration) openPost(post)
            } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
                if (version == detailGeneration)
                    mutableFeed.value =
                        mutableFeed.value.copy(error = "Loading timed out. Try again.")
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (version == detailGeneration)
                    mutableFeed.value = mutableFeed.value.copy(error = "Couldn't load this post.")
            }
        }
    }

    fun restoreFocusedPost() {
        val id = (savedState?.get<Any>("taggr.focused-post") as? Long)?.takeIf { it >= 0 } ?: return
        if (mutableDetail.value == null && detailJob?.isActive != true) openPostById(id)
    }

    fun closePost() {
        savedState?.set<Long?>("taggr.focused-post", null)
        clearReplies()
        detailGeneration++
        detailJob?.cancel()
        mutableDetail.value = null
    }

    override fun onCleared() {
        clearReplies()
        if (ownsRepository) org.taggr.android.data.closeNetworkResources(repository)
        super.onCleared()
    }
}
