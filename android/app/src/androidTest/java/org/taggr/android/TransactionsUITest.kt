package org.taggr.android

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.math.BigInteger
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class TransactionsUITest {
    @get:Rule val compose = createComposeRule()

    private fun row(id: Long) =
        TokenTransaction(
            id,
            TokenAccount("aaaaa-aa"),
            TokenAccount("2vxsx-fae"),
            123uL,
            1uL,
            1000000000uL,
            "00ff",
        )

    private val summary = TokenAccountSummary(BigInteger("12300"), 2, "TAGGR")

    @Test
    fun rendersExactTokenAmountsAndBinaryMemo() {
        compose.setContent {
            TaggrTheme {
                TransactionsContent(
                    "2vxsx-fae",
                    "guest",
                    { _, _ -> listOf(row(9)) },
                    { summary },
                    {},
                )
            }
        }
        compose.waitUntil(5000) {
            compose.onAllNodesWithText("Balance: 123 TAGGR").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("Amount: 1.23 TAGGR · Fee: 0.01").performScrollTo().assertExists()
        compose.onNodeWithText("Memo: 00ff").performScrollTo().assertExists()
    }

    @Test
    fun failedPageRetainsHistoryAndRetriesThatPage() {
        val calls = mutableListOf<Int>()
        var failed = false
        compose.setContent {
            TaggrTheme {
                TransactionsContent(
                    "2vxsx-fae",
                    "guest",
                    { _, page ->
                        calls += page
                        if (page == 0) listOf(row(9))
                        else if (!failed) {
                            failed = true
                            error("Offline")
                        } else emptyList()
                    },
                    { summary },
                    {},
                )
            }
        }
        compose.waitUntil(5000) {
            compose.onAllNodesWithText("Transaction #9").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("Load more").performScrollTo().performClick()
        compose.waitUntil(5000) {
            compose.onAllNodesWithText("Retry transactions").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("Transaction #9").performScrollTo().assertExists()
        compose.onNodeWithText("Retry transactions").performScrollTo().performClick()
        compose.waitUntil(5000) { calls.size >= 3 }
        compose.runOnIdle { assertEquals(listOf(0, 1, 1), calls) }
    }

    @Test
    fun balanceFailureDoesNotHideHistoryOrInventTokenDecimals() {
        compose.setContent {
            TaggrTheme {
                TransactionsContent(
                    "2vxsx-fae",
                    "guest",
                    { _, _ -> listOf(row(9)) },
                    { error("Balance unavailable") },
                    {},
                )
            }
        }
        compose.waitUntil(5000) {
            compose.onAllNodesWithText("Retry balance").fetchSemanticsNodes().isNotEmpty()
        }
        compose
            .onNodeWithText("Amount: 123 base units · Fee: 1 base units")
            .performScrollTo()
            .assertExists()
    }

    @Test
    fun publicMainnetHistoryAndBalanceUseNativeReadOnlyQueryDecoding() =
        runBlocking<Unit> {
            withTimeout(40000) {
                TaggrApi().use { api ->
                    assertEquals(TaggrApi.CANISTER_ID, api.configuration.canisterId)
                    assertArrayEquals(
                        org.ic4j.agent.Agent.mainnetRootKey(),
                        api.configuration.rootKey,
                    )
                    val account = TokenAccount("2vxsx-fae")
                    val entries = api.tokenTransactions(account, 0)
                    assertTrue(entries.isNotEmpty())
                    val selected =
                        entries
                            .asSequence()
                            .flatMap { sequenceOf(it.to, it.from) }
                            .first { it.owner != "2vxsx-fae" }
                    val scoped = api.tokenTransactions(selected, 0)
                    assertTrue(scoped.isNotEmpty())
                    assertTrue(
                        scoped.all {
                            it.from.owner == selected.owner || it.to.owner == selected.owner
                        }
                    )
                    val info = api.tokenAccountSummary(selected)
                    assertEquals("TAGGR", info.symbol)
                    assertTrue(info.decimals in 0..19)
                    assertTrue(info.balance.signum() >= 0)
                }
            }
        }

    @Test
    fun fundingAndRewardsRecipientsOpenTheirExactTokenAccounts() {
        val payload =
            mutableStateOf(ProposalPayload("Funding", recipient = "2vxsx-fae", amount = 12345uL))
        val targets = mutableListOf<String>()
        val post = TaggrPost(8, "author", "Discussion", null, 1000, emptyList(), 0, 0, null)
        compose.setContent {
            TaggrTheme {
                ProposalDetails(
                    TaggrProposal(
                        7,
                        1,
                        1000000000uL,
                        8,
                        "Executed",
                        payload.value,
                        emptyList(),
                        100uL,
                    ),
                    post,
                    2,
                    66,
                    {},
                    {},
                    {},
                    openTransactions = { targets += it },
                )
            }
        }
        compose.onNodeWithText("Recipient: 2vxsx-fae").performClick()
        compose.runOnIdle {
            payload.value = ProposalPayload("Rewards", recipient = "aaaaa-aa", amount = 321uL)
        }
        compose.onNodeWithText("Recipient: aaaaa-aa").performClick()
        compose.runOnIdle { assertEquals(listOf("2vxsx-fae", "aaaaa-aa"), targets) }
    }

    @Test
    fun invalidAccountDoesNotIssueQueries() {
        compose.setContent {
            TaggrTheme {
                TransactionsContent(
                    "aaaaa-ab",
                    "guest",
                    { _, _ -> error("Queried invalid account") },
                    { error("Queried invalid account") },
                    {},
                )
            }
        }
        compose.onNodeWithText("Invalid account Principal.").assertExists()
        compose.onNodeWithText("Load more").assertDoesNotExist()
    }
}
