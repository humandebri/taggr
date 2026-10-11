package org.taggr.android

import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.*
import org.junit.Assert.*
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrRuntime

@RunWith(AndroidJUnit4::class)
class BeforeConsentHelpTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    private var original: String? = null
    private val termsKey
        get() = "terms/${TaggrRuntime.configuration().canisterId}"

    private val preferences
        get() =
            InstrumentationRegistry.getInstrumentation()
                .targetContext
                .getSharedPreferences("taggr-safety", Context.MODE_PRIVATE)

    private val withoutConsent =
        object : ExternalResource() {
            override fun before() {
                original = preferences.getString(termsKey, null)
                assertTrue(preferences.edit().remove(termsKey).commit())
            }

            override fun after() {
                val edit = preferences.edit()
                if (original == null) edit.remove(termsKey) else edit.putString(termsKey, original)
                assertTrue(edit.commit())
            }
        }
    @get:Rule val rules: RuleChain = RuleChain.outerRule(withoutConsent).around(compose)

    @Test
    fun publicHelpIsAvailableOnARealFreshLaunchWithoutConsentOrIdentity() {
        lateinit var account: AccountViewModel
        compose.runOnIdle {
            account = ViewModelProvider(compose.activity)[AccountViewModel::class.java]
        }
        compose.waitUntil(30000) { !account.state.value.restoring }
        assertNull("This test leaves any existing identity intact.", account.state.value.principal)
        compose.onNodeWithText("Terms & safety").assertIsDisplayed()
        for (label in listOf("Terms of Use", "Privacy Policy", "Contact @FF on TAGGR")) compose
            .onNodeWithText(label)
            .performScrollTo()
            .assertIsDisplayed()
            .assertIsEnabled()
        compose.onNodeWithText("Agree and continue").performScrollTo().assertIsNotEnabled()
        assertFalse(account.state.value.acceptedTerms)
    }
}
