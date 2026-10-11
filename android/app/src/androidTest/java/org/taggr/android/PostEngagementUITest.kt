package org.taggr.android

import android.app.Application
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.PostEngagementContent
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class PostEngagementUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun receivedTipCountIsAccessibleUpdatesAndDoesNotActAsAPayment() {
        val source =
            mutableStateOf(
                TaggrPost.decodeEnvelopes(
                        """[[{"id":42,"user":7,"body":"Tip fixture","timestamp":0,"children":[],"tips":[[8,100],[8,200]]},{"author_name":"Alice"}]]"""
                            .toByteArray()
                    )
                    .single()
            )
        compose.setContent {
            val density = androidx.compose.ui.platform.LocalDensity.current
            androidx.compose.runtime.CompositionLocalProvider(
                androidx.compose.ui.platform.LocalDensity provides
                    androidx.compose.ui.unit.Density(density.density, 1.5f)
            ) {
                TaggrTheme {
                    androidx.compose.foundation.layout.Box(
                        androidx.compose.ui.Modifier.width(320.dp)
                    ) {
                        PostEngagementContent(source.value, null, false, {}, {}, {})
                    }
                }
            }
        }
        compose
            .onNodeWithContentDescription("2 tips")
            .assertIsDisplayed()
            .assert(
                SemanticsMatcher.keyNotDefined(
                    androidx.compose.ui.semantics.SemanticsActions.OnClick
                )
            )
        compose.runOnIdle { source.value = source.value.copy(tipCount = 1) }
        compose.onNodeWithContentDescription("1 tips").assertIsDisplayed()
        compose.onNodeWithContentDescription("2 tips").assertDoesNotExist()
        compose.runOnIdle { source.value = source.value.copy(tipCount = 0) }
        compose.onNodeWithContentDescription("1 tips").assertDoesNotExist()
    }

    @Test
    fun reactionPillsSendTheSelectedIdOnlyWhenEnabled() {
        val enabled = mutableStateOf(true)
        val selected = mutableListOf<Int>()
        val post =
            TaggrPost(
                42,
                "Alice",
                "Hello",
                null,
                0,
                emptyList(),
                0,
                3,
                null,
                reactions = mapOf(11 to listOf(7, 8), 10 to listOf(9)),
            )
        compose.setContent {
            TaggrTheme {
                PostEngagementContent(
                    post,
                    "owner",
                    true,
                    {},
                    {},
                    {},
                    reactionEnabled = enabled.value,
                    selectReaction = {
                        selected.add(it)
                        enabled.value = false
                    },
                )
            }
        }
        compose
            .onNodeWithContentDescription("❤️ reaction, 1")
            .assertIsEnabled()
            .assertHasClickAction()
            .performClick()
        compose.runOnIdle { assertEquals(listOf(10), selected) }
        compose.onNodeWithContentDescription("👍 reaction, 2").assertIsNotEnabled().performClick()
        compose.runOnIdle {
            assertEquals(listOf(10), selected)
            enabled.value = true
        }
        compose.onNodeWithContentDescription("👍 reaction, 2").performClick()
        compose.runOnIdle { assertEquals(listOf(10, 11), selected) }
    }

    @Test
    fun actionPanelRequiresExplicitExpansionAndResetsForAnotherPostOrOwner() {
        val post =
            mutableStateOf(
                TaggrPost(
                    42,
                    "Alice",
                    "Hello",
                    null,
                    0,
                    emptyList(),
                    3,
                    2,
                    null,
                    reactions = mapOf(11 to listOf(7, 8)),
                )
            )
        val owner = mutableStateOf<String?>("owner")
        var reports = 0
        var replies = 0
        compose.setContent {
            TaggrTheme {
                PostEngagementContent(
                    post.value,
                    owner.value,
                    true,
                    { replies++ },
                    {},
                    {
                        TextButton(onClick = { reports++ }) { Text("Report") }
                    },
                )
            }
        }
        compose.onNodeWithContentDescription("👍 reaction, 2").assertIsDisplayed()
        compose.onNodeWithText("Report").assertDoesNotExist()
        compose.onNodeWithText("Reply · 3").performClick()
        compose.runOnIdle {
            assertEquals(1, replies)
            assertEquals(0, reports)
        }
        compose
            .onNodeWithContentDescription("Show post actions")
            .assertHasClickAction()
            .performClick()
        compose.onNodeWithText("Report").assertIsDisplayed().performClick()
        compose.runOnIdle {
            assertEquals(1, reports)
            post.value = post.value.copy(id = 43)
        }
        compose.onNodeWithText("Report").assertDoesNotExist()
        compose.onNodeWithContentDescription("Show post actions").performClick()
        compose.runOnIdle { owner.value = null }
        compose.onNodeWithText("Report").assertDoesNotExist()
        compose.onNodeWithContentDescription("Show post actions").performClick()
        compose.onNodeWithContentDescription("Hide post actions").performClick()
        compose.onNodeWithText("Report").assertDoesNotExist()
    }

    @Test
    fun compactControlsStayReachableAtLargeTextSize() {
        val post =
            TaggrPost(
                42,
                "Alice",
                "Hello",
                null,
                0,
                emptyList(),
                123,
                2,
                null,
                authorId = 7,
                reactions = mapOf(11 to listOf(7, 8)),
            )
        compose.setContent {
            val density = androidx.compose.ui.platform.LocalDensity.current
            androidx.compose.runtime.CompositionLocalProvider(
                androidx.compose.ui.platform.LocalDensity provides
                    androidx.compose.ui.unit.Density(density.density, 1.5f)
            ) {
                TaggrTheme {
                    androidx.compose.foundation.layout.Box(
                        androidx.compose.ui.Modifier.width(320.dp)
                    ) {
                        PostEngagementContent(
                            post,
                            "owner",
                            true,
                            {},
                            {
                                org.taggr.android.ui.PostReactionControl(
                                    post,
                                    9,
                                    false,
                                    compact = true,
                                ) {}
                            },
                            { TextButton(onClick = {}) { Text("Report") } },
                        )
                    }
                }
            }
        }
        compose
            .onNodeWithContentDescription("Add reaction")
            .assertHasClickAction()
            .assertIsDisplayed()
        compose.onNodeWithText("Reply · 123").assertIsDisplayed()
        compose.onNodeWithContentDescription("Show post actions").assertIsDisplayed().performClick()
        compose.onNodeWithText("Report").assertIsDisplayed()
    }

    @Test
    fun guestCanOpenReportFromActualConversationWithoutReplyOrEdit() {
        val post =
            TaggrPost(
                42,
                "Alice",
                "Public conversation",
                null,
                0,
                emptyList(),
                0,
                0,
                null,
                authorId = 7,
            )
        val repository =
            object : PostRepository {
                override suspend fun feed(mode: FeedMode, page: Int, offset: Long) = listOf(post)

                override suspend fun posts(ids: List<Long>) = listOf(post).filter { it.id in ids }
            }
        val model = FeedViewModel(repository)
        val account = AccountViewModel(ApplicationProvider.getApplicationContext<Application>())
        compose.setContent { TaggrTheme { TaggrApp(model, account) } }
        if (!account.state.value.acceptedTerms) {
            compose.onNodeWithText("I agree to the Terms of Use and safety rules").performClick()
            compose.onNodeWithText("Agree and continue").performClick()
        }
        compose
            .onNodeWithText("Public conversation", useUnmergedTree = true)
            .performScrollTo()
            .performClick()
        compose.waitUntil(5_000) { model.detail.value?.loading == false }
        compose.onNodeWithText("Report").assertDoesNotExist()
        compose.onNodeWithText("Reply", substring = false).assertIsNotEnabled()
        compose.onNodeWithContentDescription("Show post actions").performClick()
        compose.onNodeWithText("Edit").assertDoesNotExist()
        compose.onNodeWithText("Delete", substring = false).assertDoesNotExist()
        compose.onNodeWithText("Report").performClick()
        compose.onNodeWithText("Report content").assertIsDisplayed()
        compose.onNodeWithText("Send report").assertIsNotEnabled()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithContentDescription("Hide post actions").performClick()
        compose.onNodeWithText("Report").assertDoesNotExist()
    }
}
