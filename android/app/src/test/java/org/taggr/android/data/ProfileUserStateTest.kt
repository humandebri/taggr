package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class ProfileUserStateTest {
    private val mapper = ObjectMapper()

    @Test
    fun membershipKeepsFullIdsAndSeparatesFollowingFromMutedUsers() {
        val state =
            ProfileUserState.decode(
                mapper.readTree(
                    """{"id":7,"followees":[7,8,8],"filters":{"users":[9223372036854775807]}}"""
                )
            )
        assertEquals(7L, state.id)
        assertEquals(setOf(7L, 8L), state.follows)
        assertEquals(setOf(Long.MAX_VALUE), state.muted)
    }

    @Test
    fun incompleteOrMalformedStateDoesNotPermitBlindToggle() {
        for (json in
            listOf(
                "{}",
                """{"id":7,"followees":[],"filters":{}}""",
                """{"id":7,"followees":["8"],"filters":{"users":[]}}""",
                """{"id":7,"followees":[],"filters":{"users":[-1]}}""",
            )) assertTrue(runCatching { ProfileUserState.decode(mapper.readTree(json)) }.isFailure)
        ProfileUserState.confirmMuteReply(mapper.readTree("""{"Ok":null}"""))
        for (json in
            listOf(
                "null",
                "{}",
                """{"Ok":true}""",
                """{"Ok":null,"Err":"rejected"}""",
                """{"Err":"filter size limit exceeded"}""",
            )) assertTrue(
            runCatching { ProfileUserState.confirmMuteReply(mapper.readTree(json)) }.isFailure
        )
    }
}
