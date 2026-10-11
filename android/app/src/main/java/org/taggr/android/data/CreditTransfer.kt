package org.taggr.android.data

import com.fasterxml.jackson.databind.DeserializationFeature
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper

/** The backend consumes raw JSON [UserId, Credits], both unsigned integers. */
data class CreditTransferQuote(
    val owner: String,
    val senderId: Long,
    val recipientId: Long,
    val recipientName: String,
    val amount: ULong,
    val fee: ULong,
    val network: String,
    val preparedAtMillis: Long,
) {
    init {
        require(
            owner.isNotBlank() &&
                senderId in 0 until 9007199254740991L &&
                recipientId in 0 until 9007199254740991L &&
                senderId != recipientId &&
                recipientName.isNotBlank()
        )
        total(amount, fee)
    }

    val total: ULong
        get() = total(amount, fee)

    fun arguments(): ByteArray = arguments(recipientId, amount)

    fun validate(user: JsonNode, recipient: JsonNode, currentFee: ULong, nowMillis: Long) {
        require(nowMillis >= preparedAtMillis && nowMillis - preparedAtMillis <= 120000) {
            "This confirmation expired. Review the credit transfer again."
        }
        require(
            user.path("id").isIntegralNumber &&
                user.path("id").canConvertToLong() &&
                user.path("id").asLong(-1) == senderId &&
                recipient.path("id").isIntegralNumber &&
                recipient.path("id").canConvertToLong() &&
                recipient.path("id").asLong(-1) == recipientId &&
                recipient.path("name").asText() == recipientName
        ) {
            "The sender or recipient changed. Review the credit transfer again."
        }
        require(fee == currentFee) { "The fee changed. Review the credit transfer again." }
        require(total <= WithdrawQuote.unsigned(user, "cycles")) {
            "Insufficient credits including the fee."
        }
    }

    companion object {
        private val mapper = ObjectMapper().enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)

        fun parse(text: String): ULong? =
            text
                .trim()
                .takeIf { it.isNotEmpty() && it.all { char -> char in '0'..'9' } }
                ?.toULongOrNull()
                ?.takeIf { it > 0uL }

        fun total(amount: ULong, fee: ULong): ULong {
            require(amount > 0uL && amount <= ULong.MAX_VALUE - fee) {
                "Invalid credit amount including the fee."
            }
            return amount + fee
        }

        fun arguments(recipient: Long, amount: ULong): ByteArray {
            require(recipient in 0 until 9007199254740991L && amount > 0uL)
            return mapper.writeValueAsBytes(listOf(recipient, amount.toString().toBigInteger()))
        }

        fun validArguments(bytes: ByteArray): Boolean = runCatching {
            val row = mapper.readTree(bytes)
            require(
                row.isArray &&
                    row.size() == 2 &&
                    row[0].isIntegralNumber &&
                    row[0].canConvertToLong()
            )
            val value = row[1]
            require(
                value.isIntegralNumber &&
                    value.bigIntegerValue().signum() > 0 &&
                    value.bigIntegerValue().bitLength() <= 64
            )
            bytes.contentEquals(arguments(row[0].asLong(), value.asText().toULong()))
        }
            .getOrDefault(false)
    }
}
