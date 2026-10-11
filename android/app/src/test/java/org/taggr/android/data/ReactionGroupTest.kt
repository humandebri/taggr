package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class ReactionGroupTest {
    @Test
    fun iconsMatchSwiftAndWebAndConfiguredOrderWins() {
        assertEquals("❤️", ReactionGroup.emoji(10))
        assertEquals("👍", ReactionGroup.emoji(11))
        assertEquals("😢", ReactionGroup.emoji(12))
        assertEquals("❌", ReactionGroup.emoji(1))
        val reactions =
            mapOf(10 to listOf(1L), 11 to listOf(2L), 1 to listOf(3L), 500 to listOf(4L))
        assertEquals(
            listOf(11, 10, 1),
            ReactionGroup.groups(reactions, ReactionGroup.defaultOrder).map { it.id },
        )
        assertEquals(
            listOf(10, 11, 1),
            ReactionGroup.groups(reactions, listOf(10, 11)).map { it.id },
        )
        assertEquals(listOf(1, 10, 11), ReactionGroup.groups(reactions, emptyList()).map { it.id })
    }

    @Test
    fun decodePreservesKnownAndFutureIdsWithoutMalformedUserValues() {
        val node =
            ObjectMapper()
                .readTree(
                    """{"11":[7,7,9,-1,"3",1.5,18446744073709551615],"500":[4],"01":[2],"65536":[1],"10":null}"""
                )
        assertEquals(mapOf(11 to listOf(7L, 9L), 500 to listOf(4L)), ReactionGroup.decode(node))
        assertTrue(ReactionGroup.decode(ObjectMapper().readTree("[]")).isEmpty())
    }

    @Test
    fun postEnvelopeKeepsReactionMembersForDetails() {
        val rows =
            """[[{"id":1,"user":2,"timestamp":0,"body":"Body","reactions":{"10":[7],"11":[8,9]}},{}]]"""
        val post = TaggrPost.decodeEnvelopes(rows.toByteArray()).single()
        assertEquals(3, post.reactionCount)
        assertEquals(listOf(8L, 9L), post.reactions[11])
        assertEquals("Body", post.body)
    }
}
