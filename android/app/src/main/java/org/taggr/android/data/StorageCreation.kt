package org.taggr.android.data

import android.content.Context
import android.util.AtomicFile
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/** Immutable approval: the signing identity is also the CMC payment's controller. */
data class StorageCreationQuote(
    val userId: Long,
    val taggr: String,
    val network: String,
    val transfer: TransferQuote,
    val moduleHash: String,
) {
    init {
        require(
            userId >= 0 &&
                network.matches(Regex("[0-9a-f]{64}")) &&
                moduleHash.matches(Regex("[0-9a-f]{64}"))
        )
        require(StorageWire.canonicalBucket(taggr) == taggr)
        require(
            transfer.recipient ==
                DraftImages.hex(StorageProvisioning.creationAccount(transfer.owner))
        )
        require(transfer.amount > transfer.fee)
    }
}

enum class StorageCreationPhase {
    PREPARED,
    PAYMENT_PENDING,
    PAID,
    CREATING,
    CREATED,
    INSTALLING,
    INSTALLED,
    REGISTERING,
    COMPLETE,
    FAILED,
}

enum class StorageCreationFailureKind {
    PAYMENT_REJECTED,
    CMC_REFUNDED,
}

data class StorageCreationFailure(
    val kind: StorageCreationFailureKind,
    val reason: String,
    val refundBlock: ULong? = null,
) {
    init {
        require(reason.length <= 4096)
        require(kind == StorageCreationFailureKind.CMC_REFUNDED || refundBlock == null)
    }
}

/** A single durable row retains the payment and every stage's request IDs. */
data class StorageCreationRecord(
    val quote: StorageCreationQuote,
    val id: String = UUID.randomUUID().toString(),
    val payment: PendingTransfer? = null,
    val block: ULong? = null,
    val bucket: String? = null,
    val cmcRequests: List<ByteArray> = emptyList(),
    val installRequests: List<ByteArray> = emptyList(),
    val registrationRequests: List<ByteArray> = emptyList(),
    val installed: Boolean = false,
    val registered: Boolean = false,
    val failure: StorageCreationFailure? = null,
) {
    init {
        UUID.fromString(id)
        require(
            payment == null ||
                (payment.quote == quote.transfer && payment.memo == StorageProvisioning.CREATE_MEMO)
        )
        require(block == null || payment != null)
        require(
            bucket == null ||
                (block != null &&
                    cmcRequests.isNotEmpty() &&
                    StorageWire.canonicalBucket(bucket) == bucket)
        )
        require(cmcRequests.isEmpty() || block != null)
        require(installRequests.isEmpty() || bucket != null)
        require(!installed || bucket != null)
        require(registrationRequests.isEmpty() || installed)
        require(!registered || installed)
        failure?.let {
            require(payment != null && bucket == null && !installed && !registered)
            when (it.kind) {
                StorageCreationFailureKind.PAYMENT_REJECTED ->
                    require(block == null && cmcRequests.isEmpty())
                StorageCreationFailureKind.CMC_REFUNDED ->
                    require(block != null && cmcRequests.isNotEmpty())
            }
        }
        for (ids in listOf(cmcRequests, installRequests, registrationRequests)) {
            require(ids.size <= 32 && ids.all { it.size == 32 })
            require(ids.map { Base64.getEncoder().encodeToString(it) }.distinct().size == ids.size)
        }
    }

    val phase
        get() =
            when {
                failure != null -> StorageCreationPhase.FAILED
                registered -> StorageCreationPhase.COMPLETE
                registrationRequests.isNotEmpty() -> StorageCreationPhase.REGISTERING
                installed -> StorageCreationPhase.INSTALLED
                installRequests.isNotEmpty() -> StorageCreationPhase.INSTALLING
                bucket != null -> StorageCreationPhase.CREATED
                cmcRequests.isNotEmpty() -> StorageCreationPhase.CREATING
                block != null -> StorageCreationPhase.PAID
                payment != null -> StorageCreationPhase.PAYMENT_PENDING
                else -> StorageCreationPhase.PREPARED
            }

    fun withPayment(value: PendingTransfer): StorageCreationRecord {
        require(payment == null)
        return copy(payment = value)
    }

    fun paymentConfirmed(value: ULong): StorageCreationRecord {
        require(payment != null && (block == null || block == value))
        return copy(block = value)
    }

    fun withCMCRequest(value: ByteArray): StorageCreationRecord {
        require(block != null && bucket == null)
        return copy(cmcRequests = cmcRequests + value.clone())
    }

    fun created(value: String): StorageCreationRecord {
        require(block != null && cmcRequests.isNotEmpty() && (bucket == null || bucket == value))
        return copy(bucket = value)
    }

    fun withInstallRequest(value: ByteArray): StorageCreationRecord {
        require(bucket != null && !installed)
        return copy(installRequests = installRequests + value.clone())
    }

    fun installed(hash: String): StorageCreationRecord {
        require(bucket != null && hash == quote.moduleHash)
        return copy(installed = true)
    }

    fun withRegistrationRequest(value: ByteArray): StorageCreationRecord {
        require(installed && !registered)
        return copy(registrationRequests = registrationRequests + value.clone())
    }

    fun registered(value: String): StorageCreationRecord {
        require(installed && value == bucket)
        return copy(registered = true)
    }

    fun withPaymentReplay(value: ByteArray): StorageCreationRecord {
        require(payment != null && block == null)
        return copy(
            payment = payment.copy(replayRequestIds = payment.replayRequestIds + value.clone())
        )
    }
}

