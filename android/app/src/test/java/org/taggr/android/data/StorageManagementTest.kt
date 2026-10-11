package org.taggr.android.data

import java.io.IOException
import java.math.BigInteger
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.ic4j.agent.android.*
import org.ic4j.types.Principal
import org.junit.Assert.*
import org.junit.Test

class StorageManagementTest {
    @Test
    fun bucketUnitReplyDiffersFromManagementEmptyReply() {
        val bucketReply = byteArrayOf(0x44, 0x49, 0x44, 0x4c, 0, 1, 0x7f)
        val managementReply = CandidArguments().encode()
        StorageManagementWire.confirmReply(bucketReply, false)
        StorageManagementWire.confirmReply(managementReply, true)
        assertThrows(IllegalArgumentException::class.java) {
            StorageManagementWire.confirmReply(bucketReply, true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            StorageManagementWire.confirmReply(managementReply, false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            StorageManagementWire.confirmReply(
                CandidArguments(Candid.bool.encode(true)).encode(),
                false,
            )
        }
    }

    private val owner = "2vxsx-fae"
    private val bucket = "rrkah-fqaaa-aaaaa-aaaaq-cai"
    private val old =
        StorageStatus(
            bucket,
            "running",
            listOf(owner),
            "a".repeat(64),
            BigInteger.valueOf(123456),
            BigInteger.TEN,
            BigInteger.ONE,
            "b".repeat(64),
        )

    private fun quote(action: StorageManagementAction) =
        StorageManagementQuote(
            action,
            owner,
            7,
            if (action == StorageManagementAction.UPGRADE) old
            else old.copy(moduleHash = old.expectedHash),
            100,
        )

    private class Port(var current: StorageStatus) : StorageManagementPort {
        val calls = mutableListOf<String>()
        var upgradeFailure: Exception? = null
        var internalFailure: Exception? = null
        var managementFailure: Exception? = null
        var changeAfterInternal = false
        var applyUpgrade = true
        var publishedAfterUpgrade: String? = null

        override suspend fun status(): StorageStatus {
            calls += "status"
            return current
        }

        override suspend fun upgrade() {
            calls += "upgrade"
            if (upgradeFailure is CancellationException) throw upgradeFailure!!
            if (applyUpgrade) current = current.copy(moduleHash = current.expectedHash)
            publishedAfterUpgrade?.let { current = current.copy(expectedHash = it) }
            upgradeFailure?.let { throw it }
        }

        override suspend fun synchronizeInternalControllers() {
            calls += "internal"
            internalFailure?.let { throw it }
            if (changeAfterInternal)
                current = current.copy(controllers = current.controllers + "aaaaa-aa")
        }

        override suspend fun addManagementController() {
            calls += "management"
            current =
                current.copy(controllers = current.controllers + StorageProvisioning.BLACKHOLE)
            managementFailure?.let { throw it }
        }
    }

    @Test
    fun upgradeUsesStatePreservingModeAndSettingsOnlyAddControllers() {
        val bytes = byteArrayOf(0, 0x61, 0x73, 0x6d, 1, 0, 0, 0)
        val wasm =
            VerifiedStorageWasm.verify(
                bytes,
                DraftImages.hex(MessageDigest.getInstance("SHA-256").digest(bytes)),
            )
        val args =
            Candid.decode(StorageManagementWire.upgradeArguments(bucket, owner, wasm))
                .values
                .single()
                .value
        assertEquals(
            Candid.fieldID("upgrade"),
            (LedgerWire.field(args, "mode") as CandidVariant).tag,
        )
        assertEquals(Principal.fromString(bucket), LedgerWire.field(args, "canister_id"))
        assertArrayEquals(bytes, LedgerWire.field(args, "wasm_module") as ByteArray)
        assertEquals(
            listOf(Principal.fromString(owner)),
            Candid.decode(LedgerWire.field(args, "arg") as ByteArray).values.single().value,
        )
        val settings =
            Candid.decode(
                    StorageManagementWire.settingsArguments(
                        bucket,
                        listOf(owner, StorageProvisioning.BLACKHOLE),
                    )
                )
                .values
                .single()
                .value
        val record = LedgerWire.field(settings, "settings") as Map<*, *>
        assertEquals(1, record.size)
        val controllers = LedgerWire.field(record, "controllers") as CandidOption.Some
        assertEquals(
            listOf(owner, StorageProvisioning.BLACKHOLE),
            (controllers.value as List<*>).map { (it as Principal).toString() },
        )
    }

    @Test
    fun staleAccountCodeControllersAndExpiredReviewCannotDispatch() {
        val q = quote(StorageManagementAction.UPGRADE)
        q.validate(owner, 7, bucket, old, 100)
        for (status in
            listOf(
                old.copy(moduleHash = "c".repeat(64)),
                old.copy(expectedHash = "c".repeat(64)),
                old.copy(controllers = listOf(owner, "aaaaa-aa")),
            )) assertThrows(IllegalArgumentException::class.java) {
            q.validate(owner, 7, bucket, status, 101)
        }
        assertThrows(IllegalArgumentException::class.java) {
            q.validate("aaaaa-aa", 7, bucket, old, 101)
        }
        assertThrows(IllegalArgumentException::class.java) {
            q.validate(owner, 8, bucket, old, 101)
        }
        assertThrows(IllegalArgumentException::class.java) {
            q.validate(owner, 7, "aaaaa-aa", old, 101)
        }
        assertThrows(IllegalArgumentException::class.java) {
            q.validate(owner, 7, bucket, old, 120101)
        }
        assertThrows(IllegalArgumentException::class.java) { q.validate(owner, 7, bucket, old, 99) }
    }

    @Test
    fun completedUpgradeRetainsMetricsAndControllers() = runBlocking {
        val p = Port(old)
        val result =
            StorageManagementWorkflow.run(quote(StorageManagementAction.UPGRADE), p) { 101 }
        assertEquals(old.expectedHash, result.moduleHash)
        assertEquals(old.memoryBytes, result.memoryBytes)
        assertEquals(old.controllers, result.controllers)
        assertEquals(listOf("status", "upgrade", "status"), p.calls)
    }

    @Test
    fun lostUpgradeReplyIsReconciledWithoutAnotherUpgrade() = runBlocking {
        val p = Port(old).apply { upgradeFailure = IOException("lost reply") }
        assertTrue(
            StorageManagementWorkflow.run(quote(StorageManagementAction.UPGRADE), p) { 101 }
                .compatible
        )
        assertEquals(1, p.calls.count { it == "upgrade" })
    }

    @Test
    fun unconfirmedUpgradeRetainsFailureAndNeverClaimsSuccessOrRetries() {
        val cause = IOException("unknown result")
        val p =
            Port(old).apply {
                applyUpgrade = false
                upgradeFailure = cause
            }
        val failure =
            assertThrows(IllegalStateException::class.java) {
                runBlocking {
                    StorageManagementWorkflow.run(quote(StorageManagementAction.UPGRADE), p) { 101 }
                }
            }
        assertSame(cause, failure.cause)
        assertTrue(failure.message!!.contains("Nothing was automatically resent"))
        assertEquals(1, p.calls.count { it == "upgrade" })
        assertEquals(old.moduleHash, p.current.moduleHash)
    }

    @Test
    fun changingPublishedCodeCannotBeReportedAsUpToDate() {
        val p = Port(old).apply { publishedAfterUpgrade = "c".repeat(64) }
        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                StorageManagementWorkflow.run(quote(StorageManagementAction.UPGRADE), p) { 101 }
            }
        }
        assertEquals(1, p.calls.count { it == "upgrade" })
    }

