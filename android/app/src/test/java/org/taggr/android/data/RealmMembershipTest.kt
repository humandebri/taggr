package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RealmMembershipTest {
    private val mapper = ObjectMapper()

    private fun user(joined: Boolean) =
        mapper.readTree(if (joined) """{"realms":["TEST"]}""" else """{"realms":[]}""")

    @Test
    fun alreadyDesiredMembershipDoesNotToggleIncludingCaseInsensitiveLookup() = runBlocking {
        var toggles = 0
        RealmMembership.set("test", true, { user(true) }) {
            toggles++
            mapper.readTree("true")
        }
        RealmMembership.set("TEST", false, { user(false) }) {
            toggles++
            mapper.readTree("false")
        }
        assertEquals(0, toggles)
    }

    @Test
    fun joinAndLeaveToggleExactlyOnceWithScalarJsonAndVerifyRefreshedState() = runBlocking {
        for (desired in listOf(true, false)) {
            var joined = !desired
            var toggles = 0
            var reads = 0
            RealmMembership.set(
                "TEST",
                desired,
                {
                    reads++
                    user(joined)
                },
            ) {
                assertEquals("\"TEST\"", it.toString(Charsets.UTF_8))
                toggles++
                joined = desired
                mapper.valueToTree<JsonNode>(joined)
            }
            assertEquals(1, toggles)
            assertEquals(2, reads)
        }
    }

    @Test
    fun unknownToggleResultNeverResendsOrTreatsAnAccountReadAsConfirmation() = runBlocking {
        var reads = 0
        var toggles = 0
        try {
            RealmMembership.set(
                "TEST",
                true,
                {
                    reads++
                    user(false)
                },
            ) {
                toggles++
                throw IllegalStateException("Original request status unavailable")
            }
            fail("Unknown result was accepted")
        } catch (e: IllegalStateException) {
            assertEquals("Original request status unavailable", e.message)
        }
        assertEquals(1, reads)
        assertEquals(1, toggles)
    }

    @Test
    fun concurrentToggleOrStaleRefreshNeverCausesAnAutomaticCorrectiveToggle() = runBlocking {
        for (response in listOf("false", "true")) {
            var toggles = 0
            try {
                RealmMembership.set("TEST", true, { user(false) }) {
                    toggles++
                    mapper.readTree(response)
                }
                fail("Mismatched membership was accepted")
            } catch (_: IllegalArgumentException) {}
            assertEquals(1, toggles)
        }
    }

    @Test
    fun missingOrMalformedAccountMembershipPreventsDispatch() = runBlocking {
        for (bad in listOf("{}", """{"realms":null}""", """{"realms":[1]}""")) {
            var toggles = 0
            try {
                RealmMembership.set("TEST", true, { mapper.readTree(bad) }) {
                    toggles++
                    mapper.readTree("true")
                }
                fail("Invalid account was accepted")
            } catch (_: IllegalArgumentException) {}
            assertEquals(0, toggles)
        }
    }

    @Test
    fun strictScalarArgumentsRejectTrailingJsonAndInvalidNames() {
        assertTrue(RealmMembership.validArguments(RealmMembership.arguments("日本語-TEST_1")))
        for (invalid in
            listOf(
                "null",
                "123",
                "\"\"",
                "\"1\"",
                "[\"TEST\"]",
                "\"TEST\" false",
                "\"bad name\"",
            )) assertFalse(invalid, RealmMembership.validArguments(invalid.toByteArray()))
    }

    @Test
    fun strictBooleanRepliesRejectTrailingJsonAndResultWrappers() {
        assertTrue(
            FinancialReply.decode("toggle_realm_membership", "true".toByteArray()).asBoolean()
        )
        assertFalse(
            FinancialReply.decode("toggle_realm_membership", "false".toByteArray()).asBoolean()
        )
        for (invalid in listOf("null", "1", "{}", "{\"Ok\":true}", "true false")) assertThrows(
            Exception::class.java
        ) {
            FinancialReply.decode("toggle_realm_membership", invalid.toByteArray())
        }
    }

    @Test
    fun consentRejectsChangedRulesOrPermissionsButAllowsUpdatedReadOnlyCounts() {
        val approved =
            mapper.readTree(
                """{"cleanup_penalty":25,"controllers":[7],"description":"Rules","filter":{"age_days":0,"safe":false,"balance":0,"num_followers":0},"label_color":"#AABBCC","last_setting_update":10,"last_update":20,"logo":"","max_downvotes":4,"num_members":1,"num_posts":2,"revenue":0,"theme":"","whitelist":[],"created":0,"posts":[],"adult_content":false,"comments_filtering":true}"""
            )
        val current = approved.deepCopy<com.fasterxml.jackson.databind.node.ObjectNode>()
        current.put("num_members", 50)
        current.put("last_update", 30)
        RealmMembership.validateConsent(approved, current)
        for (field in listOf("cleanup_penalty", "max_downvotes", "last_setting_update")) {
            val changed = current.deepCopy()
            changed.put(field, 99)
            assertThrows(IllegalArgumentException::class.java) {
                RealmMembership.validateConsent(approved, changed)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            RealmMembership.validateConsent(
                approved,
                current.deepCopy().put("description", "New rules"),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            RealmMembership.validateConsent(
                approved,
                current
                    .deepCopy()
                    .set<com.fasterxml.jackson.databind.node.ObjectNode>(
                        "controllers",
                        mapper.readTree("[8]"),
                    ),
            )
        }
    }
}
