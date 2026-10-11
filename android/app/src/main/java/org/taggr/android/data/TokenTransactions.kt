package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import java.math.BigInteger
import java.util.zip.CRC32
import org.ic4j.agent.android.*
import org.ic4j.types.Principal

/** ICRC textual account, using the same owner-plus-subaccount checksum as Swift. */
data class TokenAccount(val owner: String, val subaccount: String = "0".repeat(64)) {
    init {
        require(canonical(owner) == owner && subaccount.matches(Regex("[0-9a-f]{64}")))
    }

    val bytes
        get() = subaccount.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    val address
        get() =
            if (bytes.all { it == 0.toByte() }) owner
            else "$owner-${checksum(owner, bytes)}.${subaccount.trimStart('0')}"

    companion object {
        fun canonical(text: String): String =
            try {
                Principal.fromString(text).toString()
            } catch (e: org.ic4j.types.PrincipalError) {
                throw IllegalArgumentException("Invalid account Principal.", e)
            } catch (e: Exception) {
                throw IllegalArgumentException("Invalid account Principal.", e)
            }

        fun parse(text: String): TokenAccount {
            val parts = text.trim().split('.')
            require(parts.size in 1..2 && parts[0].isNotEmpty()) { "Invalid token account." }
            if (parts.size == 1) return TokenAccount(canonical(parts[0]))
            val head = parts[0]
            val separator = head.lastIndexOf('-')
            require(separator > 0 && parts[1].matches(Regex("[0-9a-fA-F]{1,64}"))) {
                "Invalid token subaccount."
            }
            val result =
                TokenAccount(
                    canonical(head.substring(0, separator)),
                    parts[1].lowercase().padStart(64, '0'),
                )
            require(checksum(result.owner, result.bytes) == head.substring(separator + 1)) {
                "Invalid token account checksum."
            }
            return result
        }

        internal fun checksum(owner: String, bytes: ByteArray): String {
            require(bytes.size == 32)
            val crc =
                CRC32()
                    .apply {
                        update(Principal.fromString(owner).value)
                        update(bytes)
                    }
                    .value shl 3
            val alphabet = "abcdefghijklmnopqrstuvwxyz234567"
            return (30 downTo 0 step 5)
                .map { alphabet[((crc ushr it) and 31).toInt()] }
                .joinToString("")
        }

        fun decode(node: JsonNode): TokenAccount {
            require(node.isObject && node.path("owner").isTextual)
            val sub = node.required("subaccount")
            return TokenAccount(
                canonical(node["owner"].asText()),
                if (sub.isNull) "0".repeat(64)
                else
                    DraftImages.hex(
                        TokenTransactions.bytes(sub, 32).also { require(it.size == 32) }
                    ),
            )
        }
    }
}

data class TokenTransaction(
    val id: Long,
    val from: TokenAccount,
    val to: TokenAccount,
    val amount: ULong,
    val fee: ULong,
    val timestamp: ULong,
    val memo: String?,
)

data class TokenAccountSummary(val balance: BigInteger, val decimals: Int, val symbol: String) {
    init {
        require(
            balance.signum() >= 0 &&
                decimals in 0..255 &&
                symbol.isNotBlank() &&
                symbol.length <= 32
        )
    }
}

object TokenTransactions {
    fun bytes(node: JsonNode, maximum: Int): ByteArray {
        require(
            node.isArray &&
                node.size() <= maximum &&
                node.all {
                    it.isIntegralNumber &&
                        it.bigIntegerValue().signum() >= 0 &&
                        it.bigIntegerValue() <= BigInteger.valueOf(255)
                }
        ) {
            "Invalid transaction bytes."
        }
        return node.map { it.asInt().toByte() }.toByteArray()
    }

    fun decode(node: JsonNode): List<TokenTransaction> {
        require(node.isArray && node.size() <= 1000) { "Invalid transaction page." }
        val result = node.map { entry ->
            require(
                entry.isArray &&
                    entry.size() == 2 &&
                    entry[0].isIntegralNumber &&
                    entry[0].bigIntegerValue().signum() >= 0 &&
                    entry[0].bigIntegerValue().bitLength() <= 32
            )
            val tx = entry[1]
            require(tx.isObject)
            val memo = tx.required("memo")
            TokenTransaction(
                entry[0].asLong(),
                TokenAccount.decode(tx.required("from")),
                TokenAccount.decode(tx.required("to")),
                WithdrawQuote.unsigned(tx, "amount"),
                WithdrawQuote.unsigned(tx, "fee"),
                WithdrawQuote.unsigned(tx, "timestamp"),
                if (memo.isNull) null else DraftImages.hex(bytes(memo, 1024)),
            )
        }
        require(result.map { it.id }.distinct().size == result.size) {
            "Duplicate transaction IDs."
        }
        return result
    }

    fun balanceArguments(account: TokenAccount) =
        CandidArguments(
                LedgerWire.record(
                    "owner" to Candid.principal.encode(Principal.fromString(account.owner)),
                    "subaccount" to Candid.optional(Candid.blob).encode(account.bytes),
                )
            )
            .encode()

    fun balanceReply(bytes: ByteArray): BigInteger {
        val decoded = Candid.decode(bytes).values.single()
        require(decoded.type == CandidType.Primitive.NAT)
        return (decoded.value as BigInteger).also { require(it.signum() >= 0) }
    }
}
