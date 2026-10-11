package org.taggr.android.data

/** Paging is based on the raw server page even when every row is hidden locally. */
data class PostPage(val posts: List<TaggrPost>, val anchor: Long, val hasMore: Boolean) {
    companion object {
        fun visible(rows: List<TaggrPost>, allowed: (TaggrPost) -> Boolean) =
            PostPage(rows.filter(allowed), rows.firstOrNull()?.id ?: 0, rows.isNotEmpty())
    }
}
