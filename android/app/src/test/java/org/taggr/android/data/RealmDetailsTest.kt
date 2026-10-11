package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.node.ObjectNode
import org.junit.Assert.*
import org.junit.Test

class RealmDetailsTest {
    private val mapper = ObjectMapper()

    private fun realm() =
        mapper.readTree(
            """{"cleanup_penalty":25,"controllers":[7],"description":"Rules","filter":{"age_days":30,"safe":true,"balance":18446744073709551615,"num_followers":12},"label_color":"#AABBCC","last_setting_update":10,"last_update":20,"logo":"","max_downvotes":4,"num_members":18446744073709551615,"num_posts":2,"revenue":0,"theme":"","whitelist":[],"created":0,"posts":[],"adult_content":false,"comments_filtering":true}"""
        ) as ObjectNode

    @Test
    fun exactCountsAndPostingConditionsMatchNativeSwiftWithWhitelistPriority() {
        val value = realm()
        val details = RealmDetails.decode(value)
        assertEquals(ULong.MAX_VALUE, details.members)
        assertEquals(
            "non-controversial users, balance ≥ 18446744073709551615, account age ≥ 30 days, followers ≥ 12",
            details.posting,
        )
        assertEquals("Realm posting rules apply", details.comments)
        value.set<ObjectNode>("whitelist", mapper.readTree("[1,2]"))
        assertEquals("Limited to 2 approved users", RealmDetails.decode(value).posting)
    }

    @Test
    fun uncontrolledLegacyRealmDisplaysAndSupportsConsentWithoutAllowingEmptyCreationOrEditing() {
        val value = realm()
        value.set<ObjectNode>("controllers", mapper.readTree("[]"))
        value.set<ObjectNode>(
            "filter",
            mapper.readTree("""{"age_days":0,"safe":false,"balance":0,"num_followers":0}"""),
        )
        value.put("comments_filtering", false)
        val details = RealmDetails.decode(value)
        assertEquals("Open to all members", details.posting)
        assertEquals("Open to everyone", details.comments)
        assertTrue(details.controllers.isEmpty())
        RealmMembership.validateConsent(value, value)
        assertThrows(IllegalArgumentException::class.java) { RealmSettings.validateMetadata(value) }
    }

    @Test
    fun malformedMetadataCannotBecomeMisleadingPresentation() {
        for (bad in
            listOf(
                realm().put("num_members", -1),
                realm().put("num_posts", "many"),
                realm().put("comments_filtering", "false"),
            )) assertThrows(IllegalArgumentException::class.java) { RealmDetails.decode(bad) }
    }

    @Test
    fun samplingBoundsDecodedLogoAndRejectsInvalidOrHugeSourceDimensions() {
        assertEquals(1, RealmLogo.sampleSize(128, 256))
        assertEquals(4, RealmLogo.sampleSize(513, 200))
        assertEquals(16, RealmLogo.sampleSize(4096, 4096))
        for ((width, height) in
            listOf(0 to 1, 1 to -1, 4097 to 1, 1 to Int.MAX_VALUE)) assertThrows(
            IllegalArgumentException::class.java
        ) {
            RealmLogo.sampleSize(width, height)
        }
    }
}
