package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class UserBlockingTest {
    private val mapper = ObjectMapper()

    private fun user(blocked: Boolean, id: Long = 7) =
        mapper.readTree("{\"id\":$id,\"blacklist\":${if (blocked) "[8]" else "[]"}}")

    @Test
    fun matchingStateDoesNotToggleAndUnblockingUsesFreshMembership() = runTest {
        var current = user(true)
        var writes = 0
        suspend fun change(selected: Boolean) =
            synchronizeUserBlock(
                8,
                selected,
                read = { current },
                toggle = {
                    writes++
                    current = user(false)
                },
                checkOwner = {},
            )
        change(true)
        assertEquals(0, writes)
        assertFalse(UserBlockState.decode(change(false)).blocked.contains(8))
        assertEquals(1, writes)
    }

    @Test
    fun lostReplyIsConfirmedByReadWithoutReplayingToggle() = runTest {
        var current = user(false)
        var writes = 0
        val result =
            synchronizeUserBlock(
                8,
                true,
                read = { current },
                toggle = {
                    writes++
                    current = user(true)
                    throw IOException("lost reply")
                },
                checkOwner = {},
            )
        assertTrue(8L in UserBlockState.decode(result).blocked)
        assertEquals(1, writes)
    }

    @Test
    fun uncertainUnappliedToggleIsNotRetried() = runTest {
        var writes = 0
        try {
            synchronizeUserBlock(
                8,
                true,
                read = { user(false) },
                toggle = {
                    writes++
                    throw IOException("unavailable")
                },
                checkOwner = {},
            )
            fail("Unconfirmed result must fail")
        } catch (_: IllegalStateException) {}
        assertEquals(1, writes)
    }

    @Test
    fun ownerChangesAndSelfTargetPreventDispatch() = runTest {
        var owner = 7
        var writes = 0
        try {
            synchronizeUserBlock(
                8,
                true,
                read = {
                    owner = 9
                    user(false)
                },
                toggle = { writes++ },
                checkOwner = { require(owner == 7) },
            )
            fail("Changed owner must fail")
        } catch (_: IllegalArgumentException) {}
        owner = 7
        try {
            synchronizeUserBlock(
                7,
                true,
                read = { user(false) },
                toggle = { writes++ },
                checkOwner = { require(owner == 7) },
            )
            fail("Self target must fail")
        } catch (_: IllegalArgumentException) {}
        assertEquals(0, writes)
    }

    @Test
    fun cancellationDoesNotRunResultQueries() = runTest {
        var reads = 0
        try {
            synchronizeUserBlock(
                8,
                true,
                read = {
                    reads++
                    user(false)
                },
                toggle = { throw CancellationException("cancelled") },
                checkOwner = {},
            )
            fail("Cancellation must propagate")
        } catch (_: CancellationException) {}
        assertEquals(1, reads)
    }

    @Test
    fun malformedServerMembershipCannotBeTreatedAsUnblocked() {
        for (json in
            listOf(
                "{}",
                "{\"id\":7}",
                "{\"id\":7,\"blacklist\":[\"8\"]}",
                "{\"id\":7,\"blacklist\":[-1]}",
                "{\"id\":7,\"blacklist\":[9223372036854775808]}",
            )) {
            assertThrows(IllegalArgumentException::class.java) {
                UserBlockState.decode(mapper.readTree(json))
            }
        }
    }
}
