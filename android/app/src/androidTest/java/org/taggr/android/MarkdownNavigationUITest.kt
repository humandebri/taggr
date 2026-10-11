package org.taggr.android

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.PostContent
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class MarkdownNavigationUITest {
    @get:Rule val compose = createComposeRule()

    private fun tapTextLink(node: SemanticsNodeInteraction, label: String) {
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val result = layouts.single()
        val offset = result.layoutInput.text.text.indexOf(label)
        assertTrue("Link label missing", offset >= 0)
        val point = result.getBoundingBox(offset + label.length / 2).center
        node.performTouchInput { click(point) }
    }

    @Test
    fun mentionsTagsRealmsAndBareUrlsHaveIndependentCharacterAccurateTargets() {
        val native = mutableListOf<TaggrLink>()
        val external = mutableListOf<String>()
        val name = "cafe" + 0x0301.toChar()
        val noBreak = 0x00a0.toChar()
        val body =
            "@Alice #ICP /日本語Realm @$name　https://example.net/path${noBreak}after\n\n7. Seven\n8. Eight\n\nVisit https://example.org/help!"
        val post = TaggrPost(501, "Author", body, null, 0, emptyList(), 0, 0, null)
        val handler =
            TaggrUriHandler(
                TaggrLinks.productionHost,
                native::add,
                object : UriHandler {
                    override fun openUri(uri: String) {
                        external.add(uri)
                    }
                },
            )
        compose.setContent {
            CompositionLocalProvider(LocalUriHandler provides handler) {
                TaggrTheme { Column { PostContent(post, true) } }
            }
        }
        val text =
            compose.onNodeWithText(
                "@Alice #ICP /日本語Realm",
                substring = true,
                useUnmergedTree = true,
            )
        text.assertIsDisplayed()
        tapTextLink(text, "@Alice")
        tapTextLink(text, "#ICP")
        tapTextLink(text, "/日本語Realm")
        tapTextLink(text, "@$name")
        tapTextLink(text, "EXAMPLE.NET")
        tapTextLink(
            compose.onNodeWithText("EXAMPLE.ORG", substring = true, useUnmergedTree = true),
            "EXAMPLE.ORG",
        )
        compose.runOnIdle {
            assertEquals(
                listOf(
                    TaggrLink.Profile("Alice"),
                    TaggrLink.Tags(listOf("ICP")),
                    TaggrLink.Realm("日本語Realm"),
                    TaggrLink.Profile(name),
                ),
                native,
            )
            assertEquals(listOf("https://example.net/path", "https://example.org/help"), external)
        }
        compose
            .onNodeWithText("7. Seven\n8. Eight", substring = true, useUnmergedTree = true)
            .assertIsDisplayed()
    }

    @Test
    fun actualAppOpensMarkdownPostLinkInternallyAndReturnsToFeed() {
        val target =
            TaggrPost(502, "Target", "Native destination body", null, 0, emptyList(), 0, 0, null)
        val source =
            target.copy(
                id = 501,
                author = "Source",
                body = "[Open native target](https://${TaggrLinks.productionHost}/post/502)",
            )
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(source)

                override suspend fun posts(ids: List<Long>) =
                    listOf(source, target).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        val external = mutableListOf<String>()
        val fallback =
            object : UriHandler {
                override fun openUri(uri: String) {
                    external.add(uri)
                }
            }
        compose.setContent {
            CompositionLocalProvider(LocalUriHandler provides fallback) {
                TaggrTheme { TaggrApp(model, account) }
            }
        }
        if (!account.state.value.acceptedTerms) {
            compose.onNodeWithText("I agree to the Terms of Use and safety rules").performClick()
            compose.onNodeWithText("Agree and continue").performClick()
        }
        tapTextLink(
            compose.onNodeWithText("Open native target", useUnmergedTree = true),
            "Open native target",
        )
        compose.waitUntil(5000) {
            model.detail.value?.post?.id == 502L && model.detail.value?.loading == false
        }
        compose
            .onNodeWithText("Native destination body", useUnmergedTree = true)
            .assertIsDisplayed()
        compose.runOnIdle { assertEquals(emptyList<String>(), external) }
        compose.onNodeWithText("Back").performClick()
        compose.onNodeWithText("Open native target", useUnmergedTree = true).assertIsDisplayed()
        compose.runOnIdle { assertNull(model.detail.value) }
    }

    @Test
    fun normalGuestAppReadsPublicTagProfileAndRealmAndReturnsFromTagConversation() {
        val source = TaggrPost(501, "Fixture", "#ICP @JK /DAO", null, 0, emptyList(), 0, 0, null)
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(source)

                override suspend fun posts(ids: List<Long>) =
                    if (ids == listOf(501L)) listOf(source) else account.api.posts(ids)

                override suspend fun thread(id: Long) =
                    if (id == 501L) listOf(source) else account.api.thread(id)
            }
        val model = FeedViewModel(repository, ownsRepository = false)
        val external = mutableListOf<String>()
        val fallback =
            object : UriHandler {
                override fun openUri(uri: String) {
                    external.add(uri)
                }
            }
        compose.setContent {
            CompositionLocalProvider(LocalUriHandler provides fallback) {
                TaggrTheme { TaggrApp(model, account) }
            }
        }
        if (!account.state.value.acceptedTerms) {
            compose.onNodeWithText("I agree to the Terms of Use and safety rules").performClick()
            compose.onNodeWithText("Agree and continue").performClick()
        }
        fun sourceText() = compose.onNodeWithText("#ICP @JK /DAO", useUnmergedTree = true)
        tapTextLink(sourceText(), "#ICP")
        compose.onNodeWithText("#ICP", substring = false).assertIsDisplayed()
        compose.waitUntil(45000) {
            compose.onAllNodesWithText("Open conversation").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onAllNodesWithText("Open conversation")[0].performScrollTo().performClick()
        compose.waitUntil(45000) { model.detail.value?.loading == false }
        compose.runOnIdle {
            assertNotEquals(501L, model.detail.value?.post?.id)
            assertNull(model.detail.value?.error)
            assertNotEquals("Post unavailable", model.detail.value?.post?.restriction)
        }
        compose.onNodeWithText("Conversation").assertIsDisplayed()
        compose.onNodeWithText("Back").performClick()
        compose.onNodeWithText("#ICP", substring = false).assertIsDisplayed()
        compose.onNodeWithText("Back").performClick()
        sourceText().assertIsDisplayed()
        tapTextLink(sourceText(), "@JK")
        compose.waitUntil(45000) {
            compose.onAllNodesWithTag("profile-name").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("profile-name").assertTextEquals("JK")
        compose.onNodeWithText("Back").performScrollTo().performClick()
        sourceText().assertIsDisplayed()
        tapTextLink(sourceText(), "/DAO")
        compose.waitUntil(45000) {
            compose.onAllNodesWithTag("realm-details").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("realm-details").assertExists()
        compose.onNodeWithText("Back").performScrollTo().performClick()
        sourceText().assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(emptyList<String>(), external)
            model.discardCachedContent()
        }
    }

    @Test
    fun longAsciiAndDecomposedMentionsRenderOnAndroidWithoutRegexFailure() {
        val first = "@" + "a".repeat(6000)
        val second = "@" + ("e" + 0x0301.toChar()).repeat(6000)
        val post =
            mutableStateOf(TaggrPost(503, "Fixture", first, null, 0, emptyList(), 0, 0, null))
        compose.setContent { TaggrTheme { Column { PostContent(post.value, false) } } }
        compose.onNodeWithText(first, useUnmergedTree = true).assertIsDisplayed()
        compose.runOnIdle { post.value = post.value.copy(body = second) }
        compose.onNodeWithText(second, useUnmergedTree = true).assertIsDisplayed()
    }
}