object StorageCreationCodec {
    private val mapper = ObjectMapper()

    private fun ids(values: List<ByteArray>) = values.map { Base64.getEncoder().encodeToString(it) }

    fun encode(row: StorageCreationRecord): ByteArray {
        val transfer = row.quote.transfer
        return mapper.writeValueAsBytes(
            linkedMapOf(
                "version" to 1,
                "id" to row.id,
                "owner" to transfer.owner,
                "network" to row.quote.network,
                "taggr" to row.quote.taggr,
                "userId" to row.quote.userId,
                "ledgerNetwork" to transfer.network,
                "recipient" to transfer.recipient,
                "amount" to transfer.amount.toString(),
                "fee" to transfer.fee.toString(),
                "preparedAtMillis" to transfer.preparedAtMillis,
                "moduleHash" to row.quote.moduleHash,
                "payment" to
                    row.payment?.let {
                        linkedMapOf(
                            "requestId" to Base64.getEncoder().encodeToString(it.requestId),
                            "createdAtNanos" to it.createdAtNanos.toString(),
                            "memo" to it.memo.toString(),
                            "replays" to ids(it.replayRequestIds),
                        )
                    },
                "block" to row.block?.toString(),
                "bucket" to row.bucket,
                "cmcRequests" to ids(row.cmcRequests),
                "installRequests" to ids(row.installRequests),
                "registrationRequests" to ids(row.registrationRequests),
                "installed" to row.installed,
                "registered" to row.registered,
                "failure" to
                    row.failure?.let {
                        linkedMapOf(
                            "kind" to it.kind.name,
                            "reason" to it.reason,
                            "refundBlock" to it.refundBlock?.toString(),
                        )
                    },
            )
        )
    }

