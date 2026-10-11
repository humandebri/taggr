package org.taggr.android.data

import kotlinx.coroutines.CancellationException
import org.ic4j.agent.android.*
import org.ic4j.types.Principal

enum class StorageManagementAction(val title: String, val confirm: String) {
    UPGRADE("Upgrade storage", "Upgrade"),
    ADD_BLACKHOLE("Add Blackhole controller", "Add"),
}

data class StorageManagementQuote(
    val action: StorageManagementAction,
    val owner: String,
    val userId: Long,
    val snapshot: StorageStatus,
    val preparedAtMillis: Long,
) {
    val controllers: List<String>
        get() = (snapshot.controllers + StorageProvisioning.BLACKHOLE).distinct()

    fun validate(owner: String, userId: Long, bucket: String?, current: StorageStatus, now: Long) {
        require(
            owner == this.owner &&
                userId == this.userId &&
                bucket == snapshot.bucket &&
                current.bucket == bucket
        ) {
            "The account or storage changed. Review it again."
        }
        require(now >= preparedAtMillis && now - preparedAtMillis <= 120000) {
            "This confirmation expired. Review storage again."
        }
        require(owner in current.controllers && current.status in listOf("running", "stopped")) {
            "The signed-in principal must control this storage canister."
        }
        require(
            current.moduleHash == snapshot.moduleHash &&
                current.expectedHash == snapshot.expectedHash &&
                current.controllers.toSet() == snapshot.controllers.toSet()
        ) {
            "Storage code or controllers changed. Review it again."
        }
        require(current.expectedHash.matches(Regex("[0-9a-f]{64}")))
        when (action) {
            StorageManagementAction.UPGRADE ->
                require(current.moduleHash != null && !current.compatible) {
                    "Storage is already up to date or has no installed module."
                }
            StorageManagementAction.ADD_BLACKHOLE -> {
                require(current.compatible) { "Upgrade storage before adding a controller." }
                require(StorageProvisioning.BLACKHOLE !in current.controllers) {
                    "Blackhole is already a controller."
                }
                require(
                    controllers.size <= 10 &&
                        StorageManagementWire.internalControllers(controllers).size <= 256
                ) {
                    "This controller list exceeds the storage limit."
                }
            }
        }
    }
}

object StorageManagementWire {
    fun confirmReply(bytes: ByteArray, management: Boolean) {
        val values = Candid.decode(bytes).values
        require(
            if (management) values.isEmpty()
            else
                values.size == 1 &&
                    values.single().type == CandidType.Primitive.NULL &&
                    values.single().value == null
        ) {
            "Invalid storage management reply"
        }
    }

    fun upgradeArguments(bucket: String, owner: String, wasm: VerifiedStorageWasm): ByteArray {
        val mode =
            CandidValue(
                CandidType.Variant(listOf(CandidField("upgrade", CandidType.Primitive.NULL))),
                CandidVariant(Candid.fieldID("upgrade"), null),
            )
        return CandidArguments(
                LedgerWire.record(
                    "mode" to mode,
                    "canister_id" to
                        Candid.principal.encode(
                            Principal.fromString(StorageWire.canonicalBucket(bucket))
                        ),
                    "wasm_module" to Candid.blob.encode(wasm.bytes()),
                    "arg" to Candid.blob.encode(internalControllers(listOf(owner))),
                    "sender_canister_version" to Candid.optional(Candid.nat64).encode(null),
                )
            )
            .encode()
    }

    fun internalControllers(controllers: List<String>): ByteArray {
        require(controllers.isNotEmpty() && controllers.distinct().size == controllers.size)
        return CandidArguments(
                Candid.vector(Candid.principal).encode(controllers.map(Principal::fromString))
            )
            .encode()
    }

    fun settingsArguments(bucket: String, controllers: List<String>): ByteArray {
        internalControllers(controllers)
        require(controllers.size <= 10)
        return CandidArguments(
                LedgerWire.record(
                    "canister_id" to
                        Candid.principal.encode(
                            Principal.fromString(StorageWire.canonicalBucket(bucket))
                        ),
                    "settings" to
                        LedgerWire.record(
                            "controllers" to
                                Candid.optional(Candid.vector(Candid.principal))
                                    .encode(controllers.map(Principal::fromString))
                        ),
                    "sender_canister_version" to Candid.optional(Candid.nat64).encode(null),
                )
            )
            .encode()
    }
}

interface StorageManagementPort {
    suspend fun status(): StorageStatus

    suspend fun upgrade()

    suspend fun synchronizeInternalControllers()

    suspend fun addManagementController()
}

/**
 * Controller changes are additive; initialize bucket authorization before granting management
 * access.
 */
object StorageManagementWorkflow {
    suspend fun run(
        quote: StorageManagementQuote,
        port: StorageManagementPort,
        now: () -> Long,
    ): StorageStatus {
        fun validate(status: StorageStatus) =
            quote.validate(quote.owner, quote.userId, quote.snapshot.bucket, status, now())
        validate(port.status())
        if (quote.action == StorageManagementAction.ADD_BLACKHOLE) {
            // An interrupted internal write is idempotent and leaves the management grant absent.
            try {
                port.synchronizeInternalControllers()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                throw IllegalStateException(
                    "Controller synchronization is unconfirmed. Refresh storage before reviewing again. No management controller was added by this operation.",
                    e,
                )
            }
            validate(port.status())
        }
        var failed: Exception? = null
        try {
            if (quote.action == StorageManagementAction.UPGRADE) port.upgrade()
            else port.addManagementController()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            failed = e
        }
        val current =
            try {
                port.status()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                throw IllegalStateException(
                    "The storage result is unconfirmed. Refresh storage before reviewing again. Nothing was automatically resent.",
                    failed ?: e,
                )
            }
        val expectedControllers =
            if (quote.action == StorageManagementAction.UPGRADE) quote.snapshot.controllers
            else quote.controllers
        if (
            current.bucket != quote.snapshot.bucket ||
                current.moduleHash != quote.snapshot.expectedHash ||
                current.expectedHash != quote.snapshot.expectedHash ||
                current.controllers.toSet() != expectedControllers.toSet() ||
                quote.owner !in current.controllers
        ) {
            throw IllegalStateException(
                "The storage result is unconfirmed. Refresh storage before reviewing again. Nothing was automatically resent.",
                failed,
            )
        }
        return current
    }
}
