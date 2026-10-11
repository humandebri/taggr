package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.node.ObjectNode
import org.junit.Assert.*
import org.junit.Test

class RealmCreationTest {
    private val mapper = ObjectMapper()
    private val limits = RealmCreationLimits(1000uL, 25, 500uL, 15u, "TAGGR")

    private fun draft() =
        RealmCreationDraft(
            RealmCreationDraft.defaults("7", "15").values +
                mapOf("name" to " test_1 ", "description" to " Description ")
        )

    private fun quote(draft: RealmCreationDraft = draft()) =
        RealmCreationQuote(
            "2vxsx-fae",
            "d".repeat(64),
            7,
            draft.name,
            draft.payload(limits, listOf(7uL), emptyList()).toString(),
            limits,
            1000,
        )

    private fun user() =
        mapper.readTree("""{"id":7,"cycles":1000,"deactivated":false}""") as ObjectNode

    @Test
    fun creationPayloadMatchesBackendSchemaAndIncludesAllSwiftSettings() {
        val draft =
            RealmCreationDraft(
                draft().values +
                    mapOf(
                        "ownTheme" to "true",
                        "safe" to "true",
                        "adult" to "true",
                        "filterComments" to "false",
                        "age" to "30",
                        "balance" to ULong.MAX_VALUE.toString(),
                        "followers" to "12",
                    )
            )
        val payload = draft.payload(limits, listOf(7uL, 8uL, 7uL), listOf(11uL, 9uL))
        RealmSettings.validateMetadata(payload)
        assertEquals("TEST_1", draft.name)
        assertEquals("Description", payload["description"].asText())
        assertEquals(listOf(7L, 8L), payload["controllers"].map { it.asLong() })
        assertEquals(listOf(9L, 11L), payload["whitelist"].map { it.asLong() })
        assertEquals(ULong.MAX_VALUE.toString(), payload["filter"]["balance"].asText())
        assertTrue(payload["adult_content"].asBoolean())
        assertFalse(payload["comments_filtering"].asBoolean())
        assertEquals("#ffc700", mapper.readTree(payload["theme"].asText())["accent"].asText())
        assertEquals("", payload["logo"].asText())
        assertEquals(0, payload["posts"].size())
        assertEquals(15, payload["max_downvotes"].asInt())
    }

    @Test
    fun namesUseNormalizedUtf8LengthRejectReservedNamesDigitsAndPunctuation() {
        for (name in
            listOf(
                "123",
                "TAGGR",
                "BAD NAME",
                "X".repeat(26),
                "あ".repeat(9),
                "emoji😀",
            )) assertThrows(IllegalArgumentException::class.java) {
            RealmCreationDraft(draft().values + ("name" to name))
                .payload(limits, listOf(7uL), emptyList())
        }
        RealmCreationDraft(draft().values + ("name" to "あ".repeat(8)))
            .payload(limits, listOf(7uL), emptyList())
    }

    @Test
    fun descriptionLimitsNumbersThemesAndControllerRequirementsAreValidated() {
        for ((field, bad) in
            listOf(
                "description" to " ",
                "description" to "あ".repeat(667),
                "penalty" to "501",
                "penalty" to "-1",
                "downvotes" to "4294967296",
                "balance" to "18446744073709551616",
                "followers" to "1.5",
                "color" to "red",
            )) assertThrows(Exception::class.java) {
            RealmCreationDraft(draft().values + (field to bad))
                .payload(limits, listOf(7uL), emptyList())
        }
        assertThrows(IllegalArgumentException::class.java) {
            draft().payload(limits, emptyList(), emptyList())
        }
        assertThrows(IllegalArgumentException::class.java) {
            draft().payload(limits, listOf(7uL), (0..100).map { it.toULong() })
        }
        assertThrows(IllegalArgumentException::class.java) {
            RealmCreationDraft(draft().values + mapOf("ownTheme" to "true", "theme_text" to "blue"))
                .payload(limits, listOf(7uL), emptyList())
        }
    }

    @Test
    fun quoteRejectsChangedAccountCostLimitsClockStoppedStateOrInsufficientCredits() {
        val quote = quote()
        quote.validate(user(), limits, 121000)
        for (changed in
            listOf(
                user().put("id", 8),
                user().put("cycles", 999),
                user().put("deactivated", true),
            )) assertThrows(IllegalArgumentException::class.java) {
            quote.validate(changed, limits, 1100)
        }
        for (now in listOf(999L, 121001L)) assertThrows(IllegalArgumentException::class.java) {
            quote.validate(user(), limits, now)
        }
        assertThrows(IllegalArgumentException::class.java) {
            quote.validate(user(), limits.copy(cost = 1001uL), 1100)
        }
        assertThrows(IllegalArgumentException::class.java) {
            quote.validate(user(), limits.copy(maxNameBytes = 24), 1100)
        }
    }

    @Test
    fun payloadIsFrozenAndPersistedArgumentsRejectReadOnlyCounterForgeryOrTrailingJson() {
        val quote = quote()
        val args = mapper.readTree(quote.arguments())
        assertEquals("TEST_1", args[0].asText())
        assertTrue(RealmCreation.validArguments(quote.arguments()))
        for (key in listOf("num_members", "created", "revenue")) {
            val mutated = mapper.readTree(quote.arguments())
            (mutated[1] as ObjectNode).put(key, 1)
            assertFalse(RealmCreation.validArguments(mapper.writeValueAsBytes(mutated)))
        }
        assertFalse(RealmCreation.validArguments(quote.arguments() + " false".toByteArray()))
        assertTrue(FinancialReply.decode("create_realm", """{"Ok":null}""".toByteArray()).isNull)
        assertThrows(FinancialRejected::class.java) {
            FinancialReply.decode("create_realm", """{"Err":"name taken"}""".toByteArray())
        }
        assertThrows(IllegalArgumentException::class.java) {
            FinancialReply.decode("create_realm", """{"Ok":true}""".toByteArray())
        }
    }

    @Test
    fun controllerAndWhitelistHandleListsTrimDeduplicateAndRespectBounds() {
        val values =
            draft().values + mapOf("controllers" to "7,alice\n7, bob", "whitelist" to " \n ")
        assertEquals(listOf("7", "alice", "bob"), RealmCreationDraft(values).handles("controllers"))
        assertTrue(RealmCreationDraft(values).handles("whitelist").isEmpty())
        assertThrows(IllegalArgumentException::class.java) {
            RealmCreationDraft(values + ("whitelist" to (0..100).joinToString(",")))
                .handles("whitelist")
        }
    }
}
