package org.taggr.android

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.UUID
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class RealmCreationUITest {
    @get:Rule val compose = createComposeRule()
    private val directory by lazy {
        File(
                ApplicationProvider.getApplicationContext<Context>().cacheDir,
                "realm-creation-${UUID.randomUUID()}",
            )
            .apply { mkdirs() }
    }
    private val context
        get() =
            object : ContextWrapper(ApplicationProvider.getApplicationContext<Context>()) {
                override fun getNoBackupFilesDir() = directory
            }

    private fun draft() =
        RealmCreationDraft(
            RealmCreationDraft.defaults("7", "15").values +
                mapOf("name" to "TEST", "description" to "Description", "ownTheme" to "true")
        )

    private fun quote() =
        RealmCreationQuote(
            "2vxsx-fae",
            "e".repeat(64),
            7,
            "TEST",
            draft()
                .payload(
                    RealmCreationLimits(1000uL, 25, 500uL, 15u, "TAGGR"),
                    listOf(7uL),
                    emptyList(),
                )
                .toString(),
            RealmCreationLimits(1000uL, 25, 500uL, 15u, "TAGGR"),
            1000,
        )

    @After
    fun cleanup() {
        directory.deleteRecursively()
    }

    @Test
    fun createdMembershipOnlyOffersJoinWhenItIsNotConfirmed() {
        val joined = mutableStateOf(false)
        compose.setContent {
            TaggrTheme {
                RealmCreationForm(
                    draft(),
                    false,
                    true,
                    null,
                    false,
                    "TEST",
                    null,
                    null,
                    change = {},
                    close = {},
                    review = {},
                    check = {},
                    reload = {},
                    join = {},
                    open = {},
                    createdJoined = joined.value,
                )
            }
        }
        compose.onNodeWithText("Join Realm").assertIsDisplayed()
        compose.runOnIdle { joined.value = true }
        compose.onNodeWithText("Join Realm").assertDoesNotExist()
        compose.onNodeWithText("Open Realm").assertIsDisplayed()
    }

    @Test
    fun formRetainsDraftAcrossRecreationAndReviewDoesNotCreate() {
        val restoration = StateRestorationTester(compose)
        var reviewed: RealmCreationDraft? = null
        restoration.setContent {
            var values by rememberSaveable { mutableStateOf(draft().values) }
            TaggrTheme {
                RealmCreationForm(
                    RealmCreationDraft(values),
                    false,
                    true,
                    null,
                    false,
                    null,
                    null,
                    null,
                    { values = it.values },
                    {},
                    { reviewed = RealmCreationDraft(values) },
                    {},
                    {},
                    {},
                    {},
                )
            }
        }
        compose
            .onNode(hasText("Description") and hasSetTextAction())
            .performTextReplacement("Edited Realm")
        compose.onNodeWithText("Minimum followers").performScrollTo().performTextReplacement("25")
        compose
            .onNodeWithText("accent (#RRGGBB)")
            .performScrollTo()
            .performTextReplacement("#abcdef")
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithText("Minimum followers").performScrollTo().assertTextContains("25")
        assertNull(reviewed)
        compose.onNodeWithText("Review creation").performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals("Edited Realm", reviewed!!.values["description"])
            assertEquals("#abcdef", reviewed!!.values["theme_accent"])
        }
    }

    @Test
    fun confirmationShowsExactCostAndRequiresAnExplicitConfirmAction() {
        var creations = 0
        compose.setContent {
            TaggrTheme {
                RealmCreationConfirmation(
                    quote(),
                    "aaaaa-aa",
                    "fixture network",
                    false,
                    { creations++ },
                    {},
                )
            }
        }
        compose.onNodeWithText("Creation costs 1000 credits.").assertIsDisplayed()
        compose.onNodeWithText("Controllers: 7").assertIsDisplayed()
        assertEquals(0, creations)
        compose.onNodeWithText("Create for 1000 credits").performClick()
        compose.runOnIdle { assertEquals(1, creations) }
    }

    @Test
    fun uncertainCreationOnlyOffersOriginalResultLookupAndNoNewForm() {
        var checks = 0
        compose.setContent {
            TaggrTheme {
                RealmCreationForm(
                    draft(),
                    false,
                    false,
                    "TEST",
                    false,
                    null,
                    "Unconfirmed",
                    null,
                    {},
                    {},
                    { error("Another creation dispatched") },
                    { checks++ },
                    {},
                    {},
                    {},
                )
            }
        }
        compose.onNodeWithText("Review creation").assertDoesNotExist()
        compose.onNodeWithText("Realm name").assertDoesNotExist()
        compose.onNodeWithText("Check creation result").performClick()
        compose.runOnIdle { assertEquals(1, checks) }
    }

    @Test
    fun fullCreationRequestReloadsWithScopeAndCannotBeOverwritten() {
        val call =
            FinancialCall(
                "2vxsx-fae",
                "aaaaa-aa",
                "e".repeat(64),
                "create_realm",
                ByteArray(32) { it.toByte() },
                quote().arguments(),
            )
        FinancialCallStore(context).save(call)
        val restored = FinancialCallStore(context).load(call.owner, call.network)!!
        assertTrue(call.matches(restored))
        assertNull(FinancialCallStore(context).load(call.owner, "f".repeat(64)))
        assertThrows(IllegalArgumentException::class.java) {
            FinancialCallStore(context).save(call.copy(requestId = ByteArray(32)))
        }
        FinancialCallStore(context).clear(restored)
        assertNull(FinancialCallStore(context).load(call.owner, call.network))
    }
}
