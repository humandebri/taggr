package org.taggr.android.data

/** Same reverse history patch as iOS TaggrEditPatch: new body -> previous body. */
object EditPatch {
    private val header = Regex("@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@")

    fun apply(patchText: String, text: String): String {
        val lines = patchText.split('\n')
        var index = 0
        var result = text
        var count = 0
        fun range(raw: String, rawLength: String): Pair<Int, Int> {
            val start = raw.toIntOrNull() ?: error("The post edit history could not be decoded.")
            val length =
                if (rawLength.isEmpty()) 1
                else rawLength.toIntOrNull() ?: error("The post edit history could not be decoded.")
            val offset = if (length == 0) start else start - 1
            require(offset >= 0 && length >= 0) { "The post edit history could not be decoded." }
            return offset to length
        }
        while (index < lines.size) {
            if (lines[index].isEmpty()) {
                index++
                continue
            }
            val match =
                header.matchEntire(lines[index++])
                    ?: error("The post edit history could not be decoded.")
            val sourceRange = range(match.groupValues[1], match.groupValues[2])
            val destination = range(match.groupValues[3], match.groupValues[4])
            val source = StringBuilder()
            val replacement = StringBuilder()
            while (index < lines.size && !lines[index].startsWith("@@ ")) {
                val line = lines[index++]
                if (line.isEmpty() && index == lines.size) break
                require(line.isNotEmpty() && line[0] in " -+") {
                    "The post edit history could not be decoded."
                }
                val decoded = unescape(line.substring(1))
                if (line[0] != '+') source.append(decoded)
                if (line[0] != '-') replacement.append(decoded)
            }
            require(source.length == sourceRange.second) {
                "The post edit history could not be decoded."
            }
            val begin = destination.first
            val end = begin.toLong() + sourceRange.second
            require(
                end <= result.length &&
                    boundary(result, begin) &&
                    boundary(result, end.toInt()) &&
                    result.substring(begin, end.toInt()) == source.toString()
            ) {
                "The post edit history does not match the current post body."
            }
            result = result.replaceRange(begin, end.toInt(), replacement.toString())
            count++
        }
        require(count > 0) { "The post edit history could not be decoded." }
        return result
    }

    private fun boundary(text: String, offset: Int) =
        offset in 0..text.length &&
            !(offset > 0 &&
                offset < text.length &&
                Character.isHighSurrogate(text[offset - 1]) &&
                Character.isLowSurrogate(text[offset]))

    private fun unescape(text: String): String {
        val bytes = java.io.ByteArrayOutputStream()
        var index = 0
        while (index < text.length) {
            if (text[index] == '%') {
                require(index + 2 < text.length) { "The post edit history could not be decoded." }
                require(
                    text[index + 1] in "0123456789abcdefABCDEF" &&
                        text[index + 2] in "0123456789abcdefABCDEF"
                ) {
                    "The post edit history could not be decoded."
                }
                val high = text[index + 1].digitToIntOrNull(16)
                val low = text[index + 2].digitToIntOrNull(16)
                require(high != null && low != null) {
                    "The post edit history could not be decoded."
                }
                bytes.write(high * 16 + low)
                index += 3
            } else {
                val next = text.indexOf('%', index).let { if (it < 0) text.length else it }
                bytes.write(text.substring(index, next).toByteArray(Charsets.UTF_8))
                index = next
            }
        }
        return Charsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(bytes.toByteArray()))
            .toString()
    }

    private const val allowed =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'();/?:@&=+$,# "

    fun fullReplacement(newText: String, previousText: String): String = buildString {
        append("@@ -${range(newText)} +${range(previousText)} @@\n")
        if (newText.isNotEmpty()) append("-${escape(newText)}\n")
        if (previousText.isNotEmpty()) append("+${escape(previousText)}\n")
    }

    private fun range(text: String): String =
        when (text.length) {
            0 -> "0,0"
            1 -> "1"
            else -> "1,${text.length}"
        }

    private fun escape(text: String): String = buildString {
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            val value = byte.toInt() and 255
            if (value < 128 && value.toChar() in allowed) append(value.toChar())
            else {
                append('%')
                append("0123456789ABCDEF"[value ushr 4])
                append("0123456789ABCDEF"[value and 15])
            }
        }
    }
}
