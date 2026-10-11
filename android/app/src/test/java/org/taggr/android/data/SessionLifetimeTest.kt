package org.taggr.android.data

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SessionLifetimeTest {
    @Test
    fun expiresAtDeadlineAndWaitsForInFlightOperation() = runTest {
        var busy = true
        var expired = 0
        val job = launch {
            watchSessionExpiry(1_000_000_000L, { testScheduler.currentTime }, { !busy }) {
                expired++
            }
        }
        advanceTimeBy(1001)
        runCurrent()
        assertEquals(0, expired)
        busy = false
        advanceTimeBy(250)
        runCurrent()
        assertEquals(1, expired)
        assertTrue(job.isCompleted)
        advanceTimeBy(100000)
        assertEquals(1, expired)
    }

    @Test
    fun replacingSessionCancelsOldDeadline() = runTest {
        var expired = 0
        val old = launch {
            watchSessionExpiry(1_000_000_000L, { testScheduler.currentTime }, { true }) {
                expired++
            }
        }
        runCurrent()
        old.cancel()
        val next = launch {
            watchSessionExpiry(2_000_000_000L, { testScheduler.currentTime }, { true }) {
                expired++
            }
        }
        advanceTimeBy(1500)
        runCurrent()
        assertEquals(0, expired)
        advanceTimeBy(501)
        runCurrent()
        assertEquals(1, expired)
        assertTrue(next.isCompleted)
    }

    @Test
    fun rechecksWallClockAfterSuspensionAndRollback() = runTest {
        var wall = 0L
        var expired = false
        val job = launch {
            watchSessionExpiry(60_000_000_000L, { wall }, { true }) { expired = true }
        }
        runCurrent()
        wall = -1000
        advanceTimeBy(30000)
        runCurrent()
        assertFalse(expired)
        wall = 90000
        advanceTimeBy(30000)
        runCurrent()
        assertTrue(expired)
        assertTrue(job.isCompleted)
        assertEquals(0L, sessionRemainingMillis(1_999_999L, 2))
    }
}
