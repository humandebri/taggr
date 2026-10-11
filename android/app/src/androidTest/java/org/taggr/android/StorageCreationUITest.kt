package org.taggr.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class StorageCreationUITest {
    @get:Rule val compose = createComposeRule()
    private val owner = "2vxsx-fae"
    private val quote =
        StorageCreationQuote(
            7,
            "rrkah-fqaaa-aaaaa-aaaaq-cai",
            "a".repeat(64),
            TransferQuote(
                owner,
                "b".repeat(64),
                DraftImages.hex(StorageProvisioning.creationAccount(owner)),
                123_000_000uL,
                10_000uL,
                1000,
            ),
            "c".repeat(64),
        )

    @Test
    fun financialReviewShowsNetworkRecipientAndExactTotalBeforeExplicitConfirmation() {
        var confirmed = 0
        compose.setContent {
            TaggrTheme {
                StorageCreationConfirmation(quote, "Test network", false, {}) { confirmed++ }
            }
        }
        compose.onNodeWithText("Test network").assertExists()
        compose
            .onNodeWithText("CMC recipient: ${quote.transfer.recipient}")
            .performScrollTo()
            .assertIsDisplayed()
        compose.onNodeWithText("Creation price: 1.23 ICP").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Ledger fee: 0.0001 ICP").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Total: 1.2301 ICP").performScrollTo().assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, confirmed) }
        compose.onNodeWithText("Pay and create").performClick()
        compose.runOnIdle { assertEquals(1, confirmed) }
    }

    @Test
    fun busyReviewCannotDispatchAnotherCreation() {
        compose.setContent {
            TaggrTheme {
                StorageCreationConfirmation(quote, "Test network", true, {}) {
                    error("Unexpected confirmation")
                }
            }
        }
        compose.onNodeWithText("Pay and create").assertIsNotEnabled()
        compose.onNodeWithText("Cancel").assertIsNotEnabled()
    }

    @Test
    fun refundDisplaysExactBlockWithoutClaimingFullAmountReturned() {
        val record =
            StorageCreationRecord(quote)
                .withPayment(
                    PendingTransfer(
                        quote.transfer,
                        ByteArray(32),
                        123uL,
                        StorageProvisioning.CREATE_MEMO,
                    )
                )
                .paymentConfirmed(42uL)
                .withCMCRequest(ByteArray(32) { 1 })
                .copy(
                    failure =
                        StorageCreationFailure(
                            StorageCreationFailureKind.CMC_REFUNDED,
                            "Creation refused",
                            ULong.MAX_VALUE,
                        )
                )
        compose.setContent { TaggrTheme { StorageCreationFailureDetails(record) } }
        compose.onNodeWithText("Original payment block: 42").assertExists()
        compose.onNodeWithText("Refund block: ${ULong.MAX_VALUE}").assertExists()
        compose.onNodeWithText("Creation refused").assertExists()
    }

    @Test
    fun missingRefundBlockDoesNotClaimAVerifiedRefundAmount() {
        val record =
            StorageCreationRecord(quote)
                .withPayment(
                    PendingTransfer(
                        quote.transfer,
                        ByteArray(32),
                        123uL,
                        StorageProvisioning.CREATE_MEMO,
                    )
                )
                .paymentConfirmed(42uL)
                .withCMCRequest(ByteArray(32) { 1 })
                .copy(
                    failure =
                        StorageCreationFailure(
                            StorageCreationFailureKind.CMC_REFUNDED,
                            "Creation refused",
                        )
                )
        compose.setContent { TaggrTheme { StorageCreationFailureDetails(record) } }
        compose
            .onNodeWithText(
                "CMC supplied no refund block. The refund amount has not been verified."
            )
            .assertExists()
    }
}
