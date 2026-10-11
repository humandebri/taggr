package org.taggr.android.data

import android.content.Context
import android.util.AtomicFile
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.security.MessageDigest
import org.ic4j.agent.android.ICPAccountIdentifier

/** A certified invoice reply retained before its pending request can be cleared. */
data class CreditInvoiceReceipt(
    val owner: String,
    val network: String,
    val canister: String,
    val invoice: ICPInvoice,
    val requestId: ByteArray,
    val receivedAtMillis: Long,
) {
    init {
        require(network.matches(Regex("[0-9a-f]{64}")) && requestId.size == 32)
        require(receivedAtMillis >= 0 && invoice.amountE8s > 0uL)
        val expectedAccount =
            try {
                DraftImages.hex(ICPAccountIdentifier.account(canister, owner))
            } catch (e: org.ic4j.types.PrincipalError) {
                throw IllegalArgumentException(
                    "Invalid invoice signing principal or TAGGR canister.",
                    e,
                )
            }
        require(invoice.account == expectedAccount) {
            "The invoice recipient does not match this account and TAGGR network."
        }
        require(
            if (invoice.paid) invoice.paidE8s >= invoice.amountE8s else invoice.paidE8s == 0uL
        ) {
            "Invalid invoice payment status."
        }
    }
}

object CreditInvoiceCodec {
    private val mapper = ObjectMapper()

    fun encode(value: CreditInvoiceReceipt): ByteArray =
        mapper.writeValueAsBytes(
            mapOf(
                "owner" to value.owner,
                "network" to value.network,
                "canister" to value.canister,
                "requestId" to DraftImages.hex(value.requestId),
                "receivedAtMillis" to value.receivedAtMillis,
                "invoice" to
                    mapOf(
                        "e8s" to java.math.BigInteger(value.invoice.amountE8s.toString()),
                        "paid_e8s" to java.math.BigInteger(value.invoice.paidE8s.toString()),
                        "paid" to value.invoice.paid,
                        "account" to
                            ICPAccountIdentifier.parse(value.invoice.account).map {
                                it.toInt() and 255
                            },
                    ),
            )
        )

    fun decode(bytes: ByteArray): CreditInvoiceReceipt {
        require(bytes.size <= 4096)
        val row = mapper.readTree(bytes)
        fun text(name: String) = row.required(name).also { require(it.isTextual) }.asText()
        val request = text("requestId")
        require(request.matches(Regex("[0-9a-f]{64}")))
        val time = row.required("receivedAtMillis")
        require(time.isIntegralNumber && time.canConvertToLong() && time.asLong() >= 0)
        return CreditInvoiceReceipt(
            text("owner"),
            text("network"),
            text("canister"),
            ICPInvoice.decode(row.required("invoice")),
            request.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
            time.asLong(),
        )
    }
}

class CreditInvoiceStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "taggr-credit-invoices")

    private fun file(owner: String, network: String) =
        AtomicFile(
            File(
                root,
                DraftImages.hex(
                    MessageDigest.getInstance("SHA-256").digest("$network/$owner".toByteArray())
                ) + ".json",
            )
        )

    fun save(value: CreditInvoiceReceipt) =
        synchronized(gate) {
            check(root.mkdirs() || root.isDirectory)
            val target = file(value.owner, value.network)
            val stream = target.startWrite()
            try {
                stream.write(CreditInvoiceCodec.encode(value))
                target.finishWrite(stream)
            } catch (e: Exception) {
                target.failWrite(stream)
                throw e
            }
        }

    fun load(owner: String, network: String, canister: String): CreditInvoiceReceipt? =
        synchronized(gate) {
            val target = file(owner, network)
            val backup = File(target.baseFile.path + ".bak")
            if (!target.baseFile.exists() && !backup.exists()) return@synchronized null
            require(target.baseFile.length() <= 4096 && backup.length() <= 4096)
            CreditInvoiceCodec.decode(target.readFully()).also {
                require(it.owner == owner && it.network == network && it.canister == canister)
            }
        }

    companion object {
        private val gate = Any()
    }
}
