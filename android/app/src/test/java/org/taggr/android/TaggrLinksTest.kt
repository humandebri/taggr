package org.taggr.android

import org.junit.Assert.*
import org.junit.Test
import org.taggr.android.data.FeedMode

class TaggrLinksTest {
    private val base = "https://${TaggrLinks.productionHost}"

    @Test
    fun sharedPostURLUsesTheUniversalRouteAndConfiguredOrigin() {
        assertEquals("$base/post/42", TaggrLinks.postURL(42))
        assertEquals(
            TaggrLink.Post(Long.MAX_VALUE),
            TaggrLinks.parse(TaggrLinks.postURL(Long.MAX_VALUE)),
        )
        assertEquals("https://localhost:18444/post/0", TaggrLinks.postURL(0, "localhost:18444"))
        assertEquals(
            TaggrLink.Post(0),
            TaggrLinks.parse(TaggrLinks.postURL(0, "localhost:18444"), "localhost:18444"),
        )
        assertThrows(IllegalArgumentException::class.java) { TaggrLinks.postURL(-1) }
        for (domain in
            listOf(
                "user@host.example",
                "host.example/path",
                "host.example?query",
                "host.example#fragment",
            )) assertThrows(IllegalArgumentException::class.java) { TaggrLinks.postURL(1, domain) }
    }

    @Test
    fun nativePathAndLegacyFragmentRoutesAgree() {
        val routes =
            mapOf(
                "/" to TaggrLink.Feed(FeedMode.HOT),
                "/post/42" to TaggrLink.Post(42),
                "/thread/42" to TaggrLink.Post(42),
                "/user/alice" to TaggrLink.Profile("alice"),
                "/journal/7" to TaggrLink.Profile("7"),
                "/user/alice/photos" to TaggrLink.Profile("alice", true),
                "/realm/%E6%97%A5%E6%9C%AC" to TaggrLink.Realm("日本"),
                "/feed/latest" to TaggrLink.Feed(FeedMode.LATEST),
                "/feed/personal" to TaggrLink.Feed(FeedMode.PERSONAL),
                "/feed/ICP+TAGGR" to TaggrLink.Tags(listOf("ICP", "TAGGR")),
                "/feed/a%2Bb" to TaggrLink.Tags(listOf("a+b")),
                "/search/hello%20world/a+b" to TaggrLink.Search("hello world/a+b"),
                "/transactions/2vxsx-fae" to TaggrLink.Transactions("2vxsx-fae"),
                "/transactions" to TaggrLink.Transactions("2vxsx-fae"),
                "/proposal/7" to TaggrLink.Proposal(7),
                "/inbox" to TaggrLink.Inbox,
                "/bookmarks" to TaggrLink.Bookmarks,
                "/invites" to TaggrLink.Invites,
                "/proposals" to TaggrLink.Proposals,
                "/settings" to TaggrLink.Account,
                "/wallet" to TaggrLink.Account,
                "/auction" to TaggrLink.Account,
            )
        for ((path, route) in routes) {
            assertEquals(path, route, TaggrLinks.parse(base + path))
            assertEquals(path, route, TaggrLinks.parse("$base/#$path"))
        }
    }

    @Test
    fun unsupportedHostsCallbacksMalformedIdsAndUtf8CannotNavigate() {
        for (url in
            listOf(
                "https://evil.example/post/42",
                "${base}.evil.example/post/42",
                "https://evil.example@${TaggrLinks.productionHost}/post/42",
                "http://${TaggrLinks.productionHost}/post/42",
                "$base:8443/post/42",
                "$base/android-auth-callback#/?session=x",
                "$base/ios-auth-callback",
                "$base/post/-1",
                "$base/post/9223372036854775808",
                "$base/post/42/delete",
                "$base/user/%2Fadmin",
                "$base/user/%00alice",
                "$base/user/%FF",
                "$base/feed/a++b",
                "$base/unknown",
                "$base//post/42",
                "$base/post/",
                "$base/search/${"a".repeat(4096)}",
            )) assertNull(url, TaggrLinks.parse(url))
    }

    @Test
    fun configuredDebugDomainDoesNotBecomeAnApiOrRootOverride() {
        assertEquals(
            TaggrLink.Post(7),
            TaggrLinks.parse(
                "https://taggr.example:8443/post/7?api=https://evil.example",
                "taggr.example:8443",
            ),
        )
        assertNull(TaggrLinks.parse("https://taggr.example/post/7", "taggr.example:8443"))
        assertEquals(
            TaggrLink.Post(7),
            TaggrLinks.parse("$base/post/7?root_key=evil", "taggr.example:8443"),
        )
    }
}
