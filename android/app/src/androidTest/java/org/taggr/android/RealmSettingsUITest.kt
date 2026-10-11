package org.taggr.android

import android.content.Context
import android.content.ContextWrapper
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.util.UUID
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class RealmSettingsUITest {
    @get:Rule val compose = createComposeRule()
    private val directory by lazy {
        File(
                ApplicationProvider.getApplicationContext<Context>().cacheDir,
                "realm-settings-${UUID.randomUUID()}",
            )
            .apply { mkdirs() }
    }
    private val context
        get() =
            object : ContextWrapper(ApplicationProvider.getApplicationContext<Context>()) {
                override fun getNoBackupFilesDir() = directory
            }

    private fun draft() = RealmSettingsDraft("Original", "#AABBCC", "10", "4", false, true)

    @After
    fun cleanup() {
        directory.deleteRecursively()
    }

    @Test
    fun editorRetainsFieldsAndSavesOnlyOnExplicitSave() {
        val draft = mutableStateOf(draft())
        var saved: RealmSettingsDraft? = null
        compose.setContent {
            TaggrTheme {
                RealmSettingsForm(
                    "TEST",
                    draft.value,
                    500uL,
                    false,
                    true,
                    null,
                    { draft.value = it },
                    {},
                    {},
                    { saved = draft.value },
                )
            }
        }
        compose.onNodeWithText("Description").performTextReplacement("Edited description")
        compose.onNodeWithText("Maximum downvotes").performScrollTo().performTextReplacement("12")
        assertNull(saved)
        compose.onNodeWithText("Save").performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals("Edited description", saved!!.description)
            assertEquals("12", saved!!.maxDownvotes)
            assertTrue(saved!!.commentsFiltering)
        }
    }

    @Test
    fun uncertainRealmUpdateBlocksAnotherSaveAndOffersRequestLookup() {
        var checked = false
        compose.setContent {
            TaggrTheme {
                RealmSettingsForm(
                    "TEST",
                    draft(),
                    500uL,
                    false,
                    false,
                    "Result unknown",
                    {},
                    {},
                    {},
                    { error("Second update dispatched") },
                    pending = true,
                    checkResult = { checked = true },
                )
            }
        }
        compose.onNodeWithText("Save").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("Check Realm update result").performScrollTo().performClick()
        assertTrue(checked)
    }

    @Test
    fun fullLogoArgumentsSurviveReloadAndCannotOverwritePendingChanges() {
        val mapper = ObjectMapper()
        val realm =
            mapper.readTree(
                """{"cleanup_penalty":10,"controllers":[7],"description":"Realm","filter":{"age_days":0,"safe":false,"balance":0,"num_followers":0},"label_color":"#AABBCC","last_setting_update":0,"last_update":0,"logo":"${"A".repeat(16384)}","max_downvotes":4,"num_members":0,"num_posts":0,"revenue":0,"theme":"","whitelist":[],"created":0,"posts":[],"adult_content":false,"comments_filtering":true}"""
            )
        val call =
            FinancialCall(
                "2vxsx-fae",
                "aaaaa-aa",
                "a".repeat(64),
                "edit_realm",
                ByteArray(32),
                mapper.writeValueAsBytes(listOf("TEST", realm)),
            )
        assertTrue(call.arguments.size > 8192)
        val store = FinancialCallStore(context)
        store.save(call)
        assertTrue(FinancialCallStore(context).load(call.owner, call.network)!!.matches(call))
        assertThrows(IllegalArgumentException::class.java) {
            store.save(call.copy(requestId = ByteArray(32) { 1 }))
        }
        store.clear(call)
        assertNull(store.load(call.owner, call.network))
    }
}
