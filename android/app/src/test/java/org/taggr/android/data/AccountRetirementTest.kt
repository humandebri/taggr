package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class AccountRetirementTest {
    private val mapper = ObjectMapper()
    private val quote = RetirementQuote("2vxsx-fae", "a".repeat(64), 7, 100uL, 1000)

    private fun user(stopped: Boolean = false) =
        mapper.readTree(
            """{"id":7,"deactivated":$stopped,"cycles":1000,"controllers":[],"filters":{"noise":{"age_days":0}},"mode":"Mining","governance":true,"show_posts_in_realms":true,"settings":{"links":"private links","pgp":"private key","theme":"dark"}}"""
        )

    private inner class Backend : RetirementBackend {
        var stopped = false
        var calls = 0
        var checks = 0
        var cleanup = 0
        var lost = false
        var rejected = false
        var unavailable = false
        var cost = 100uL

        override suspend fun user() = this@AccountRetirementTest.user(stopped)

        override suspend fun cost() = cost

        override suspend fun clearProfile(user: com.fasterxml.jackson.databind.JsonNode) {
            cleanup++
        }

        override suspend fun clearLinks(user: com.fasterxml.jackson.databind.JsonNode) {
            cleanup++
        }

        override suspend fun stop(quote: RetirementQuote, persist: (ByteArray) -> Unit) {
            calls++
            persist(ByteArray(32) { calls.toByte() })
            if (rejected) throw RetirementRejected()
            if (lost) error("Disconnected")
            stopped = true
        }

        override suspend fun stopResult(requestId: ByteArray): Boolean {
            checks++
            if (rejected) throw RetirementRejected()
            return !unavailable
        }
    }

    private inner class Journal(val backend: Backend) {
        var row = RetirementRecord(quote)

        suspend fun run(): RetirementRecord =
            RetirementWorkflow(backend)
                .resume(
                    row,
                    { previous, next ->
                        assertSame(row, previous)
                        row = next
                    },
                    1000,
                )
    }

    @Test
    fun successfulStopReachesDeviceCleanupWithoutAnotherToggle() =
        runBlocking<Unit> {
            val b = Backend()
            val j = Journal(b)
            assertEquals(RetirementStage.CLEANUP, j.run().stage)
            assertEquals(1, b.calls)
            assertEquals(2, b.cleanup)
            j.run()
            assertEquals(1, b.calls)
        }

    @Test
    fun unknownStopKeepsOriginalIDAndOnlyChecksStatus() =
        runBlocking<Unit> {
            val b =
                Backend().apply {
                    lost = true
                    unavailable = true
                }
            val j = Journal(b)
            try {
                j.run()
                fail()
            } catch (_: IllegalStateException) {}
            assertEquals(RetirementStage.STOP_PENDING, j.row.stage)
            val request = j.row.requestId!!.clone()
            repeat(2) {
                try {
                    j.run()
                    fail()
                } catch (_: IllegalStateException) {}
            }
            assertEquals(1, b.calls)
            assertEquals(2, b.checks)
            assertArrayEquals(request, j.row.requestId)
            b.stopped = true
            assertEquals(RetirementStage.CLEANUP, j.run().stage)
            assertEquals(1, b.calls)
        }

    @Test
    fun certifiedSuccessWaitsForStoppedAccountWithoutResending() =
        runBlocking<Unit> {
            val b = Backend()
            val j = Journal(b)
            j.row = RetirementRecord(quote, RetirementStage.STOP_CONFIRMED, ByteArray(32))
            try {
                j.run()
                fail()
            } catch (_: IllegalArgumentException) {}
            assertEquals(0, b.calls)
            assertEquals(0, b.checks)
            b.stopped = true
            assertEquals(RetirementStage.CLEANUP, j.run().stage)
        }

    @Test
    fun certifiedRejectionAllowsFreshExplicitPreparationButUnknownDoesNot() =
        runBlocking<Unit> {
            val b = Backend().apply { rejected = true }
            val j = Journal(b)
            try {
                j.run()
                fail()
            } catch (_: RetirementRejected) {}
            assertEquals(RetirementStage.PREPARING, j.row.stage)
            b.rejected = false
            j.run()
            assertEquals(2, b.calls)
        }

    @Test
    fun insufficientCreditsChangedCostAndAlreadyStoppedAreRejectedBeforeCleanup() =
        runBlocking<Unit> {
            for (cost in listOf(101uL, 1001uL)) {
                val b = Backend().apply { this.cost = cost }
                val j = Journal(b)
                try {
                    j.run()
                    fail()
                } catch (_: IllegalArgumentException) {}
                assertEquals(0, b.cleanup)
                assertEquals(0, b.calls)
            }
            val b = Backend().apply { stopped = true }
            val j = Journal(b)
            try {
                j.run()
                fail()
            } catch (_: IllegalArgumentException) {}
            assertEquals(0, b.calls)
            assertThrows(IllegalArgumentException::class.java) {
                quote.validate(user(), 100uL, 121001)
            }
            assertThrows(IllegalArgumentException::class.java) {
                quote.copy(cost = 1001uL).validate(user(), 1001uL, 1000)
            }
        }

    @Test
    fun profileCleanupPreservesControllersNoiseModeAndUnrelatedSettings() {
        val args = RetirementReply.profileArguments(user())
        assertEquals("", args[0])
        assertEquals("", args[1])
        assertEquals("Mining", args[5])
        assertEquals(mapOf("theme" to "dark"), RetirementReply.settings(user()))
        RetirementReply.cleanup(mapper.readTree("""{"Ok":null}"""))
        assertThrows(IllegalArgumentException::class.java) {
            RetirementReply.cleanup(mapper.readTree("null"))
        }
    }

    @Test
    fun recordStoresOnlyStageAndRequestIDWithStrictUnsignedCostAndScope() {
        val row =
            RetirementRecord(
                quote.copy(cost = ULong.MAX_VALUE),
                RetirementStage.STOP_PENDING,
                ByteArray(32) { 3 },
            )
        val bytes = RetirementCodec.encode(row)
        val restored = RetirementCodec.decode(bytes, quote.owner, quote.network)
        assertEquals(ULong.MAX_VALUE, restored.quote.cost)
        assertArrayEquals(row.requestId, restored.requestId)
        val keys = mapper.readTree(bytes).fieldNames().asSequence().toSet()
        assertEquals(
            setOf("owner", "network", "userId", "cost", "preparedAtMillis", "stage", "requestId"),
            keys,
        )
        assertThrows(IllegalArgumentException::class.java) {
            RetirementCodec.decode(bytes, "aaaaa-aa", quote.network)
        }
        assertThrows(IllegalArgumentException::class.java) {
            RetirementCodec.decode(bytes, quote.owner, "b".repeat(64))
        }
    }

    @Test
    fun pendingDeletionBlocksGenericSnsAndNewCreditUpdatesBeforeDispatch() =
        runBlocking<Unit> {
            val api = TaggrApi().apply { snsRestricted = true }
            try {
                try {
                    api.update("toggle_following_post", listOf(7))
                    fail()
                } catch (e: IllegalArgumentException) {
                    assertTrue(e.message!!.contains("SNS actions"))
                }
                try {
                    api.financialUpdate("mint_credits_with_icp", "0".toByteArray()) {
                        error("Request dispatched")
                    }
                    fail()
                } catch (e: IllegalArgumentException) {
                    assertTrue(e.message!!.contains("New financial changes"))
                }
                try {
                    api.addPost("Post", null, null, { error("Request dispatched") })
                    fail()
                } catch (e: IllegalArgumentException) {
                    assertTrue(e.message!!.contains("SNS actions"))
                }
            } finally {
                api.close()
            }
        }

    @Test
    fun stopRepliesValidateOnlyStrictResultsAndDoNotEchoBackendSecrets() {
        RetirementReply.decode("""{"Ok":4}""".toByteArray())
        val error =
            assertThrows(RetirementRejected::class.java) {
                RetirementReply.decode("""{"Err":"secret seed"}""".toByteArray())
            }
        assertFalse(error.message!!.contains("secret seed"))
        for (reply in
            listOf("null", "{}", "{\"Ok\":-1}", "{\"Ok\":null}", "{\"Ok\":1,\"Err\":\"x\"}")) {
            assertThrows(IllegalArgumentException::class.java) {
                RetirementReply.decode(reply.toByteArray())
            }
        }
    }
}
