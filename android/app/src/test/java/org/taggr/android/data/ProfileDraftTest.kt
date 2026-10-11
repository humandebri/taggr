package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test

class ProfileDraftTest {
    private val mapper = ObjectMapper()

    private fun user() =
        mapper.readTree(
            """{"id":7,"name":"Alice","about":"old","mode":"Mining","governance":true,"controllers":[],"settings":{"links":"Site: https://example.com","storage_creation":"private state"},"filters":{"noise":{"age_days":12,"safe":true,"balance":42,"num_followers":3}},"show_posts_in_realms":false,"rewards":0}"""
        )

    @Test
    fun updateKeepsUneditedFilterAndRealmPreferences() {
        val user = user()
        val draft = ProfileDraft.from(user).copy(about = "new", governance = false)
        val tuple = mapper.readTree(LegacyJsonArguments.encode(draft.updateArguments(user)))
        assertEquals(7, tuple.size())
        assertEquals("", tuple[0].asText())
        assertEquals("new", tuple[1].asText())
        assertEquals(user["filters"]["noise"], tuple[3])
        assertFalse(tuple[4].asBoolean())
        assertEquals("Mining", tuple[5].asText())
        assertFalse(tuple[6].asBoolean())
    }

    @Test
    fun linksMergeIntoLatestSettingsWithoutRemovingStorageState() {
        val user = user()
        val draft = ProfileDraft.from(user).copy(links = "New site: https://example.org")
        val merged = draft.mergedSettings(user)
        assertEquals("private state", merged["storage_creation"])
        assertEquals(draft.links, merged["links"])
        assertFalse(draft.profileChanged(user))
    }

    @Test
    fun reconcilesPartiallySavedProfileWithoutLosingRequestedLinks() {
        val user = user()
        val draft =
            ProfileDraft.from(user).copy(about = "changed", links = "New site: https://example.org")
        assertEquals(listOf("About", "Links"), draft.unsavedFields(user))
        (user as com.fasterxml.jackson.databind.node.ObjectNode).put("about", "changed")
        assertEquals(listOf("Links"), draft.unsavedFields(user))
        (user["settings"] as com.fasterxml.jackson.databind.node.ObjectNode).put(
            "links",
            draft.links,
        )
        assertTrue(draft.unsavedFields(user).isEmpty())
    }

    @Test
    fun rejectsInvalidControllersLinksAndRewardModeSwitch() {
        val user = user()
        val draft = ProfileDraft.from(user)
        assertThrows(IllegalArgumentException::class.java) {
            draft.copy(controllers = "invalid-principal").validate()
        }
        assertThrows(IllegalArgumentException::class.java) {
            draft.copy(controllers = "2vxsx-fae\n2vxsx-fae").validate()
        }
        assertThrows(IllegalArgumentException::class.java) {
            draft.copy(links = "Label: http://example.com").validate()
        }
        assertThrows(IllegalArgumentException::class.java) {
            draft.copy(links = "Label: https://").validate()
        }
        (user as com.fasterxml.jackson.databind.node.ObjectNode).put("rewards", 5)
        assertThrows(IllegalArgumentException::class.java) {
            draft.copy(mode = "Credits").updateArguments(user)
        }
        user.remove("show_posts_in_realms")
        assertThrows(IllegalArgumentException::class.java) { draft.updateArguments(user) }
    }
}
