package org.taggr.android

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test
import org.taggr.android.data.FeedMode
import org.taggr.android.data.PostRepository
import org.taggr.android.data.TaggrPost

@OptIn(ExperimentalCoroutinesApi::class)
class FeedViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setup() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun teardown() {
        Dispatchers.resetMain()
    }

    private fun post(id: Long) = TaggrPost(id, "Alice", "Hello", null, 0, emptyList(), 0, 0, null)

    @Test
    fun savedFocusRestoresOnceAndCloseDoesNotReopenIt() =
        runTest(dispatcher) {
            val state = androidx.lifecycle.SavedStateHandle()
            val calls = mutableListOf<List<Long>>()
            val repository =
                object : PostRepository {
                    override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                        emptyList<TaggrPost>()

                    override suspend fun thread(id: Long) = listOf(post(id))

                    override suspend fun posts(ids: List<Long>): List<TaggrPost> {
                        if (ids.isNotEmpty()) calls += ids
                        return ids.map(::post)
                    }
                }
            val original = FeedViewModel(repository, ownsRepository = false, savedState = state)
            original.openPost(post(42))
            advanceUntilIdle()
            val copy =
                androidx.lifecycle.SavedStateHandle(
                    state.keys().associateWith { state.get<Any?>(it) }
                )
            val restored = FeedViewModel(repository, ownsRepository = false, savedState = copy)
            restored.restoreFocusedPost()
            restored.restoreFocusedPost()
            advanceUntilIdle()
            assertEquals(42L, restored.detail.value?.post?.id)
            assertEquals(listOf(listOf(42L)), calls)
            restored.closePost()
            restored.restoreFocusedPost()
            advanceUntilIdle()
            org.junit.Assert.assertNull(restored.detail.value)
            assertEquals(1, calls.size)
        }

    @Test
    fun accountCacheDiscardRemovesSavedFocus() =
        runTest(dispatcher) {
            val state = androidx.lifecycle.SavedStateHandle()
            var calls = 0
            val repository =
                object : PostRepository {
                    override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                        emptyList<TaggrPost>()

                    override suspend fun thread(id: Long) = listOf(post(id))

                    override suspend fun posts(ids: List<Long>): List<TaggrPost> {
                        if (ids.isNotEmpty()) calls++
                        return ids.map(::post)
                    }
                }
            val model = FeedViewModel(repository, ownsRepository = false, savedState = state)
            model.openPost(post(42))
            advanceUntilIdle()
            model.discardCachedContent()
            model.restoreFocusedPost()
            advanceUntilIdle()
            org.junit.Assert.assertNull(model.detail.value)
            assertEquals(0, calls)
        }

    @Test
    fun repliesLoadOnlyOnExpansionAndCollapseReleasesDescendants() =
        runTest(dispatcher) {
            val parent = post(1).copy(children = listOf(3, 2), replyCount = 2)
            val child = post(3).copy(parent = 1, children = listOf(4), replyCount = 1)
            val rows = listOf(child, post(2).copy(parent = 1), post(4).copy(parent = 3))
            val calls = mutableListOf<List<Long>>()
            val model =
                FeedViewModel(
                    object : PostRepository {
                        override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                            listOf(parent)

                        override suspend fun posts(ids: List<Long>): List<TaggrPost> {
                            calls.add(ids)
                            return rows.filter { it.id in ids }
                        }
                    }
                )
            advanceUntilIdle()
            assertEquals(0, calls.size)
            model.toggleReplies(parent)
            advanceUntilIdle()
            assertEquals(listOf(3L, 2L), model.replies.value[1]?.posts?.map { it.id })
            model.expandReplies(parent)
            advanceUntilIdle()
            assertEquals(1, calls.size)
            model.toggleReplies(child)
            advanceUntilIdle()
            assertEquals(
                listOf(1L, 3L, 4L, 2L),
                replyFeedRows(listOf(parent), model.replies.value).map { it.post.id },
            )
            model.toggleReplies(parent)
            assertEquals(emptyMap<Long, PostRepliesState>(), model.replies.value)
        }

    @Test
    fun closedReplyResponseCannotOverwriteReopenedOrDiscardedContent() =
        runTest(dispatcher) {
            val parent = post(1).copy(children = listOf(2), replyCount = 1)
            val first = CompletableDeferred<List<TaggrPost>>()
            var calls = 0
            val model =
                FeedViewModel(
                    object : PostRepository {
                        override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                            listOf(parent)

                        override suspend fun posts(ids: List<Long>): List<TaggrPost> {
                            calls++
                            return if (calls == 1)
                                kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                                    first.await()
                                }
                            else listOf(post(2).copy(parent = 1, body = "New"))
                        }
                    }
                )
            advanceUntilIdle()
            model.toggleReplies(parent)
            testScheduler.runCurrent()
            model.toggleReplies(parent)
            model.toggleReplies(parent)
            testScheduler.runCurrent()
            first.complete(listOf(post(2).copy(parent = 1, body = "Old")))
            advanceUntilIdle()
            assertEquals("New", model.replies.value[1]?.posts?.single()?.body)
            model.discardCachedContent()
            assertEquals(emptyMap<Long, PostRepliesState>(), model.replies.value)
        }

    @Test
    fun failedRepliesRetryAndSubmittedReplyUsesFreshParentChildren() =
        runTest(dispatcher) {
            val parent = post(1).copy(children = listOf(2), replyCount = 1)
            var failed = true
            val model =
                FeedViewModel(
                    object : PostRepository {
                        override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                            listOf(parent)

                        override suspend fun posts(ids: List<Long>): List<TaggrPost> {
                            if (failed) {
                                failed = false
                                error("Offline")
                            }
                            if (ids == listOf(1L))
                                return listOf(parent.copy(children = listOf(2, 3)))
                            return ids.map { post(it).copy(parent = 1) } + post(99).copy(parent = 5)
                        }
                    }
                )
            advanceUntilIdle()
            model.expandReplies(parent)
            advanceUntilIdle()
            assertEquals("Couldn't load replies. Try again.", model.replies.value[1]?.error)
            model.expandReplies(parent)
            advanceUntilIdle()
            assertEquals(listOf(2L), model.replies.value[1]?.posts?.map { it.id })
            model.refresh()
            model.expandReplies(parent, reloadParent = true)
            advanceUntilIdle()
            assertEquals(listOf(2L, 3L), model.replies.value[1]?.posts?.map { it.id })
        }

    @Test
    fun lazyReplyTraversalSuppressesRootDuplicatesAndCyclesWithoutRecursion() {
        val root = post(1)
        val second = post(2)
        val states =
            mapOf(
                1L to PostRepliesState(false, listOf(second, post(3))),
                2L to PostRepliesState(false, listOf(root)),
                3L to PostRepliesState(false, listOf(post(3))),
            )
        assertEquals(
            listOf(1L, 3L, 2L),
            replyFeedRows(listOf(root, second), states).map { it.post.id },
        )
        assertEquals(
            listOf(2L),
            replyFeedRows(listOf(root, second), states, setOf(1)).map { it.post.id },
        )
        val deep =
            (1L..5000L).associateWith {
                PostRepliesState(false, if (it < 5000) listOf(post(it + 1)) else emptyList())
            }
        assertEquals(5000, replyFeedRows(listOf(root), deep).size)
    }

    @Test
    fun switchingModeCancelsPendingHotResponse() =
        runTest(dispatcher) {
            val hot = CompletableDeferred<List<TaggrPost>>()
            val repository =
                object : PostRepository {
                    override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                        if (mode == FeedMode.HOT) hot.await() else listOf(post(20))

                    override suspend fun posts(ids: List<Long>) = emptyList<TaggrPost>()
                }
            val model = FeedViewModel(repository)
            testScheduler.runCurrent()
            model.selectMode(FeedMode.LATEST)
            advanceUntilIdle()
            hot.complete(listOf(post(10)))
            advanceUntilIdle()
            assertEquals(FeedMode.LATEST, model.feed.value.mode)
            assertEquals(listOf(20L), model.feed.value.posts.map { it.id })
        }

    @Test
    fun retriesSamePageAndKeepsOffsetAfterFailure() =
        runTest(dispatcher) {
            val requests = mutableListOf<Pair<Int, Long>>()
            val repository =
                object : PostRepository {
                    override suspend fun feed(
                        mode: FeedMode,
                        page: Int,
                        offset: Long,
                    ): List<TaggrPost> {
                        requests += page to offset
                        if (requests.size == 2) throw IllegalStateException("Offline")
                        return if (page == 0) listOf(post(42)) else emptyList()
                    }

                    override suspend fun posts(ids: List<Long>) = emptyList<TaggrPost>()
                }
            val model = FeedViewModel(repository)
            advanceUntilIdle()
            model.loadMore()
            advanceUntilIdle()
            assertEquals(listOf(42L), model.feed.value.posts.map { it.id })
            model.loadMore()
            advanceUntilIdle()
            assertEquals(listOf(0 to 0L, 1 to 42L, 1 to 42L), requests)
            assertFalse(model.feed.value.canLoadMore)
        }

    @Test
    fun networkTimeoutLeavesRetryableFeed() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        try {
            val repository =
                object : PostRepository {
                    override suspend fun feed(
                        mode: FeedMode,
                        page: Int,
                        offset: Long,
                    ): List<TaggrPost> =
                        kotlinx.coroutines.withTimeout(1) {
                            kotlinx.coroutines.delay(100)
                            emptyList()
                        }

                    override suspend fun posts(ids: List<Long>) = emptyList<TaggrPost>()
                }
            val model = FeedViewModel(repository)
            advanceUntilIdle()
            assertFalse(model.feed.value.loading)
            assertEquals("Loading timed out. Try again.", model.feed.value.error)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun hiddenPageDoesNotStopMainFeedAndUsesRawAnchor() =
        runTest(dispatcher) {
            val calls = mutableListOf<Pair<Int, Long>>()
            val repository =
                object : PostRepository {
                    override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                        error("Use raw page metadata")

                    override suspend fun posts(ids: List<Long>) = emptyList<TaggrPost>()

                    override suspend fun feedPage(
                        mode: FeedMode,
                        page: Int,
                        offset: Long,
                    ): org.taggr.android.data.PostPage {
                        calls += page to offset
                        return if (page == 0) org.taggr.android.data.PostPage(emptyList(), 99, true)
                        else org.taggr.android.data.PostPage(listOf(post(88)), 88, false)
                    }
                }
            val model = FeedViewModel(repository)
            advanceUntilIdle()
            org.junit.Assert.assertTrue(model.feed.value.canLoadMore)
            model.loadMore()
            advanceUntilIdle()
            assertEquals(listOf(0 to 0L, 1 to 99L), calls)
            assertEquals(listOf(88L), model.feed.value.posts.map { it.id })
            assertFalse(model.feed.value.canLoadMore)
        }

    @Test
    fun replyPublishesAncestorsBeforeSlowChildrenAndKeepsThemOnFailure() =
        runTest(dispatcher) {
            val children = CompletableDeferred<List<TaggrPost>>()
            val root = post(10)
            val focused = post(20).copy(parent = 10, children = listOf(30))
            val repository =
                object : PostRepository {
                    override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                        emptyList<TaggrPost>()

                    override suspend fun thread(id: Long) = listOf(root, focused)

                    override suspend fun posts(ids: List<Long>) = children.await()
                }
            val model = FeedViewModel(repository)
            model.openPost(focused)
            testScheduler.runCurrent()
            assertEquals(listOf(10L), model.detail.value!!.ancestors.map { it.id })
            org.junit.Assert.assertTrue(model.detail.value!!.loading)
            children.completeExceptionally(IllegalStateException("Offline"))
            advanceUntilIdle()
            assertEquals(listOf(10L), model.detail.value!!.ancestors.map { it.id })
            org.junit.Assert.assertNotNull(model.detail.value!!.error)
            assertFalse(model.detail.value!!.loading)
        }

    @Test
    fun hiddenAncestorCreatesGapAndUnavailableFocusDropsCachedBody() =
        runTest(dispatcher) {
            var available = true
            val focused = post(20).copy(parent = 15)
            val repository =
                object : PostRepository {
                    override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                        emptyList<TaggrPost>()

                    override suspend fun thread(id: Long) =
                        if (available) listOf(post(10), focused) else listOf(post(10))

                    override suspend fun posts(ids: List<Long>) = emptyList<TaggrPost>()
                }
            val model = FeedViewModel(repository)
            model.openPost(focused)
            advanceUntilIdle()
            org.junit.Assert.assertTrue(model.detail.value!!.contextIncomplete)
            available = false
            model.openPost(focused)
            advanceUntilIdle()
            assertEquals("", model.detail.value!!.post.body)
            assertEquals("Post unavailable", model.detail.value!!.post.restriction)
        }

    @Test
    fun closingConversationIgnoresCancellationResistantThreadReply() =
        runTest(dispatcher) {
            val response = CompletableDeferred<List<TaggrPost>>()
            val repository =
                object : PostRepository {
                    override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                        emptyList<TaggrPost>()

                    override suspend fun thread(id: Long) =
                        kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                            response.await()
                        }

                    override suspend fun posts(ids: List<Long>) = emptyList<TaggrPost>()
                }
            val model = FeedViewModel(repository)
            model.openPost(post(20))
            testScheduler.runCurrent()
            model.closePost()
            response.complete(listOf(post(20)))
            advanceUntilIdle()
            org.junit.Assert.assertNull(model.detail.value)
        }
}
