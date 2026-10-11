package org.taggr.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.math.BigInteger
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class StorageTest {
    @get:Rule val compose = createComposeRule()
    private val status =
        StorageStatus(
            "rrkah-fqaaa-aaaaa-aaaaq-cai",
            "running",
            listOf("2vxsx-fae"),
            "a".repeat(64),
            BigInteger.TEN,
            BigInteger.valueOf(100),
            BigInteger.TEN,
            "a".repeat(64),
        )

    @Test
    fun registrationRequiresExplicitReviewAndShowsControllers() {
        var confirmed = false
        compose.setContent {
            TaggrTheme {
                StorageConfirmation(
                    StorageQuote("2vxsx-fae", 7, status, 1),
                    "aaaaa-aa",
                    "Test network",
                    false,
                    {},
                ) {
                    confirmed = true
                }
            }
        }
        compose.onNodeWithText("Storage: ${status.bucket}").assertExists()
        compose.onNodeWithText("2vxsx-fae").assertExists()
        compose.onNodeWithText("Test network").assertExists()
        assertFalse(confirmed)
        compose.onNodeWithText("Register", useUnmergedTree = true).performClick()
        assertTrue(confirmed)
    }

    @Test
    fun storageMetricsKeepIntegerPrecisionAndDistinguishZeroBurn() {
        compose.setContent {
            TaggrTheme {
                StorageMetrics(
                    status.copy(cycles = BigInteger.ONE.shiftLeft(90), dailyBurn = BigInteger.ZERO)
                )
            }
        }
        compose.onNodeWithText("Cycles: ${BigInteger.ONE.shiftLeft(90)}").assertExists()
        compose.onNodeWithText("Estimated days remaining: —").assertExists()
        compose.onNodeWithText("TAGGR storage is up to date").assertExists()
    }

    @Test
    fun readsActualMainnetStorageModuleHash() =
        kotlinx.coroutines.runBlocking {
            TaggrApi().use { api ->
                val value = api.jsonQuery("bucket_wasm_hash")
                check(value.isTextual && value.asText().matches(Regex("[0-9a-f]{64}")))
            }
        }
}
