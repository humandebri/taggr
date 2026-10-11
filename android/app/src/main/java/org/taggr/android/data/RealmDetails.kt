package org.taggr.android.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.fasterxml.jackson.databind.JsonNode

/** Public Realm presentation data; counts and filter thresholds retain uint64 precision. */
data class RealmDetails(
    val description: String,
    val labelColor: String,
    val logo: String,
    val members: ULong,
    val posts: ULong,
    val penalty: Long,
    val posting: String,
    val comments: String,
    val controllers: List<ULong>,
) {
    companion object {
        fun decode(value: JsonNode): RealmDetails {
            RealmSettings.validateMetadata(value, requireControllers = false)
            val whitelist = value["whitelist"]
            val filter = value["filter"]
            val rules = mutableListOf<String>()
            if (filter["safe"].asBoolean()) rules += "non-controversial users"
            for ((key, label, suffix) in
                listOf(
                    Triple("balance", "balance", ""),
                    Triple("age_days", "account age", " days"),
                    Triple("num_followers", "followers", ""),
                )) {
                val number = WithdrawQuote.unsigned(filter, key)
                if (number > 0uL) rules += "$label ≥ $number$suffix"
            }
            val posting =
                if (!whitelist.isEmpty) "Limited to ${whitelist.size()} approved users"
                else if (rules.isEmpty()) "Open to all members" else rules.joinToString(", ")
            return RealmDetails(
                value["description"].asText(),
                value["label_color"].asText(),
                value["logo"].asText(),
                WithdrawQuote.unsigned(value, "num_members"),
                WithdrawQuote.unsigned(value, "num_posts"),
                value["cleanup_penalty"].asLong(),
                posting,
                if (value["comments_filtering"].asBoolean()) "Realm posting rules apply"
                else "Open to everyone",
                value["controllers"].map { it.asText().toULong() }.distinct(),
            )
        }
    }
}

object RealmLogo {
    const val maximumEncodedBytes = 65536
    const val maximumDecodedSide = 256

    fun sampleSize(width: Int, height: Int): Int {
        require(width in 1..4096 && height in 1..4096) { "Realm logo dimensions are unsupported." }
        var sample = 1
        while ((maxOf(width, height) + sample - 1) / sample > maximumDecodedSide) sample *= 2
        return sample
    }

    fun decode(encoded: String): Bitmap? =
        try {
            require(encoded.isNotEmpty() && encoded.length <= maximumEncodedBytes)
            val bytes = java.util.Base64.getDecoder().decode(encoded)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val sample = sampleSize(bounds.outWidth, bounds.outHeight)
            BitmapFactory.decodeByteArray(
                    bytes,
                    0,
                    bytes.size,
                    BitmapFactory.Options().apply {
                        inSampleSize = sample
                        inPreferredConfig = Bitmap.Config.ARGB_8888
                    },
                )
                ?.also {
                    if (it.width > maximumDecodedSide || it.height > maximumDecodedSide) {
                        it.recycle()
                        error("Realm logo exceeds decoded bounds.")
                    }
                }
        } catch (_: Exception) {
            null
        }
}
