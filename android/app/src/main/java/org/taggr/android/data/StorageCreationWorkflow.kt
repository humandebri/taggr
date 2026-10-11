package org.taggr.android.data

/** Each callback commits the signed request before its backend may dispatch it. */
interface StorageCreationBackend {
    suspend fun validateAccount(row: StorageCreationRecord)

    suspend fun fund(row: StorageCreationRecord, persist: (StorageCreationRecord) -> Unit): ULong

    suspend fun paymentResult(payment: PendingTransfer): ULong?

    suspend fun create(row: StorageCreationRecord, persist: (ByteArray) -> Unit): String

    suspend fun status(bucket: String): StorageStatus

    suspend fun installCanRetry(row: StorageCreationRecord): Boolean

    suspend fun module(): VerifiedStorageWasm

    suspend fun install(bucket: String, wasm: VerifiedStorageWasm, persist: (ByteArray) -> Unit)

    suspend fun register(row: StorageCreationRecord, persist: (ByteArray) -> Unit)
}

class StorageCreationWorkflow(private val backend: StorageCreationBackend) {
    suspend fun resume(
        initial: StorageCreationRecord,
        persist: (StorageCreationRecord, StorageCreationRecord) -> Unit,
    ): StorageCreationRecord {
        var row = initial
        fun save(next: StorageCreationRecord) {
            persist(row, next)
            row = next
        }
        require(row.failure == null) {
            "Review the confirmed creation failure before preparing another payment."
        }
        backend.validateAccount(row)
        if (row.block == null) {
            val block =
                try {
                    if (row.payment == null) backend.fund(row) { save(it) }
                    else
                        backend.paymentResult(row.payment!!)
                            ?: error(
                                "The storage payment result is unavailable. No payment was resent."
                            )
                } catch (e: TransferRejected) {
                    if (row.payment != null)
                        save(
                            row.copy(
                                failure =
                                    StorageCreationFailure(
                                        StorageCreationFailureKind.PAYMENT_REJECTED,
                                        (e.message ?: "Payment rejected").take(4096),
                                    )
                            )
                        )
                    throw e
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                    if (row.payment == null) throw e
                    throw IllegalStateException(
                        "The storage payment result is unknown. Use Check and continue before making another payment. Nothing was automatically resent.",
                        e,
                    )
                }
            save(row.paymentConfirmed(block))
        }
        if (row.bucket == null) {
            // CMC caches creation results by ledger block; retries use exactly the paid block.
            val bucket =
                try {
                    backend.create(row) { save(row.withCMCRequest(it)) }
                } catch (e: CMCFailure) {
                    if (e.kind == "Refunded")
                        save(
                            row.copy(
                                failure =
                                    StorageCreationFailure(
                                        StorageCreationFailureKind.CMC_REFUNDED,
                                        (e.message ?: "Creation failed").take(4096),
                                        e.refundBlock,
                                    )
                            )
                        )
                    throw e
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
                    if (row.cmcRequests.isEmpty()) throw e
                    throw IllegalStateException(
                        "The canister creation result is unknown. Use Check and continue with the recorded payment. No new ICP payment will be sent.",
                        e,
                    )
                }
            save(row.created(bucket))
        }
        if (!row.installed) {
            val status = backend.status(row.bucket!!)
            require(status.expectedHash == row.quote.moduleHash) {
                "The approved storage module changed. Keep this record and review the created canister."
            }
            require(row.quote.transfer.owner in status.controllers) {
                "Storage controllers changed."
            }
            if (status.moduleHash != row.quote.moduleHash) {
                require(status.moduleHash == null) {
                    "Different storage code is installed. Nothing was overwritten."
                }
                require(row.installRequests.isEmpty() || backend.installCanRetry(row)) {
                    "The install result is unavailable. Check again before retrying installation."
                }
                val wasm = backend.module()
                require(wasm.hash == row.quote.moduleHash)
                backend.install(row.bucket!!, wasm) { save(row.withInstallRequest(it)) }
            }
            backend.status(row.bucket!!).also {
                require(it.expectedHash == row.quote.moduleHash)
                it.requireUsable(row.quote.transfer.owner)
            }
            save(row.installed(row.quote.moduleHash))
        }
        if (!row.registered) {
            backend.register(row) { save(row.withRegistrationRequest(it)) }
            save(row.registered(row.bucket!!))
        }
        return row
    }
}
