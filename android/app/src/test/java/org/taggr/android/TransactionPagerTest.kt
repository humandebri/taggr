package org.taggr.android

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test
import org.taggr.android.data.*

@OptIn(ExperimentalCoroutinesApi::class)
class TransactionPagerTest {
    private fun row(id: Long) =
        TokenTransaction(
            id,
            TokenAccount("aaaaa-aa"),
            TokenAccount("2vxsx-fae"),
            1uL,
            0uL,
            1uL,
            null,
        )

    @Test
    fun failedNextPageKeepsRowsRetriesSamePageAndDeduplicatesNewHistory() = runTest {
        val calls = mutableListOf<Int>()
        var fail = true
        val pager =
            TransactionPager(this) { page ->
                calls += page
                if (page == 0) listOf(row(9))
                else if (fail) {
                    fail = false
                    error("Offline")
                } else if (page == 1) listOf(row(9), row(8)) else emptyList()
            }
        pager.refresh()
        runCurrent()
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(9L), pager.state.value.entries.map { it.id })
        assertEquals("Offline", pager.state.value.error)
        pager.loadMore()
        runCurrent()
        pager.loadMore()
        runCurrent()
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(0, 1, 1, 2), calls)
        assertEquals(listOf(9L, 8L), pager.state.value.entries.map { it.id })
        assertFalse(pager.state.value.hasMore)
        pager.close()
    }

    @Test
    fun refreshAndCloseDiscardLateOldResponses() = runTest {
        val old = CompletableDeferred<List<TokenTransaction>>()
        var calls = 0
        val pager =
            TransactionPager(this) {
                if (calls++ == 0) withContext(NonCancellable) { old.await() } else listOf(row(10))
            }
        pager.refresh()
        runCurrent()
        pager.refresh()
        runCurrent()
        old.complete(listOf(row(9)))
        runCurrent()
        assertEquals(listOf(10L), pager.state.value.entries.map { it.id })
        pager.close()
        pager.refresh()
        pager.loadMore()
        runCurrent()
        assertEquals(2, calls)
    }

    @Test
    fun timeoutAllowsSamePageRetry() = runTest {
        var attempts = 0
        val pager =
            TransactionPager(this) {
                if (attempts++ == 0)
                    withTimeout(10) {
                        delay(100)
                        emptyList()
                    }
                else listOf(row(7))
            }
        pager.refresh()
        advanceUntilIdle()
        assertNotNull(pager.state.value.error)
        pager.loadMore()
        runCurrent()
        assertEquals(listOf(7L), pager.state.value.entries.map { it.id })
        pager.close()
    }
}
