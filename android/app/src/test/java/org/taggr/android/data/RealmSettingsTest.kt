package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.node.ObjectNode
import org.junit.Assert.*
import org.junit.Test

class RealmSettingsTest {
    private val mapper = ObjectMapper()

    private fun realm() =
        mapper.readTree(
            """{"cleanup_penalty":10,"controllers":[7,8],"description":"Original","filter":{"age_days":3,"safe":true,"balance":42,"num_followers":5},"label_color":"#aabbcc","last_setting_update":100,"last_update":200,"logo":"existing","max_downvotes":4,"num_members":10,"num_posts":20,"revenue":-1,"theme":"custom","whitelist":[9],"created":50,"posts":[],"adult_content":false,"comments_filtering":true}"""
        )

    private fun context() =
        RealmEditContext("2vxsx-fae", "a".repeat(64), 7, "TEST", realm(), 500uL, 16384)

    @Test
    fun payloadChangesEditableFieldsAndPreservesAuthorityThemeFilterAndFreshCounters() {
        val current = realm() as ObjectNode
        current.put("num_posts", 999)
        current.put("last_update", 300)
        val payload =
            RealmSettingsDraft.from(realm())
                .copy(description = " New description ", labelColor = "#abcdef")
                .payload(current, 500uL, 16384)
        assertEquals("New description", payload["description"].asText())
        assertEquals("#ABCDEF", payload["label_color"].asText())
        for (field in
            listOf(
                "controllers",
                "filter",
                "whitelist",
                "theme",
                "created",
                "revenue",
                "logo",
                "num_posts",
                "last_update",
            )) assertEquals(current[field], payload[field])
        assertEquals("Original", current["description"].asText())
    }

    @Test
    fun unicodeLimitsMatchBackendUtf8BytesAndRejectInvalidNumbersAndColor() {
        val draft = RealmSettingsDraft.from(realm())
        draft.copy(description = "あ".repeat(666)).payload(realm(), 500uL, 16384)
        for (bad in
            listOf(
                draft.copy(description = "あ".repeat(667)),
                draft.copy(description = " "),
                draft.copy(labelColor = "red"),
                draft.copy(cleanupPenalty = "-1"),
                draft.copy(cleanupPenalty = "501"),
                draft.copy(maxDownvotes = "4294967296"),
                draft.copy(maxDownvotes = "1.5"),
            )) {
            assertThrows(IllegalArgumentException::class.java) {
                bad.payload(realm(), 500uL, 16384)
            }
        }
    }

    @Test
    fun preflightRejectsChangedControllerUserOrSettingsButAllowsFreshReadOnlyStatistics() {
        val context = context()
        val user = mapper.readTree("""{"id":7}""")
        val current = realm() as ObjectNode
        current.put("num_members", 999)
        current.put("last_update", 300)
        context.validate(current, user, 500uL, 16384)
        for (field in listOf("description", "theme", "logo")) {
            val changed = realm() as ObjectNode
            changed.put(field, "Changed")
            assertThrows(IllegalArgumentException::class.java) {
                context.validate(changed, user, 500uL, 16384)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            context.validate(realm(), mapper.readTree("""{"id":8}"""), 500uL, 16384)
        }
        assertThrows(IllegalArgumentException::class.java) {
            context.validate(realm(), user, 501uL, 16384)
        }
        assertThrows(IllegalArgumentException::class.java) {
            context.validate(realm(), user, 500uL, 16383)
        }
        assertThrows(IllegalArgumentException::class.java) { context.copy(userId = 9) }
    }

    @Test
    fun optionalLogoPreservesOldLogoAndNewBase64RespectsEncodedSize() {
        val draft = RealmSettingsDraft.from(realm())
        assertEquals("existing", draft.payload(realm(), 500uL, 16384)["logo"].asText())
        assertEquals("AQID", draft.copy(logo = "AQID").payload(realm(), 500uL, 4)["logo"].asText())
        assertThrows(IllegalArgumentException::class.java) {
            draft.copy(logo = "AQID").payload(realm(), 500uL, 3)
        }
        assertThrows(IllegalArgumentException::class.java) {
            draft.copy(logo = "?").payload(realm(), 500uL, 16384)
        }
    }

    @Test
    fun financialArgumentsRequireCompleteTypedRealmAndStrictCertifiedReply() {
        val args = mapper.writeValueAsBytes(listOf("TEST", realm()))
        assertTrue(RealmSettings.validArguments(args))
        FinancialCall("2vxsx-fae", "aaaaa-aa", "a".repeat(64), "edit_realm", ByteArray(32), args)
        assertTrue(FinancialReply.decode("edit_realm", """{"Ok":null}""".toByteArray()).isNull)
        assertThrows(FinancialRejected::class.java) {
            FinancialReply.decode("edit_realm", """{"Err":"not authorized"}""".toByteArray())
        }
        assertThrows(IllegalArgumentException::class.java) {
            FinancialReply.decode("edit_realm", """{"Ok":1}""".toByteArray())
        }
        val missing = realm() as ObjectNode
        missing.remove("filter")
        assertFalse(RealmSettings.validArguments(mapper.writeValueAsBytes(listOf("TEST", missing))))
        val controller = realm() as ObjectNode
        controller.putArray("controllers")
        assertFalse(
            RealmSettings.validArguments(mapper.writeValueAsBytes(listOf("TEST", controller)))
        )
        assertFalse(RealmSettings.validArguments("[]".toByteArray()))
    }
}
