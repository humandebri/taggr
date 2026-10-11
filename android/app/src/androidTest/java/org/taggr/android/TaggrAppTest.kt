package org.taggr.android

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.FeedMode
import org.taggr.android.data.PostRepository
import org.taggr.android.data.TaggrApi
import org.taggr.android.data.TaggrPost
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class TaggrAppTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun switchesFeedAndOpensConversation() {
        val hot = TaggrPost(1, "Alice", "Hot post", null, 0, emptyList(), 0, 0, null)
        val latest = hot.copy(id = 2, author = "Bob", body = "Latest post")
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                    if (mode == FeedMode.HOT) listOf(hot) else listOf(latest)

                override suspend fun posts(ids: List<Long>) = listOf(latest).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        compose.setContent { TaggrTheme { TaggrApp(model) } }
        compose.onNodeWithText("Hot post").assertIsDisplayed()
        compose.onNodeWithText("#latest", substring = false).performClick()
        compose.onNodeWithText("Latest post").assertIsDisplayed()
        val body = compose.onNodeWithTag("post-body-2-0", useUnmergedTree = true)
        val mergedBounds = compose.onNodeWithText("Latest post").fetchSemanticsNode().boundsInRoot
        val translateBounds =
            compose.onNodeWithText("Translate with Google").fetchSemanticsNode().boundsInRoot
        val run = InstrumentationRegistry.getArguments().getString("ui_capture_run")
        if (run != null) {
            require(run.matches(Regex("[0-9]{8}-[0-9]{6}")))
            val dir =
                File(
                    requireNotNull(
                        InstrumentationRegistry.getInstrumentation()
                            .targetContext
                            .getExternalFilesDir(null)
                    ),
                    "ui-checks/$run",
                )
            check(dir.isDirectory || dir.mkdirs())
            File(dir, "post-navigation-hit-targets.txt")
                .writeText(
                    "merged=$mergedBounds\nbody=${body.fetchSemanticsNode().boundsInRoot}\ntranslate=$translateBounds\nmerged_center_hits_translate=${translateBounds.contains(mergedBounds.center)}\n"
                )
        }
        body.performClick()
        compose.onNodeWithText("Conversation").assertIsDisplayed()
        compose.waitUntil(timeoutMillis = 5_000) { model.detail.value?.loading == false }
        compose.onNodeWithText("No replies yet.").assertIsDisplayed()
        compose.onNodeWithText("Back").performClick()
        compose.onNodeWithText("TAGGR").assertIsDisplayed()
    }

    @Test
    fun guestCanNavigateToAccountAndInbox() {
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) =
                    emptyList<TaggrPost>()

                override suspend fun posts(ids: List<Long>) = emptyList<TaggrPost>()
            }
        val application =
            androidx.test.core.app.ApplicationProvider.getApplicationContext<
                android.app.Application
            >()
        val account = AccountViewModel(application)
        val model = FeedViewModel(repository)
        compose.setContent { TaggrTheme { TaggrApp(model, account) } }
        if (!account.state.value.acceptedTerms) {
            compose.onNodeWithText("I agree to the Terms of Use and safety rules").performClick()
            compose.onNodeWithText("Agree and continue").performClick()
        }
        compose.onNodeWithText("Account").performClick()
        compose.onNodeWithText("Continue with Internet Identity").assertIsDisplayed()
        compose.onNodeWithText("Inbox").performClick()
        compose
            .onNodeWithText("Sign in from Account to see your notifications.")
            .assertIsDisplayed()
    }

    @Test
    fun restrictedContentIsNeverRendered() {
        val post =
            TaggrPost(
                1,
                "Alice",
                "PRIVATE BODY",
                null,
                0,
                emptyList(),
                0,
                0,
                "This post has been deleted.",
            )
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(post)

                override suspend fun posts(ids: List<Long>) = listOf(post).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        compose.setContent { TaggrTheme { TaggrApp(model) } }
        compose.onNodeWithText("This post has been deleted.").assertIsDisplayed().performClick()
        compose.onNodeWithText("PRIVATE BODY").assertDoesNotExist()
    }
}

/** Exercises the real Android runtime, transport and mainnet certificate verification. */
@RunWith(AndroidJUnit4::class)
class TaggrNetworkTest {
    @Test
    fun readsMainnetFeedWithVerifiedQuerySignatures() = runBlocking {
        TaggrApi().use { api ->
            val posts = api.feed(FeedMode.HOT, 0, 0)
            check(posts.isNotEmpty()) { "Mainnet feed was empty" }
            check(posts.all { it.id >= 0 && it.author.isNotEmpty() })
        }
    }

    @Test
    fun searchesRealmAndUserWithValidatedMetadata() = runBlocking {
        TaggrApi().use { api ->
            val realms = api.search("/DAO")
            check(realms.any { it.kind == "realm" && it.target == "DAO" })
            val users = api.search("@JK")
            check(users.any { it.kind == "user" && it.title.equals("@JK", true) })
            check(api.search("#nsfw").none { it.target.equals("nsfw", true) })
        }
    }
}
