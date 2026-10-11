package org.taggr.android

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.math.BigInteger
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.PostContent
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class PollUITest {
    @get:Rule val compose = createComposeRule()

    private fun poll(
        votes: Map<Int, List<BigInteger>> = emptyMap(),
        voters: Set<BigInteger> = emptySet(),
        weighted: Map<Int, BigInteger> = emptyMap(),
    ) = TaggrPoll(listOf("First", "Second"), votes, voters, BigInteger.valueOf(24), weighted)

    @Test
    fun selectionAnonymousSubmissionAndBlockedRepeatUseTheChosenOption() {
        var submitted: Pair<Int, Boolean>? = null
        var blocked by mutableStateOf(false)
        val poll = poll()
        compose.setContent {
            TaggrTheme {
                PollContent(
                    poll,
                    PollPresentation(poll, 0, 7, BigInteger.valueOf(4), false, 0),
                    emptyMap(),
                    8,
                    blocked,
                    { option, anonymous ->
                        submitted = option to anonymous
                        blocked = true
                    },
                    {},
                    {},
                )
            }
        }
        compose.onNodeWithText("SUBMIT").assertIsNotEnabled()
        compose.onNodeWithTag("poll-option-1").performClick()
        compose.onNodeWithText("SUBMIT ANONYMOUSLY").performClick()
        compose.runOnIdle { assertEquals(1 to true, submitted) }
        compose.onNodeWithText("SUBMIT").assertIsNotEnabled()
        compose.onNodeWithText("SUBMIT ANONYMOUSLY").assertIsNotEnabled()
    }

    @Test
    fun guestSeesResultsVoterProfileAndAnonymousMarkerThroughPostContent() {
        val poll =
            poll(
                mapOf(
                    0 to listOf(BigInteger.valueOf(7)),
                    1 to listOf(BigInteger("9007199254740989")),
                )
            )
        var profile: BigInteger? = null
        compose.setContent {
            TaggrTheme {
                Column {
                    PostContent(
                        TaggrPost(
                            42,
                            "Alice",
                            "Body",
                            null,
                            0,
                            emptyList(),
                            0,
                            0,
                            null,
                            poll = poll,
                        ),
                        false,
                    )
                    PollContent(
                        poll,
                        PollPresentation(poll, 0, null, BigInteger.valueOf(4), false, 0),
                        mapOf(BigInteger.valueOf(7) to "Alice"),
                        8,
                        false,
                        { _, _ -> },
                        {},
                        { profile = it },
                    )
                }
            }
        }
        compose.onAllNodesWithText("1 (50%)").assertCountEquals(4)
        compose.onNodeWithText("Alice").clickPollVoter("Alice")
        compose.runOnIdle { assertEquals(BigInteger.valueOf(7), profile) }
        compose.onAllNodesWithText("N/A").assertCountEquals(2)
        compose.onNodeWithText("SUBMIT").assertDoesNotExist()
    }

    @Test
    fun publicRevoteAndExpiredVotingPowerMatchPresentation() {
        var changing by mutableStateOf(false)
        var expired by mutableStateOf(false)
        val poll =
            poll(
                mapOf(0 to listOf(BigInteger.valueOf(7))),
                setOf(BigInteger.valueOf(7)),
                mapOf(0 to BigInteger.valueOf(100000001)),
            )
        compose.setContent {
            TaggrTheme {
                PollContent(
                    poll,
                    PollPresentation(
                        poll,
                        0,
                        7,
                        BigInteger.valueOf(4),
                        changing,
                        if (expired) 24 * 3600000L else 0,
                    ),
                    emptyMap(),
                    8,
                    false,
                    { _, _ -> },
                    { changing = true },
                    {},
                )
            }
        }
        compose.onNodeWithText("CHANGE VOTE").performClick()
        compose.onNodeWithText("SUBMIT").assertIsDisplayed()
        compose.runOnIdle { expired = true }
        compose.onNodeWithText("SUBMIT").assertDoesNotExist()
        compose.onNodeWithText("RESULTS BY VOTING POWER").assertIsDisplayed()
        compose.onNodeWithText("2").assertIsDisplayed()
    }
}

/** Click the rendered linked substring, rather than the surrounding voter text. */
internal fun SemanticsNodeInteraction.clickPollVoter(label: String) {
    val layouts = mutableListOf<TextLayoutResult>()
    performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) {
        assertTrue(it(layouts))
    }
    val layout = layouts.single()
    val start = layout.layoutInput.text.text.indexOf(label)
    assertTrue("Voter label must be rendered", start >= 0)
    assertTrue(
        "Voter label must have a native link",
        layout.layoutInput.text.getLinkAnnotations(start, start + 1).isNotEmpty(),
    )
    performTouchInput { click(layout.getBoundingBox(start).center) }
}
