package org.taggr.android

import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test
import org.taggr.android.data.*

@OptIn(ExperimentalCoroutinesApi::class)
class PhotoPagerTest {
    private fun post(id: Long, image: Boolean = true, restriction: String? = null) =
        TaggrPost(
            id,
            "Alice",
            if (image) "![photo](https://images.example/$id.png)" else "Text only",
            null,
            0,
            emptyList(),
            0,
            0,
            restriction,
        )

    @Test
    fun viewerHiddenImagesAreSkippedWithoutEndingPagination() = runTest {
        val hidden = post(100).copy(hiddenFor = setOf(7))
        assertEquals(1, photosFrom(listOf(hidden), 8).size)
        assertEquals(1, photosFrom(listOf(hidden), null).size)
        val calls = mutableListOf<Int>()
        val pager =
            PhotoPager(this, 7) { page, _ ->
                calls.add(page)
                if (page == 0) PostPage(listOf(hidden), 100, true)
                else PostPage(listOf(post(90)), 90, false)
            }
        pager.refresh()
        runCurrent()
        assertEquals(listOf(0, 1), calls)
        assertEquals(listOf(90L), pager.state.value.photos.map { it.postId })
        pager.close()
    }

    @Test
    fun imageFreeAndRestrictedPagesAreScannedWithOriginalAnchor() = runTest {
        val calls = mutableListOf<Pair<Int, Long>>()
        val pager =
            PhotoPager(this) { page, anchor ->
                calls += page to anchor
                when (page) {
                    0 -> PostPage(listOf(post(100, false)), 100, true)
                    1 -> PostPage(listOf(post(95, restriction = "Hidden")), 95, true)
                    else -> PostPage(listOf(post(90)), 90, true)
                }
            }
        pager.refresh()
        runCurrent()
        assertEquals(listOf(0 to 0L, 1 to 100L, 2 to 100L), calls)
        assertEquals(listOf(90L), pager.state.value.photos.map { it.postId })
        assertFalse(pager.state.value.loading)
        pager.close()
    }

    @Test
    fun failedPageRetainsPhotosAndRetriesExactCursorThroughDuplicates() = runTest {
        var fail = true
        val calls = mutableListOf<Pair<Int, Long>>()
        val pager =
            PhotoPager(this) { page, anchor ->
                calls += page to anchor
                when (page) {
                    0,
                    1 -> PostPage(listOf(post(100)), 100, true)
                    2 ->
                        if (fail) {
                            fail = false
                            error("Offline")
                        } else PostPage(listOf(post(90)), 90, true)
                    else -> PostPage(emptyList(), 0, false)
                }
            }
        pager.refresh()
        runCurrent()
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(100L), pager.state.value.photos.map { it.postId })
        assertEquals("Offline", pager.state.value.error)
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(100L, 90L), pager.state.value.photos.map { it.postId })
        assertNull(pager.state.value.error)
        pager.loadMore()
        runCurrent()
        assertFalse(pager.state.value.canLoadMore)
        assertEquals(listOf(0 to 0L, 1 to 100L, 2 to 100L, 2 to 100L, 3 to 100L), calls)
        pager.close()
    }

    @Test
    fun refreshedAndClosedPagersIgnoreLateNonCancellableReplies() = runTest {
        val late = CompletableDeferred<PostPage>()
        var calls = 0
        val pager =
            PhotoPager(this) { _, _ ->
                if (++calls == 1) withContext(NonCancellable) { late.await() }
                else PostPage(listOf(post(200)), 200, false)
            }
        pager.refresh()
        runCurrent()
        pager.refresh()
        runCurrent()
        late.complete(PostPage(listOf(post(100)), 100, false))
        runCurrent()
        assertEquals(listOf(200L), pager.state.value.photos.map { it.postId })
        pager.close()
        pager.refresh()
        runCurrent()
        assertEquals(2, calls)
    }

    @Test
    fun groupsUseLocalCalendarYearAndStableNewestFirstOrdering() {
        val boundary = Instant.parse("2026-01-01T00:30:00Z").toEpochMilli()
        val older = Instant.parse("2025-01-01T00:00:00Z").toEpochMilli()
        val photos =
            listOf(
                AccountPhoto(1, older, "old", "", 0),
                AccountPhoto(2, boundary, "new", "", 0),
                AccountPhoto(3, boundary, "newest", "", 0),
            )
        assertEquals(listOf(2026, 2025), photoYears(photos, ZoneId.of("UTC")).map { it.year })
        assertEquals(
            listOf(3L, 2L),
            photoYears(photos, ZoneId.of("UTC")).first().photos.map { it.postId },
        )
        assertEquals(2025, photoYears(photos, ZoneId.of("America/Los_Angeles")).first().year)
    }

    @Test
    fun repeatedPostWithNewRestrictionRemovesItsPreviouslyLoadedImage() = runTest {
        val pager =
            PhotoPager(this) { page, _ ->
                if (page == 0) PostPage(listOf(post(100)), 100, true)
                else PostPage(listOf(post(100, restriction = "Deleted"), post(90)), 90, false)
            }
        pager.refresh()
        runCurrent()
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(90L), pager.state.value.photos.map { it.postId })
        pager.close()
    }
}
