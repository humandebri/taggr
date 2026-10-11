package org.taggr.android

import androidx.compose.ui.platform.UriHandler
import org.junit.Assert.*
import org.junit.Test

class TaggrUriHandlerTest {
    @Test
    fun supportedPublicAndConfiguredRoutesStayNativeAndOthersUseExternalHandler() {
        val native = mutableListOf<TaggrLink>()
        val external = mutableListOf<String>()
        val handler =
            TaggrUriHandler(
                "localhost:18444",
                native::add,
                object : UriHandler {
                    override fun openUri(uri: String) {
                        external.add(uri)
                    }
                },
            )
        handler.openUri("https://${TaggrLinks.productionHost}/post/7")
        handler.openUri("https://localhost:18444/#/feed/ICP")
        for (url in
            listOf(
                "https://example.org/post/7",
                "https://localhost:18444/android-auth-callback#session=x",
                "mailto:hello@example.org",
                "https://${TaggrLinks.productionHost}/post/7/delete",
            )) handler.openUri(url)
        assertEquals(listOf(TaggrLink.Post(7), TaggrLink.Tags(listOf("ICP"))), native)
        assertEquals(4, external.size)
    }
}
