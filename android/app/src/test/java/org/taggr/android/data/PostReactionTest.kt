package org.taggr.android.data

import java.io.IOException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class PostReactionTest {
    private fun post() =
        TaggrPost(42, "Alice", "Hello", null, 0, emptyList(), 0, 0, null, authorId = 7)

    @Test
    fun confirmsLostReplyWithoutSendingTwice() = runTest {
        var current = post()
        var writes = 0
        submitPostReaction(
            42,
            8,
            1,
            read = { current },
            send = {
                writes++
                current = current.copy(reactions = mapOf(1 to listOf(8L)))
                throw IOException("lost reply")
            },
            checkOwner = {},
        )
        assertEquals(1, writes)
    }

    @Test
    fun unappliedRequestRemainsUnconfirmed() = runTest {
        var writes = 0
        try {
            submitPostReaction(
                42,
                8,
                1,
                read = { post() },
                send = {
                    writes++
                    throw IOException("offline")
                },
                checkOwner = {},
            )
            fail("Unconfirmed request must fail")
        } catch (e: IllegalStateException) {
            assertTrue(e.cause is IOException)
        }
        assertEquals(1, writes)
    }

    @Test
    fun ineligiblePostsNeverSend() = runTest {
        for (current in
            listOf(
                post(),
                post().copy(viewerBlocked = true),
                post().copy(reactions = mapOf(1 to listOf(8L))),
            )) {
            var writes = 0
            try {
                submitPostReaction(
                    42,
                    if (current == post()) 7 else 8,
                    1,
                    read = { current },
                    send = { writes++ },
                    checkOwner = {},
                )
                fail("Ineligible viewer must fail")
            } catch (_: IllegalArgumentException) {}
            assertEquals(0, writes)
        }
    }

    @Test
    fun accountChangeDuringReadPreventsSend() = runTest {
        var owner = 8
        var writes = 0
        try {
            submitPostReaction(
                42,
                8,
                1,
                read = {
                    owner = 9
                    post()
                },
                send = { writes++ },
                checkOwner = { require(owner == 8) },
            )
            fail("Changed account must fail")
        } catch (_: IllegalArgumentException) {}
        assertEquals(0, writes)
    }
}