    fun decode(bytes: ByteArray, owner: String, network: String): StorageCreationRecord {
        require(bytes.size <= 32768)
        val node = mapper.readTree(bytes)
        require(
            node.required("version").asInt() == 1 &&
                node.required("owner").asText() == owner &&
                node.required("network").asText() == network
        )
        fun text(name: String) = node.required(name).also { require(it.isTextual) }.asText()
        fun long(name: String) =
            node
                .required(name)
                .also { require(it.isIntegralNumber && it.bigIntegerValue().bitLength() <= 63) }
                .asLong()
        fun list(value: JsonNode): List<ByteArray> {
            require(value.isArray && value.size() <= 32)
            return value.map {
                Base64.getDecoder().decode(it.also { require(it.isTextual) }.asText())
            }
        }
        fun flag(name: String) = node.required(name).also { require(it.isBoolean) }.asBoolean()
        val transfer =
            TransferQuote(
                owner,
                text("ledgerNetwork"),
                text("recipient"),
                text("amount").toULong(),
                text("fee").toULong(),
                long("preparedAtMillis"),
            )
        val quote =
            StorageCreationQuote(
                long("userId"),
                text("taggr"),
                network,
                transfer,
                text("moduleHash"),
            )
        val pending =
            node
                .required("payment")
                .takeUnless { it.isNull }
                ?.let {
                    PendingTransfer(
                        transfer,
                        Base64.getDecoder().decode(it.required("requestId").asText()),
                        it.required("createdAtNanos").asText().toULong(),
                        it.required("memo").asText().toULong(),
                        list(it.required("replays")),
                    )
                }
        return StorageCreationRecord(
            quote,
            text("id"),
            pending,
            node.required("block").takeUnless { it.isNull }?.asText()?.toULong(),
            node.required("bucket").takeUnless { it.isNull }?.asText(),
            list(node.required("cmcRequests")),
            list(node.required("installRequests")),
            list(node.required("registrationRequests")),
            flag("installed"),
            flag("registered"),
            node
                .get("failure")
                ?.takeUnless { it.isNull }
                ?.let {
                    require(
                        it.isObject &&
                            it.required("kind").isTextual &&
                            it.required("reason").isTextual
                    )
                    val refund =
                        it.required("refundBlock")
                            .takeUnless { it.isNull }
                            ?.also { require(it.isTextual) }
                            ?.asText()
                            ?.toULong()
                    StorageCreationFailure(
                        StorageCreationFailureKind.valueOf(it["kind"].asText()),
                        it["reason"].asText(),
                        refund,
                    )
                },
        )
    }
}

class StorageCreationStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "taggr-storage-creation")

    private fun file(owner: String, network: String) =
        AtomicFile(
            File(
                root,
                DraftImages.hex(
                    MessageDigest.getInstance("SHA-256").digest("$network/$owner".toByteArray())
                ) + ".json",
            )
        )

    fun load(owner: String, network: String): StorageCreationRecord? =
        synchronized(gate) {
            val target = file(owner, network)
            val backup = File(target.baseFile.path + ".bak")
            if (!target.baseFile.exists() && !backup.exists()) return@synchronized null
            require(target.baseFile.length() <= 32768 && backup.length() <= 32768)
            StorageCreationCodec.decode(target.readFully(), owner, network)
        }

    fun create(value: StorageCreationRecord) =
        synchronized(gate) {
            require(load(value.quote.transfer.owner, value.quote.network) == null)
            require(value.phase == StorageCreationPhase.PREPARED)
            write(value)
        }

    fun update(expected: StorageCreationRecord, value: StorageCreationRecord) =
        synchronized(gate) {
            require(expected.failure == null)
            require(expected.id == value.id && expected.quote == value.quote)
            val current =
                load(expected.quote.transfer.owner, expected.quote.network)
                    ?: error("Storage creation record is missing")
            require(
                StorageCreationCodec.encode(current)
                    .contentEquals(StorageCreationCodec.encode(expected))
            ) {
                "Storage creation changed. Reload its progress."
            }
            require(value.phase.ordinal >= expected.phase.ordinal)
            require(expected.block == null || expected.block == value.block)
            require(expected.bucket == null || expected.bucket == value.bucket)
            require(
                expected.payment == null ||
                    (value.payment != null &&
                        value.payment.quote == expected.payment.quote &&
                        value.payment.memo == expected.payment.memo &&
                        value.payment.createdAtNanos == expected.payment.createdAtNanos &&
                        value.payment.allRequestIds.size >= expected.payment.allRequestIds.size &&
                        expected.payment.allRequestIds.zip(value.payment.allRequestIds).all { (a, b)
                            ->
                            a.contentEquals(b)
                        })
            )
            for ((old, next) in
                listOf(
                    expected.cmcRequests to value.cmcRequests,
                    expected.installRequests to value.installRequests,
                    expected.registrationRequests to value.registrationRequests,
                )) require(
                next.size >= old.size && old.zip(next).all { (a, b) -> a.contentEquals(b) }
            )
            write(value)
        }

    private fun write(value: StorageCreationRecord) {
        check(root.mkdirs() || root.isDirectory)
        val bytes = StorageCreationCodec.encode(value)
        require(bytes.size <= 32768)
        val target = file(value.quote.transfer.owner, value.quote.network)
        val stream = target.startWrite()
        try {
            stream.write(bytes)
            target.finishWrite(stream)
        } catch (e: Exception) {
            target.failWrite(stream)
            throw e
        }
    }

    fun clearCompleted(expected: StorageCreationRecord) =
        synchronized(gate) {
            require(expected.registered)
            val current =
                load(expected.quote.transfer.owner, expected.quote.network) ?: return@synchronized
            require(
                StorageCreationCodec.encode(current)
                    .contentEquals(StorageCreationCodec.encode(expected))
            )
            val target = file(expected.quote.transfer.owner, expected.quote.network)
            target.delete()
            check(!target.baseFile.exists() && !File(target.baseFile.path + ".bak").exists())
        }

    fun discardUnpaid(expected: StorageCreationRecord) =
        synchronized(gate) {
            require(expected.payment == null)
            val current =
                load(expected.quote.transfer.owner, expected.quote.network) ?: return@synchronized
            require(
                StorageCreationCodec.encode(current)
                    .contentEquals(StorageCreationCodec.encode(expected))
            )
            val target = file(expected.quote.transfer.owner, expected.quote.network)
            target.delete()
            check(!target.baseFile.exists() && !File(target.baseFile.path + ".bak").exists())
        }

    private fun receiptDirectory(owner: String, network: String) =
        File(root, "receipts/${file(owner, network).baseFile.name.removeSuffix(".json")}")

    fun acknowledgeFailure(expected: StorageCreationRecord) =
        synchronized(gate) {
            require(expected.failure != null)
            val current =
                load(expected.quote.transfer.owner, expected.quote.network)
                    ?: error("Creation record is missing")
            val bytes = StorageCreationCodec.encode(expected)
            require(StorageCreationCodec.encode(current).contentEquals(bytes)) {
                "Creation result changed. Reload it."
            }
            val directory = receiptDirectory(expected.quote.transfer.owner, expected.quote.network)
            check(directory.mkdirs() || directory.isDirectory)
            val receipt = AtomicFile(File(directory, "${expected.id}.json"))
            if (receipt.baseFile.exists() || File(receipt.baseFile.path + ".bak").exists()) {
                require(receipt.readFully().contentEquals(bytes))
            } else {
                val stream = receipt.startWrite()
                try {
                    stream.write(bytes)
                    receipt.finishWrite(stream)
                } catch (e: Exception) {
                    receipt.failWrite(stream)
                    throw e
                }
            }
            // Commit the receipt first. A crash before deleting leaves the same failed record
            // recoverable.
            val target = file(expected.quote.transfer.owner, expected.quote.network)
            target.delete()
            check(!target.baseFile.exists() && !File(target.baseFile.path + ".bak").exists())
        }

    fun latestFailureReceipt(owner: String, network: String): StorageCreationRecord? =
        synchronized(gate) {
            val entry =
                receiptDirectory(owner, network)
                    .listFiles()
                    ?.filter { it.name.endsWith(".json") }
                    ?.maxByOrNull { it.lastModified() } ?: return@synchronized null
            require(entry.length() <= 32768)
            StorageCreationCodec.decode(AtomicFile(entry).readFully(), owner, network).also {
                require(it.failure != null)
            }
        }

    companion object {
        private val gate = Any()
    }
}
