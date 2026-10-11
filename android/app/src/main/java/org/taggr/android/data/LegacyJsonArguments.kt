package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper

/** TAGGR legacy tuple convention, identical to Swift TaggrCandid.jsonArguments. */
object LegacyJsonArguments {
    private val mapper = ObjectMapper()

    fun encode(arguments: List<Any?>): ByteArray =
        mapper.writeValueAsBytes(
            when (arguments.size) {
                0 -> null
                1 -> arguments[0]
                else -> arguments
            }
        )
}
