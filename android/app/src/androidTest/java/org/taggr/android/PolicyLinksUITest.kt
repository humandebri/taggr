package org.taggr.android

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.ui.*

@RunWith(AndroidJUnit4::class)
class PolicyLinksUITest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun publicLinksWrapAtLargeTextAndOpenTheExactIOSDestinations() {
        val urls = mutableListOf<String>()
        compose.setContent {
            TaggrTheme {
                val density = LocalDensity.current
                CompositionLocalProvider(LocalDensity provides Density(density.density, 1.5f)) {
                    Box(Modifier.width(300.dp)) { PolicyLinks { urls.add(it.toString()) } }
                }
            }
        }
        for (label in listOf("Terms of Use", "Privacy Policy", "Contact @FF on TAGGR")) compose
            .onNodeWithText(label)
            .assertIsDisplayed()
            .assertIsEnabled()
            .performClick()
        compose.runOnIdle {
            assertEquals(
                listOf(
                    "https://taggr.kasane.network/terms",
                    "https://taggr.kasane.network/privacy-policy",
                    "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/user/FF",
                ),
                urls,
            )
        }
    }
}
