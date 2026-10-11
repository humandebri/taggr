package org.taggr.android

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test
import org.taggr.android.data.*

@OptIn(ExperimentalCoroutinesApi::class)
class PostPagerTest {
    private fun post(id: Long) =
        TaggrPost(id, "Alice", "Post $id", null, 0, emptyList(), 0, 0, null)

    @Test
    fun failedNextPageRetainsSnapshotAndRetriesSameRequest() = runTest {
        val calls = mutableListOf<Pair<Int, Long>>()
        var fail = true
        val pager =
            PostPager(this) { page, offset ->
                calls += page to offset
                if (page == 0) PostPage(listOf(post(100)), 100, true)
                else if (fail) {
                    fail = false
                    error("Offline")
                } else PostPage(listOf(post(100), post(90)), 90, true)
            }
        pager.refresh()
        runCurrent()
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(100L), pager.state.value.posts.map { it.id })
        assertEquals("Offline", pager.state.value.error)
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(0 to 0L, 1 to 100L, 1 to 100L), calls)
        assertEquals(listOf(100L, 90L), pager.state.value.posts.map { it.id })
        assertNull(pager.state.value.error)
        pager.close()
    }

    @Test
    fun fullyHiddenPageStillAnchorsAndAllowsFollowingPage() = runTest {
        val calls = mutableListOf<Pair<Int, Long>>()
        val pager =
            PostPager(this) { page, offset ->
                calls += page to offset
                when (page) {
                    0 -> PostPage.visible(listOf(post(100))) { false }
                    1 -> PostPage(listOf(post(90)), 90, true)
                    else -> PostPage(emptyList(), 0, false)
                }
            }
        pager.refresh()
        runCurrent()
        assertTrue(pager.state.value.posts.isEmpty())
        assertTrue(pager.state.value.canLoadMore)
        pager.loadMore()
        runCurrent()
        pager.loadMore()
        runCurrent()
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(0 to 0L, 1 to 100L, 2 to 100L), calls)
        assertEquals(listOf(90L), pager.state.value.posts.map { it.id })
        assertFalse(pager.state.value.canLoadMore)
        pager.close()
    }

    @Test
    fun refreshRejectsLateOldResponsesEvenIfLoaderIgnoresCancellation() = runTest {
        val first = CompletableDeferred<PostPage>()
        var calls = 0
        val pager =
            PostPager(this) { _, _ ->
                if (calls++ == 0) withContext(NonCancellable) { first.await() }
                else PostPage(listOf(post(200)), 200, true)
            }
        pager.refresh()
        runCurrent()
        pager.refresh()
        runCurrent()
        first.complete(PostPage(listOf(post(100)), 100, true))
        runCurrent()
        assertEquals(listOf(200L), pager.state.value.posts.map { it.id })
        pager.close()
        pager.refresh()
        pager.loadMore()
        runCurrent()
        assertEquals(2, calls)
    }

    @Test
    fun timeoutLeavesSamePageAvailableForRetry() = runTest {
        var attempts = 0
        val pager =
            PostPager(this) { _, _ ->
                if (attempts++ == 0)
                    withTimeout(10) {
                        delay(100)
                        PostPage(emptyList(), 0, false)
                    }
                else PostPage(listOf(post(7)), 7, true)
            }
        pager.refresh()
        advanceUntilIdle()
        assertFalse(pager.state.value.loading)
        assertNotNull(pager.state.value.error)
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(7L), pager.state.value.posts.map { it.id })
        pager.close()
    }
}