    @Test
    fun internalAuthorizationCompletesBeforeManagementGrant() = runBlocking {
        val q = quote(StorageManagementAction.ADD_BLACKHOLE)
        val p = Port(q.snapshot)
        val result = StorageManagementWorkflow.run(q, p) { 101 }
        assertEquals(q.controllers.toSet(), result.controllers.toSet())
        assertEquals(listOf("status", "internal", "status", "management", "status"), p.calls)
    }

    @Test
    fun unknownInternalWriteCannotGrantManagementAccess() {
        val q = quote(StorageManagementAction.ADD_BLACKHOLE)
        val cause = IOException("lost reply")
        val p = Port(q.snapshot).apply { internalFailure = cause }
        val failure =
            assertThrows(IllegalStateException::class.java) {
                runBlocking { StorageManagementWorkflow.run(q, p) { 101 } }
            }
        assertSame(cause, failure.cause)
        assertFalse("management" in p.calls)
        assertEquals(q.snapshot.controllers, p.current.controllers)
    }

    @Test
    fun concurrentControllerChangeStopsBeforeOverwritingIt() {
        val q = quote(StorageManagementAction.ADD_BLACKHOLE)
        val p = Port(q.snapshot).apply { changeAfterInternal = true }
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking { StorageManagementWorkflow.run(q, p) { 101 } }
        }
        assertFalse("management" in p.calls)
        assertTrue("aaaaa-aa" in p.current.controllers)
    }

    @Test
    fun lostManagementGrantReplyIsCheckedWithoutResubmission() = runBlocking {
        val q = quote(StorageManagementAction.ADD_BLACKHOLE)
        val p = Port(q.snapshot).apply { managementFailure = IOException("lost reply") }
        assertEquals(
            q.controllers.toSet(),
            StorageManagementWorkflow.run(q, p) { 101 }.controllers.toSet(),
        )
        assertEquals(1, p.calls.count { it == "internal" })
        assertEquals(1, p.calls.count { it == "management" })
    }

    @Test
    fun cancellationDoesNotSendOrRetryAnotherStage() {
        for (action in StorageManagementAction.entries) {
            val q = quote(action)
            val cancel = CancellationException("cancelled")
            val p =
                Port(q.snapshot).apply {
                    if (action == StorageManagementAction.UPGRADE) upgradeFailure = cancel
                    else internalFailure = cancel
                }
            assertSame(
                cancel,
                assertThrows(CancellationException::class.java) {
                    runBlocking { StorageManagementWorkflow.run(q, p) { 101 } }
                },
            )
            assertEquals(2, p.calls.size)
            assertFalse("management" in p.calls)
        }
    }
}
