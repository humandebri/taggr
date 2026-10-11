package org.taggr.android

import androidx.compose.runtime.saveable.mapSaver

/** Source screen retained while navigating between posts, matching Swift's return route. */
internal data class PostReturnRoute(
    val tab: Int = 0,
    val profile: String? = null,
    val photos: Boolean = false,
    val realm: String? = null,
    val tags: List<String>? = null,
    val search: Boolean = false,
    val transaction: String? = null,
    val proposals: Boolean = false,
    val proposal: Long? = null,
    val bookmarks: Boolean = false,
    val invites: Boolean = false,
) {
    companion object {
        val Saver =
            mapSaver(
                save = {
                    mapOf(
                        "tab" to it.tab,
                        "profile" to it.profile,
                        "photos" to it.photos,
                        "realm" to it.realm,
                        "tags" to it.tags?.let(::ArrayList),
                        "search" to it.search,
                        "transaction" to it.transaction,
                        "proposals" to it.proposals,
                        "proposal" to it.proposal,
                        "bookmarks" to it.bookmarks,
                        "invites" to it.invites,
                    )
                },
                restore = { values ->
                    @Suppress("UNCHECKED_CAST")
                    PostReturnRoute(
                        values["tab"] as Int,
                        values["profile"] as String?,
                        values["photos"] as Boolean,
                        values["realm"] as String?,
                        values["tags"] as List<String>?,
                        values["search"] as Boolean,
                        values["transaction"] as String?,
                        values["proposals"] as Boolean,
                        values["proposal"] as Long?,
                        values["bookmarks"] as Boolean,
                        values["invites"] as Boolean,
                    )
                },
            )
    }
}
