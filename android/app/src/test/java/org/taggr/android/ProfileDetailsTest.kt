package org.taggr.android

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class ProfileDetailsTest {
    @Test
    fun linksSplitOnlyTheFirstColonAndPreserveHttpsTargets() {
        val profile =
            ObjectMapper()
                .readTree(
                    """{"settings":{"links":"Website: https://example.com/a:b?x=1\nNo space:https://example.org/\n Unicode 🍊 : https://example.net/path#part"}}"""
                )
        assertEquals(
            listOf(
                ProfileLink("Website", "https://example.com/a:b?x=1"),
                ProfileLink("No space", "https://example.org/"),
                ProfileLink("Unicode 🍊", "https://example.net/path#part"),
            ),
            profileLinks(profile),
        )
    }

    @Test
    fun malformedAndNonHttpsLinksDoNotBecomeActions() {
        val profile =
            ObjectMapper()
                .readTree(
                    """{"settings":{"links":"Missing\n: https://example.com\nHttp: http://example.com\nScript: javascript:alert(1)\nFile: file:///tmp/a\nInvalid: https:///path\nCredentials: https://user:pass@example.com\n Space: https://example.com/a b"}}"""
                )
        assertTrue(profileLinks(profile).isEmpty())
        assertTrue(profileLinks(ObjectMapper().readTree("""{"settings":{"links":42}}""")).isEmpty())
    }
}
