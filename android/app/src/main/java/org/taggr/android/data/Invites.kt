package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import java.math.BigInteger
import java.net.URI
import java.util.Locale

/** Invite budget is a reservation; credits are debited when someone uses the code. */
data class TaggrInvite(
    val code: String,
    val credits: ULong,
    val perUser: ULong,
    val joined: List<Long>,
    val realm: String?,
    val inviter: Long,
) {
    init {
        require(
            code.matches(Regex("[0-9a-f]{10}")) &&
                perUser > 0uL &&
                credits % perUser == 0uL &&
                inviter >= 0 &&
                joined.all { it >= 0 }
        )
    }

    val canStop
        get() = credits > 0uL && joined.isNotEmpty()
}

object Invites {
    fun code(text: String) =
        text.trim().lowercase(Locale.ROOT).also {
            require(it.matches(Regex("[0-9a-f]{10}"))) { "Enter a valid invite code." }
        }

    fun decode(node: JsonNode): List<TaggrInvite> {
        require(node.isArray)
        val rows = node.map { row ->
            require(row.isArray && row.size() == 2 && row[0].isTextual && row[1].isObject)
            val invite = row[1]
            val joined = invite.required("joined_user_ids")
            require(joined.isArray)
            fun id(value: JsonNode): Long {
                require(
                    value.isIntegralNumber &&
                        value.bigIntegerValue().signum() >= 0 &&
                        value.bigIntegerValue().bitLength() <= 63
                )
                return value.asLong()
            }
            val realm =
                invite
                    .required("realm_id")
                    .takeUnless { it.isNull }
                    ?.also { require(it.isTextual) }
                    ?.asText()
            TaggrInvite(
                row[0].asText(),
                WithdrawQuote.unsigned(invite, "credits"),
                WithdrawQuote.unsigned(invite, "credits_per_user"),
                joined.map(::id).distinct(),
                realm,
                id(invite.required("inviter_user_id")),
            )
        }
        require(rows.map { it.code }.distinct().size == rows.size)
        return rows.sortedBy { it.code }
    }

    fun url(code: String, origin: URI): String {
        require(
            code.matches(Regex("[0-9a-fA-F]{10}")) &&
                origin.scheme in listOf("https", "http") &&
                origin.host != null &&
                origin.userInfo == null
        )
        return URI(
                origin.scheme,
                null,
                origin.host,
                origin.port,
                "/",
                null,
                "/welcome/${code.lowercase(Locale.ROOT)}",
            )
            .toASCIIString()
    }

    fun realm(text: String) =
        text.uppercase(Locale.ROOT).replace("/", "").trim().also { require(it.length <= 128) }
}

data class InviteDraft(val credits: ULong, val perUser: ULong, val realm: String) {
    fun validate(
        existing: TaggrInvite?,
        entries: List<TaggrInvite>,
        balance: ULong,
        minimum: ULong,
    ) {
        require(perUser > 0uL && credits % perUser == 0uL) {
            "Total credits must be a multiple of credits per user."
        }
        if (existing == null)
            require(credits > 0uL && perUser >= minimum) {
                "Credits per user must meet the minimum of $minimum."
            }
        else {
            require(existing in entries && perUser == existing.perUser) {
                "This invite changed. Reload it before saving."
            }
            require(credits != 0uL || existing.joined.isNotEmpty()) {
                "An unused invite cannot be stopped by this API."
            }
        }
        val total =
            entries.fold(BigInteger.ZERO) { sum, row -> sum + BigInteger(row.credits.toString()) } +
                BigInteger(credits.toString())
        require(total <= BigInteger(ULong.MAX_VALUE.toString())) { "Invite credits overflow." }
        val reserved = total - BigInteger((existing?.credits ?: 0uL).toString())
        require(reserved <= BigInteger(balance.toString())) {
            "Insufficient credits for the reserved invite budget."
        }
        require(realm == Invites.realm(realm))
    }

    fun arguments(code: String?): ByteArray =
        ObjectMapper()
            .writeValueAsBytes(
                if (code == null)
                    listOf(
                        BigInteger(credits.toString()),
                        BigInteger(perUser.toString()),
                        realm.ifEmpty { null },
                    )
                else listOf(code, BigInteger(credits.toString()), realm.ifEmpty { null })
            )
}

object InviteArguments {
    fun valid(method: String, bytes: ByteArray): Boolean =
        try {
            require(bytes.size <= 1024)
            val row = ObjectMapper().readTree(bytes)
            require(row.isArray && row.size() == 3)
            fun amount(index: Int) =
                row[index]
                    .also {
                        require(
                            it.isIntegralNumber &&
                                it.bigIntegerValue().signum() >= 0 &&
                                it.bigIntegerValue().bitLength() <= 64
                        )
                    }
                    .asText()
                    .toULong()
            if (method == "create_invite") {
                val total = amount(0)
                val each = amount(1)
                require(total > 0uL && each > 0uL && total % each == 0uL)
            } else {
                require(
                    method == "update_invite" &&
                        row[0].isTextual &&
                        row[0].asText().matches(Regex("[0-9a-f]{10}"))
                )
                amount(1)
            }
            require(
                row[2].isNull ||
                    (row[2].isTextual && row[2].asText() == Invites.realm(row[2].asText()))
            )
            true
        } catch (_: Exception) {
            false
        }
}
