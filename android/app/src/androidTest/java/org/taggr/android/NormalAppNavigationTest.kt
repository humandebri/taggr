package org.taggr.android

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.TaggrApi
import org.taggr.android.data.TaggrRuntime

/**
 * Real MainActivity + real ViewModels + native public requests; never signs in or dispatches
 * updates.
 */
@RunWith(AndroidJUnit4::class)
class NormalAppNavigationTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private var safetyBefore: String? = null
    private var changedTerms = false
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private val termsKey
        get() = "terms/${TaggrRuntime.configuration().canisterId}"

    private fun exists(matcher: SemanticsMatcher) =
        compose.onAllNodes(matcher).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()

    private fun await(matcher: SemanticsMatcher, timeout: Long = 30000) {
        compose.waitUntil(timeout) { exists(matcher) }
    }

    private fun tab(name: String) {
        compose.onNode(hasText(name) and hasClickAction()).performClick()
    }

    private fun back() {
        compose.onNode(hasText("Back") and hasClickAction()).performClick()
    }

    private fun screenshot(name: String) {
        val bitmap =
            InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                ?: error("Screenshot unavailable")
        File(context.cacheDir, name).outputStream().use {
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        bitmap.recycle()
    }

    @Before
    fun enterGuestApplication() {
        lateinit var account: AccountViewModel
        compose.runOnIdle {
            account = ViewModelProvider(compose.activity)[AccountViewModel::class.java]
        }
        compose.waitUntil(30000) { !account.state.value.restoring }
        assertNull(
            "Guest-only navigation test leaves any existing authenticated session intact.",
            account.state.value.principal,
        )
        val prefs = context.getSharedPreferences("taggr-safety", Context.MODE_PRIVATE)
        safetyBefore = prefs.getString(termsKey, null)
        if (exists(hasText("Agree and continue"))) {
            compose
                .onNodeWithText("I agree to the Terms of Use and safety rules")
                .performScrollTo()
                .performClick()
            compose.onNodeWithText("Agree and continue").performScrollTo().performClick()
            changedTerms = true
        }
        await(hasText("Feed") and hasClickAction())
    }

    @After
    fun restoreLocalConsentOnly() {
        if (changedTerms) {
            val edit = context.getSharedPreferences("taggr-safety", Context.MODE_PRIVATE).edit()
            if (safetyBefore == null) edit.remove(termsKey)
            else edit.putString(termsKey, safetyBefore)
            assertTrue(edit.commit())
        }
    }

    @Test
    fun supportAndPrivacyAreReachableFromGuestAccount() {
        tab("Account")
        compose
            .onNodeWithText("Connect YouTube")
            .performScrollTo()
            .assertIsDisplayed()
            .assertIsEnabled()
        compose.runOnIdle {
            val account = ViewModelProvider(compose.activity)[AccountViewModel::class.java]
            assertNull(account.state.value.principal)
            assertNull(account.youtubeAccess.value)
        }
        for (label in listOf("Terms of Use", "Privacy Policy", "Contact @FF on TAGGR")) compose
            .onNodeWithText(label)
            .performScrollTo()
            .assertIsDisplayed()
            .assertIsEnabled()
    }

    @Test
    fun normalRealmControllerProfileReturnsToTheSelectedRealm() =
        runBlocking<Unit> {
            val api = TaggrApi()
            try {
                val rows = api.jsonQuery("all_realms", listOf(TaggrRuntime.domain, "popularity", 0))
                val realm = rows.first {
                    !it[1].path("adult_content").asBoolean() && it[1].path("controllers").size() > 0
                }
                val name = realm[0].asText()
                val ids = realm[1]["controllers"].map { it.asText() }
                val names =
                    api.jsonQuery("users_data", listOf(ids.map { java.math.BigInteger(it) }))
                val controller = ids.first { names.path(it).isTextual }
                val expectedProfile = names[controller].asText()
                tab("Realms")
                val rowTag = "realm-list-$name"
                await(hasTestTag(rowTag))
                compose.onNodeWithTag(rowTag).performScrollTo().performClick()
                await(hasTestTag("realm-details"))
                compose.onNodeWithTag("realm-details").assertIsDisplayed()
                compose.onNodeWithText(name).assertIsDisplayed()
                val profileTag = "realm-controller-$controller"
                await(hasTestTag(profileTag))
                await(hasTestTag(profileTag) and hasText("@$expectedProfile"))
                compose.onNodeWithTag(profileTag).performScrollTo()
                screenshot("normal-app-realm.png")
                compose.onNodeWithTag(profileTag).performClick()
                await(hasTestTag("profile-name"))
                compose.onNodeWithTag("profile-name").assertTextEquals(expectedProfile)
                compose.onNodeWithTag("realm-details").assertDoesNotExist()
                compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
                await(hasTestTag("realm-details"))
                compose.onNodeWithTag(profileTag).assertIsDisplayed()
                compose.onNode(hasScrollToIndexAction()).performScrollToIndex(0)
                back()
                await(hasTestTag(rowTag))
                tab("Account")
                await(hasText("Continue with Internet Identity"))
                compose.onNodeWithText("Terms of Use").performScrollTo().assertIsDisplayed()
                compose.onNodeWithText("Privacy Policy").performScrollTo().assertIsDisplayed()
            } finally {
                api.close()
            }
        }

    @Test
    fun normalSearchTransactionsBackPreservesAccountSearchAndReturnsToFeed() {
        compose.onNode(hasText("Search") and hasClickAction()).performClick()
        await(hasText("Search TAGGR"))
        compose.onNodeWithText("Search TAGGR").performTextReplacement("2vxsx-fae")
        await(hasText("View transactions"))
        compose.onNodeWithText("View transactions").performClick()
        await(hasText("Transactions"))
        await(hasText("Balance:", substring = true))
        await(hasText("Refresh transactions") and isEnabled())
        screenshot("normal-app-transactions.png")
        back()
        await(hasText("Search TAGGR"))
        compose.onNodeWithText("Search TAGGR").assertTextContains("2vxsx-fae")
        back()
        await(hasText("TAGGR"))
        tab("Inbox")
        await(hasText("Sign in from Account to see your notifications."))
        tab("Account")
        await(hasText("Continue with Internet Identity"))
    }

    @Test
    fun incomingBrowsingLinkIsValidatedAndNotReplayedAfterRecreation() {
        fun link(value: String) {
            compose.runOnIdle {
                compose.activity.startActivity(
                    Intent(compose.activity, MainActivity::class.java)
                        .setAction(Intent.ACTION_VIEW)
                        .setData(Uri.parse(value))
                        .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                )
            }
        }
        val base = "https://${TaggrRuntime.domain}"
        link("$base/search/2vxsx-fae")
        await(hasText("Search TAGGR"))
        compose.onNodeWithText("Search TAGGR").assertTextContains("2vxsx-fae")
        compose.onNodeWithText("Search TAGGR").performTextReplacement("edited link query")
        compose.activityRule.scenario.recreate()
        await(hasText("Search TAGGR"))
        compose.onNodeWithText("Search TAGGR").assertTextContains("edited link query")
        link("$base/#/transactions/2vxsx-fae")
        await(hasText("Transactions"))
        await(hasText("Balance:", substring = true))
        link("https://evil.example/user/0")
        await(hasText("Transactions"))
        compose.onNodeWithText("Transactions").assertIsDisplayed()
        link("$base/android-auth-callback#delegation=not-a-session")
        await(hasText("Transactions"))
        compose.onNodeWithText("Transactions").assertIsDisplayed()
        link("$base/inbox")
        await(hasText("Sign in from Account to see your notifications."))
        link("$base/settings")
        await(hasText("Continue with Internet Identity"))
        link("$base/feed/ICP+TAGGR")
        await(hasText("#ICP + #TAGGR"))
        compose.runOnIdle {
            val pending = ViewModelProvider(compose.activity)[IncomingLinksViewModel::class.java]
            assertNull(pending.pending.value)
            assertEquals(TaggrApi.CANISTER_ID, TaggrRuntime.configuration().canisterId)
            assertArrayEquals(
                org.ic4j.agent.Agent.mainnetRootKey(),
                TaggrRuntime.configuration().rootKey,
            )
        }
    }
}
