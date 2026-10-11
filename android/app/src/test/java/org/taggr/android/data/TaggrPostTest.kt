package org.taggr.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class TaggrPostTest {
    @Test
    fun deletedPostKeepsHistoryHashesWithoutOverridingStrongerRestrictions() {
        val hashes =
            ",\"hashes\":[\"0123456789abcdef0123456789abcdef\",\"fedcba9876543210fedcba9876543210\"]"
        val deleted = decode(hashes)
        assertEquals(true, deleted.deleted)
        assertEquals(
            listOf("0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210"),
            deleted.deletionHashes,
        )
        assertEquals("This post has been deleted.", deleted.restriction)
        assertEquals("This post is encrypted.", decode(hashes + ",\"encrypted\":true").restriction)
        assertEquals(
            "This post has been moderated.",
            decode(hashes, ",\"max_downvotes_reached\":true").restriction,
        )
        assertEquals(emptyList<String>(), decode().deletionHashes)
        assertEquals(listOf("kept"), decode(",\"hashes\":[\"kept\",null,42,{}]").deletionHashes)
    }

    @Test
    fun receivedTipsCountEventsRatherThanSummingAmountsAndKeepsUnsignedValues() {
        assertEquals(0, decode().tipCount)
        assertEquals(3, decode(",\"tips\":[[7,100],[7,200],[8,18446744073709551615]]").tipCount)
        assertEquals(
            1,
            decode(
                    ",\"tips\":[[\"8\",\"250\"],[-1,5],[7,-2],[7,0.5],[7,18446744073709551616],[7],[7,10,20],null,\"tip\"]"
                )
                .tipCount,
        )
        assertEquals(0, decode(",\"tips\":{\"7\":100}").tipCount)
    }

    private fun decode(post: String = "", meta: String = ""): TaggrPost =
        TaggrPost.decodeEnvelopes(
                """[[{"id":42,"user":7,"body":"Hello","timestamp":1750000000123456789,"children":[43],"tree_size":5,"reactions":{"1":[7,8]}$post},{"author_name":"Alice"$meta}]]"""
                    .toByteArray()
            )
            .single()

    @Test
    fun readsBackendTupleAndNanosecondsWithoutFloatingPointLoss() {
        val post = decode()
        assertEquals(42L, post.id)
        assertEquals("Alice", post.author)
        assertEquals(1750000000123L, post.timestampMillis)
        assertEquals(listOf(43L), post.children)
        assertEquals(5, post.replyCount)
        assertEquals(2, post.reactionCount)
        assertNull(post.restriction)
    }

    @Test
    fun usesEffectiveBodyAndTimelineCutFromIOS() {
        val post = decode(",\"eff_body\":\"Updated\\n\\n\\n\\nMore text\"")
        assertEquals("Updated\n\n\n\nMore text", post.body)
        assertEquals("Updated", post.timelineBody)
    }

    @Test
    fun doesNotExposeRestrictedBodies() {
        assertNotNull(decode(",\"encrypted\":true").restriction)
        assertNotNull(decode(",\"hashes\":[\"deleted\"]").restriction)
        assertNotNull(decode(meta = ",\"max_downvotes_reached\":true").restriction)
        assertNotNull(decode(meta = ",\"nsfw\":true").restriction)
        assertNotNull(decode(",\"eff_body\":\"#NSFW content\"").restriction)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsUnexpectedBackendEnvelope() {
        TaggrPost.decodeEnvelopes("[{\"id\":42}]".toByteArray())
    }

    @Test
    fun repostSourceKeepsExactIdAndRejectsMalformedReferences() {
        assertEquals(setOf(42L, 43L), decode(",\"reposts\":[42,43,42,-1,\"44\",null,0.5]").reposts)
        assertEquals(
            Long.MAX_VALUE,
            decode(",\"extension\":{\"Repost\":9223372036854775807}").repostId,
        )
        for (value in listOf("-1", "\"42\"", "0.5", "9223372036854775808", "null")) assertNull(
            decode(",\"extension\":{\"Repost\":$value}").repostId
        )
    }

    @Test
    fun hiddenMembershipIsViewerSpecificAndRejectsMalformedIds() {
        val post = decode(",\"hidden_for\":[7,7,8,-1,\"9\",null,1.5,18446744073709551615]")
        assertEquals(setOf(7L, 8L), post.hiddenFor)
        assertEquals(true, post.hiddenForViewer(7))
        assertEquals(false, post.hiddenForViewer(9))
        assertEquals(false, post.hiddenForViewer(null))
        assertNull(post.restriction)
        assertEquals(emptySet<Long>(), decode(",\"hidden_for\":{\"7\":true}").hiddenFor)
    }

    @Test
    fun reactionEligibilityMatchesViewerAndExistingReaction() {
        val post = decode()
        assertEquals(true, post.canReact(null))
        assertEquals(false, post.canReact(7))
        assertEquals(false, post.canReact(8))
        assertEquals(true, post.canReact(9))
        val blocked = decode(meta = ",\"viewer_blocked\":true")
        assertEquals(true, blocked.viewerBlocked)
        assertEquals(false, blocked.canReact(9))
        assertEquals(false, blocked.canReact(null))
        assertEquals(false, decode(meta = ",\"viewer_blocked\":null").viewerBlocked)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsMalformedViewerBlockStatus() {
        decode(meta = ",\"viewer_blocked\":\"false\"")
    }
}
