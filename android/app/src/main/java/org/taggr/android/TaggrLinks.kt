package org.taggr.android

import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import org.taggr.android.data.FeedMode

sealed interface TaggrLink {
    data class Feed(val mode: FeedMode) : TaggrLink

    data class Post(val id: Long) : TaggrLink

    data class Profile(val handle: String, val photos: Boolean = false) : TaggrLink

    data class Realm(val name: String) : TaggrLink

    data class Tags(val tags: List<String>) : TaggrLink

    data class Search(val query: String) : TaggrLink

    data class Transactions(val account: String) : TaggrLink

    data class Proposal(val id: Long) : TaggrLink

    data object Inbox : TaggrLink

    data object Account : TaggrLink

    data object Bookmarks : TaggrLink

    data object Invites : TaggrLink

    data object Proposals : TaggrLink
}

/**
 * Browsing routes only. An incoming URL cannot choose an API, trust root or authentication
 * callback.
 */
object TaggrLinks {
    const val productionHost = "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io"

    fun postURL(id: Long, domain: String = productionHost): String {
        require(id >= 0)
        val origin = URI("https://$domain")
        require(
            origin.host != null &&
                origin.userInfo == null &&
                origin.rawAuthority == domain &&
                origin.path.isNullOrEmpty() &&
                origin.query == null &&
                origin.fragment == null
        )
        return origin.resolve("/post/$id").toASCIIString()
    }

    fun parse(value: String, domain: String = productionHost): TaggrLink? =
        try {
            require(value.length in 1..4096)
            val uri = URI(URI(value).toASCIIString())
            val configured = URI("https://$domain")
            require(uri.scheme.equals("https", true) && uri.userInfo == null)
            val effectivePort = if (uri.port == -1) 443 else uri.port
            require(
                (uri.host.equals(productionHost, true) && effectivePort == 443) ||
                    (uri.host.equals(configured.host, true) &&
                        effectivePort == (if (configured.port == -1) 443 else configured.port))
            )
            val raw = uri.rawFragment?.takeIf { it.startsWith("/") } ?: (uri.rawPath ?: "/")
            require(raw.startsWith("/") && !raw.contains("//"))
            val parts = raw.trim('/').split('/').filter { it.isNotEmpty() }
            fun argument(index: Int) =
                decode(parts[index]).also {
                    require(
                        it.isNotBlank() &&
                            it.length <= 1024 &&
                            it.none { c -> c.isISOControl() || c == '/' || c == '\\' }
                    )
                }
            fun id() =
                argument(1)
                    .also { require(it.matches(Regex("[0-9]+"))) }
                    .toLong()
                    .also { require(it >= 0) }
            when (parts.firstOrNull()) {
                null -> TaggrLink.Feed(FeedMode.HOT)
                "post",
                "thread" -> {
                    require(parts.size == 2)
                    TaggrLink.Post(id())
                }
                "user",
                "journal" -> {
                    require(parts.size == 2 || (parts.size == 3 && parts[2] == "photos"))
                    TaggrLink.Profile(argument(1), parts.size == 3)
                }
                "realm" -> {
                    require(parts.size == 2)
                    TaggrLink.Realm(argument(1))
                }
                "feed" -> {
                    require(parts.size <= 2)
                    when (parts.getOrNull(1)) {
                        null,
                        "hot" -> TaggrLink.Feed(FeedMode.HOT)
                        "latest" -> TaggrLink.Feed(FeedMode.LATEST)
                        "personal" -> TaggrLink.Feed(FeedMode.PERSONAL)
                        else -> {
                            val tags = parts[1].split('+').map(::decode)
                            require(
                                tags.size in 1..20 &&
                                    tags.all {
                                        it.isNotBlank() &&
                                            it.length <= 100 &&
                                            it.none { c ->
                                                c.isISOControl() || c == '/' || c == '\\'
                                            }
                                    }
                            )
                            TaggrLink.Tags(tags.distinct())
                        }
                    }
                }
                "search" ->
                    TaggrLink.Search(
                        parts
                            .drop(1)
                            .joinToString("/") { decode(it) }
                            .also { require(it.length <= 1024 && it.none(Char::isISOControl)) }
                    )
                "transactions" -> {
                    require(parts.size <= 2)
                    TaggrLink.Transactions(if (parts.size == 2) argument(1) else "2vxsx-fae")
                }
                "proposal" -> {
                    require(parts.size == 2)
                    TaggrLink.Proposal(id())
                }
                "inbox" -> {
                    require(parts.size == 1)
                    TaggrLink.Inbox
                }
                "bookmarks" -> {
                    require(parts.size == 1)
                    TaggrLink.Bookmarks
                }
                "invites" -> {
                    require(parts.size == 1)
                    TaggrLink.Invites
                }
                "proposals" -> {
                    require(parts.size == 1)
                    TaggrLink.Proposals
                }
                "settings",
                "wallet",
                "tokens",
                "auction",
                "transaction" -> {
                    require(parts.size <= 2)
                    TaggrLink.Account
                }
                else -> null
            }
        } catch (_: Exception) {
            null
        }

    private fun decode(raw: String): String {
        val bytes = ByteArrayOutputStream()
        var i = 0
        while (i < raw.length) {
            if (raw[i] == '%') {
                require(i + 2 < raw.length)
                bytes.write(raw.substring(i + 1, i + 3).toInt(16))
                i += 3
            } else {
                require(raw[i].code <= 127)
                bytes.write(raw[i++].code)
            }
        }
        return Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes.toByteArray()))
            .toString()
    }
}

/** Route approved browsing URLs locally; unknown destinations keep the OS handler. */
internal class TaggrUriHandler(
    private val domain: String,
    private val navigate: (TaggrLink) -> Unit,
    private val external: androidx.compose.ui.platform.UriHandler,
) : androidx.compose.ui.platform.UriHandler {
    override fun openUri(uri: String) {
        val destination = TaggrLinks.parse(uri, domain)
        if (destination == null) external.openUri(uri) else navigate(destination)
    }
}
