package org.taggr.android

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*

@RunWith(AndroidJUnit4::class)
class PollNativeReadTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun realPublicPollUsesNativeResultsAndVoterProfileReturnsToItsConversation() {
        val selected = runBlocking {
            TaggrApi().use { api ->
                var found: TaggrPost? = null
                for (tag in listOf("poll", "polls")) {
                    for (page in 0..1) {
                        val rows = api.tagPostPage(tag, page, 0)
                        found =
                            rows.posts.firstOrNull {
                                it.restriction == null &&
                                    it.poll != null &&
                                    ReactionGroup.groups(it.reactions, ReactionGroup.defaultOrder)
                                        .any { group ->
                                            group.users.any { id -> id < 9007199254739991L }
                                        } &&
                                    it.poll.votes
                                        .filterKeys { key -> key < 20 }
                                        .values
                                        .any { ids -> ids.take(20).any(TaggrPoll::resolvableUser) }
                            }
                        if (found != null || !rows.hasMore) break
                    }
                    if (found != null) break
                }
                requireNotNull(found) {
                    "No eligible public Poll found in the inspected tag pages."
                }
            }
        }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("taggr-safety", Context.MODE_PRIVATE)
        val terms = "terms/${TaggrRuntime.configuration().canisterId}"
        val before = prefs.getString(terms, null)
        var changed = false
        val intent =
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(Uri.parse("https://${TaggrRuntime.domain}/post/${selected.id}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ActivityScenario.launch<MainActivity>(intent).use { scenario ->
            try {
                lateinit var account: AccountViewModel
                scenario.onActivity {
                    account = ViewModelProvider(it)[AccountViewModel::class.java]
                }
                compose.waitUntil(30000) { !account.state.value.restoring }
                assertNull(
                    "Guest test preserves any existing signed-in session.",
                    account.state.value.principal,
                )
                if (
                    compose
                        .onAllNodesWithText("Agree and continue")
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                ) {
                    compose
                        .onNodeWithText("I agree to the Terms of Use and safety rules")
                        .performScrollTo()
                        .performClick()
                    compose.onNodeWithText("Agree and continue").performScrollTo().performClick()
                    changed = true
                }
                val tag = "post-poll-${selected.id}"
                compose.waitUntil(30000) {
                    compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
                }
                val poll = compose.onNodeWithTag(tag)
                poll.performScrollTo().assertIsDisplayed()
                compose.onNodeWithText("SUBMIT").assertDoesNotExist()
                compose.waitUntil(20000) {
                    compose
                        .onAllNodesWithTag("poll-loading-${selected.id}")
                        .fetchSemanticsNodes()
                        .isEmpty()
                }
                compose
                    .onNodeWithText("Poll settings or updated results could not be loaded.")
                    .assertDoesNotExist()
                android.os.SystemClock.sleep(500)
                val image =
                    InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()!!
                File(context.cacheDir, "poll-native.png").outputStream().use {
                    check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
                }
                image.recycle()
                val voter =
                    selected.poll!!
                        .votes
                        .toSortedMap()
                        .filterKeys { it < 20 }
                        .values
                        .flatMap { it.take(20) }
                        .firstOrNull {
                            TaggrPoll.resolvableUser(it) && account.safety.allowedUser(it.toLong())
                        }
                requireNotNull(voter) {
                    "The selected public Poll needs a visible resolvable voter for the profile journey."
                }
                run {
                    val numeric = voter.toString()
                    // The API may already have resolved the name; target the source profile by its
                    // current label.
                    val label = runBlocking {
                        account.api
                            .jsonQuery("users_data", listOf(listOf(voter)))
                            .path(numeric)
                            .asText(numeric)
                    }
                    val target =
                        hasText(label, substring = true) and hasAnyAncestor(hasTestTag(tag))
                    compose.waitUntil(20000) {
                        compose.onAllNodes(target).fetchSemanticsNodes().isNotEmpty()
                    }
                    compose.onNode(target).performScrollTo().clickPollVoter(label)
                    compose.waitUntil(30000) {
                        compose.onAllNodesWithTag("profile-name").fetchSemanticsNodes().isNotEmpty()
                    }
                    compose.onNodeWithTag("profile-name").assertIsDisplayed()
                    val sourceProfile = runBlocking {
                        account.api.jsonQuery(
                            "user",
                            listOf(TaggrRuntime.domain, listOf(voter.toString())),
                        )
                    }
                    val sourceBadges =
                        UserBadge.profile(sourceProfile, null, null, System.currentTimeMillis())
                    require(sourceBadges.isNotEmpty()) {
                        "Selected source profile needs a public badge for the native check."
                    }
                    sourceBadges.forEach { badge ->
                        compose
                            .onAllNodesWithContentDescription(badge.accessibilityLabel)
                            .onFirst()
                            .performScrollTo()
                            .assertIsDisplayed()
                    }
                    val kind =
                        if (ProfileUserList.Following.ids(sourceProfile).isNotEmpty())
                            ProfileUserList.Following
                        else ProfileUserList.Followers
                    val userIds = kind.ids(sourceProfile)
                    require(userIds.isNotEmpty()) {
                        "Selected voter needs a user list for the native journey."
                    }
                    val listTag =
                        "profile-stat-${if (kind == ProfileUserList.Following) "follows" else "followers"}"
                    compose.onNodeWithTag(listTag).performScrollTo().assertIsDisplayed()
                    val pinCount = PinnedPosts.decode(sourceProfile.get("pinned_posts")).size
                    if (pinCount > 0) compose.onNodeWithTag("profile-stat-pinned").assertExists()
                    else compose.onNodeWithTag("profile-stat-pinned").assertDoesNotExist()
                    compose.onNodeWithTag(listTag).performClick()
                    compose.waitUntil(20000) {
                        compose
                            .onAllNodesWithTag("profile-user-list")
                            .fetchSemanticsNodes()
                            .isNotEmpty()
                    }
                    android.os.SystemClock.sleep(500)
                    val listImage =
                        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()!!
                    File(context.cacheDir, "profile-users-native.png").outputStream().use {
                        check(listImage.compress(Bitmap.CompressFormat.PNG, 100, it))
                    }
                    listImage.recycle()
                    val targetId = userIds.first()
                    compose
                        .onNodeWithTag("profile-list-user-$targetId")
                        .performScrollTo()
                        .performClick()
                    val targetName = runBlocking {
                        account.api
                            .jsonQuery(
                                "user",
                                listOf(TaggrRuntime.domain, listOf(targetId.toString())),
                            )
                            .path("name")
                            .asText()
                    }
                    compose.waitUntil(30000) {
                        compose
                            .onAllNodes(hasTestTag("profile-name") and hasText(targetName))
                            .fetchSemanticsNodes()
                            .isNotEmpty()
                    }
                    compose.onNodeWithText("Back").performClick()
                    compose.waitUntil(30000) {
                        compose
                            .onAllNodes(
                                hasTestTag("profile-name") and
                                    hasText(sourceProfile.path("name").asText())
                            )
                            .fetchSemanticsNodes()
                            .isNotEmpty()
                    }
                    compose.onNodeWithText("Back").performClick()
                    compose.waitUntil(30000) {
                        compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
                    }
                    compose.onNodeWithTag(tag).performScrollTo().assertIsDisplayed()
                    val reaction =
                        ReactionGroup.groups(selected.reactions, ReactionGroup.defaultOrder)
                            .first { group ->
                                group.users.take(20).any { id ->
                                    id < 9007199254739991L && account.safety.allowedUser(id)
                                }
                            }
                    val reactionUser =
                        reaction.users.take(20).first { id ->
                            id < 9007199254739991L && account.safety.allowedUser(id)
                        }
                    val reactionName = runBlocking {
                        account.api
                            .jsonQuery("users_data", listOf(listOf(reactionUser)))
                            .path(reactionUser.toString())
                            .asText()
                    }
                    require(reactionName.isNotBlank()) {
                        "Reaction profile journey needs a resolved public name."
                    }
                    val reactionTag = "reaction-voters-${reaction.id}"
                    compose
                        .onNode(hasScrollToIndexAction())
                        .performScrollToNode(hasTestTag(reactionTag))
                    compose.waitUntil(20000) {
                        compose
                            .onAllNodes(
                                hasTestTag(reactionTag) and hasText(reactionName, substring = true)
                            )
                            .fetchSemanticsNodes()
                            .isNotEmpty()
                    }
                    android.os.SystemClock.sleep(500)
                    val reactionImage =
                        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()!!
                    File(context.cacheDir, "reaction-details-native.png").outputStream().use {
                        check(reactionImage.compress(Bitmap.CompressFormat.PNG, 100, it))
                    }
                    reactionImage.recycle()
                    compose.onNodeWithTag(reactionTag).clickPollVoter(reactionName)
                    val reactionProfileName = runBlocking {
                        account.api
                            .jsonQuery(
                                "user",
                                listOf(TaggrRuntime.domain, listOf(reactionUser.toString())),
                            )
                            .path("name")
                            .asText()
                    }
                    compose.waitUntil(30000) {
                        compose
                            .onAllNodes(hasTestTag("profile-name") and hasText(reactionProfileName))
                            .fetchSemanticsNodes()
                            .isNotEmpty()
                    }
                    compose.onNodeWithText("Back").performClick()
                    compose.waitUntil(30000) {
                        compose
                            .onAllNodesWithText("Conversation")
                            .fetchSemanticsNodes()
                            .isNotEmpty()
                    }
                    compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasTestTag(tag))
                    compose.onNodeWithTag(tag).assertIsDisplayed()
                    compose
                        .onNode(hasScrollToIndexAction())
                        .performScrollToNode(hasTestTag("reaction-details"))
                    compose.onNodeWithTag("reaction-details").assertIsDisplayed()
                }
                println(
                    "Public Poll post=${selected.id}; options=${selected.poll!!.options.size}; profileChecked=true"
                )
            } finally {
                if (changed)
                    prefs
                        .edit()
                        .apply { if (before == null) remove(terms) else putString(terms, before) }
                        .commit()
            }
        }
    }
}
