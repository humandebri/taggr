package org.taggr.android

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.fasterxml.jackson.databind.ObjectMapper
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrApi
import org.taggr.android.data.WalletSnapshot
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class WalletTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun displaysTokenUnitsAndWithdrawableTreasuryRatherThanRawRewards() {
        val user =
            ObjectMapper()
                .readTree(
                    """{"balance":12345,"cycles":1000,"rewards":999,"treasury_e8s":200000001}"""
                )
        compose.setContent {
            TaggrTheme { WalletMetrics(user, WalletSnapshot("2vxsx-fae", 123400000u, 10000u, 2)) }
        }
        compose.onNodeWithText("123.45").assertIsDisplayed()
        compose.onNodeWithText("1000").assertIsDisplayed()
        compose.onNodeWithText("1.234").assertIsDisplayed()
        compose.onNodeWithText("2.00000001").assertIsDisplayed()
        compose.onNodeWithText("999").assertDoesNotExist()
    }

    @Test
    fun recoveryMetricsRetainAssetsAndOmitUnusableCredits() {
        val user =
            ObjectMapper().readTree("""{"balance":12345,"cycles":1000,"treasury_e8s":200000001}""")
        compose.setContent {
            TaggrTheme {
                WalletMetrics(
                    user,
                    WalletSnapshot("2vxsx-fae", 123400000u, 10000u, 2),
                    showCredits = false,
                )
            }
        }
        compose.onNodeWithText("123.45").assertIsDisplayed()
        compose.onNodeWithText("1.234").assertIsDisplayed()
        compose.onNodeWithText("2.00000001").assertIsDisplayed()
        compose.onNodeWithText("Credits").assertDoesNotExist()
        compose.onNodeWithText("1000").assertDoesNotExist()
    }

    @Test
    fun readsRealLedgerBalanceFeeAndTaggrDecimalsWithoutSigning() = runBlocking {
        TaggrApi().use { api ->
            val snapshot = api.wallet("2vxsx-fae")
            assertEquals("2vxsx-fae", snapshot.owner)
            assertTrue(snapshot.feeE8s > 0uL)
            assertTrue(snapshot.tokenDecimals in 0..255)
        }
    }
}
