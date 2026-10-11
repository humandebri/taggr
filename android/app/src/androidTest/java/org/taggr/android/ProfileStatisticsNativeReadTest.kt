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
import org.junit.*
import org.junit.runner.RunWith
import org.taggr.android.data.*

@RunWith(AndroidJUnit4::class)
class ProfileStatisticsNativeReadTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun publicControllerStatisticsOpenTheirActualRealm() {
        val selected = runBlocking {
            TaggrApi().use { api ->
                val rows = api.jsonQuery("all_realms", listOf(TaggrRuntime.domain, "popularity", 0))
                val row = rows.first {
                    !it[1].path("adult_content").asBoolean() && it[1].path("controllers").size() > 0
                }
                val name = row[0].asText()
                val id = row[1].path("controllers").first().asText()
                val user = api.jsonQuery("user", listOf(TaggrRuntime.domain, listOf(id)))
                val decimals = api.jsonQuery("config").path("token_decimals").asInt()
                val stats = profileStatistics(user, decimals)
                require(stats.first { it.key == "controls-realms" }.realms.contains(name))
                Triple(id, name, stats)
            }
        }
        val expectedUser = runBlocking {
            TaggrApi().use {
                it.jsonQuery("user", listOf(TaggrRuntime.domain, listOf(selected.first)))
            }
        }
        val expectedPrincipal = expectedUser.path("principal").asText()
        require(expectedPrincipal.isNotEmpty()) { "The public profile must expose its Principal." }
        val expectedLinks = profileLinks(expectedUser)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("taggr-safety", Context.MODE_PRIVATE)
        val terms = "terms/${TaggrRuntime.configuration().canisterId}"
        val previous = prefs.getString(terms, null)
        var changed = false
        val intent =
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(Uri.parse("https://${TaggrRuntime.domain}/user/${selected.first}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ActivityScenario.launch<MainActivity>(intent).use { scenario ->
            try {
                lateinit var account: AccountViewModel
                scenario.onActivity {
                    account = ViewModelProvider(it)[AccountViewModel::class.java]
                }
                compose.waitUntil(30000) { !account.state.value.restoring }
                Assert.assertNull(
                    "Read test preserves existing signed-in sessions.",
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
                compose.waitUntil(30000) {
                    compose
                        .onAllNodesWithTag("profile-stat-controls-realms")
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                }
                for (stat in selected.third) {
                    compose
                        .onNodeWithTag("profile-stat-${stat.key}")
                        .assertContentDescriptionEquals("${stat.label}, ${stat.value}")
                }
                compose
                    .onNodeWithTag("profile-stat-controls-realms")
                    .performScrollTo()
                    .assertIsDisplayed()
                val bitmap =
                    requireNotNull(
                        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                    )
                File(context.cacheDir, "profile-stats-native.png").outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
                compose
                    .onNodeWithTag("profile-principal")
                    .performScrollTo()
                    .assertTextEquals(expectedPrincipal)
                    .assertIsDisplayed()
                for ((index, link) in expectedLinks.withIndex()) {
                    compose
                        .onNodeWithTag("profile-link-$index")
                        .assertTextEquals(link.label)
                        .assertHasClickAction()
                }
                val detailsImage =
                    requireNotNull(
                        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                    )
                File(context.cacheDir, "profile-details-native.png").outputStream().use {
                    detailsImage.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                detailsImage.recycle()
                compose.onNodeWithTag("profile-stat-controls-realms").performScrollTo()
                compose.onNodeWithTag("profile-stat-controls-realms").performClick()
                compose.onNodeWithTag("profile-realm-list").assertIsDisplayed()
                compose
                    .onNodeWithTag("profile-realm-${selected.second}")
                    .performScrollTo()
                    .performClick()
                compose.waitUntil(30000) {
                    compose.onAllNodesWithTag("realm-details").fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNodeWithText(selected.second).assertIsDisplayed()
                compose.onNodeWithTag("profile-realm-list").assertDoesNotExist()
                println(
                    "Public profile ${selected.first} opened controlled Realm ${selected.second}"
                )
            } finally {
                if (changed)
                    prefs
                        .edit()
                        .apply {
                            if (previous == null) remove(terms) else putString(terms, previous)
                        }
                        .commit()
            }
        }
    }
}
