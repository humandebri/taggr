package org.taggr.android

import android.accounts.Account
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.core.app.ActivityOptionsCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*
import org.taggr.android.ui.TaggrTheme

@RunWith(AndroidJUnit4::class)
class YouTubeUploadPermissionUITest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun deniedPickerInputRetainsMetadataAndDoesNotCreateOrDispatchUpload() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val denied = Uri.parse("content://org.taggr.android.test.denied-video/expired.mp4")
        val store = YouTubeUploadJobStore(context, "permission-${UUID.randomUUID()}")
        val target =
            YouTubeDraftTarget(
                "fixture-owner",
                "fixture-network",
                "fixture-canister",
                "fixture-channel",
                "new",
            )
        val closed = mutableStateOf(false)
        var picks = 0
        val registry =
            object : ActivityResultRegistry() {
                override fun <I, O> onLaunch(
                    requestCode: Int,
                    contract: ActivityResultContract<I, O>,
                    input: I,
                    options: ActivityOptionsCompat?,
                ) {
                    check(contract is ActivityResultContracts.PickVisualMedia) {
                        "Unexpected authorization/permission request"
                    }
                    picks++
                    dispatchResult(requestCode, denied)
                }
            }
        val registryOwner =
            object : ActivityResultRegistryOwner {
                override val activityResultRegistry = registry
            }
        assertFalse(YouTubeBackground.isRunning(context))
        try {
            compose.setContent {
                CompositionLocalProvider(LocalActivityResultRegistryOwner provides registryOwner) {
                    TaggrTheme {
                        if (!closed.value)
                            YouTubeUploadScreen(
                                target.owner,
                                target.network,
                                target.canister,
                                target.draftSlot,
                                { target.owner },
                                { error("Unexpected insertion") },
                                { closed.value = true },
                                jobStore = store,
                                initialAccess =
                                    YouTubeAuthorization.Access(
                                        "fixture-token",
                                        Account("test@example.test", "com.google"),
                                        YouTubeChannel(target.channelId, "Fixture channel"),
                                    ),
                            )
                    }
                }
            }
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Fixture channel").fetchSemanticsNodes().isNotEmpty()
            }
            compose
                .onNodeWithText("Title")
                .performScrollTo()
                .performTextInput("Retained video title")
            compose
                .onNodeWithText("Description")
                .performScrollTo()
                .performTextInput("Retained description")
            compose.onNodeWithText("Private").performScrollTo().performClick()
            compose.onNodeWithText("No").performScrollTo().performClick()
            compose
                .onNodeWithContentDescription("Accept YouTube terms and community guidelines")
                .performScrollTo()
                .performClick()
            compose.onNodeWithText("Choose video").performScrollTo().performClick()
            compose.waitUntil(10000) {
                compose
                    .onAllNodesWithText("Video preview unavailable. You can choose another video.")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            val before =
                context.contentResolver.call(denied, "attempts", null, null)!!.getInt("count")
            compose
                .onNodeWithText("Upload to YouTube")
                .performScrollTo()
                .assertIsEnabled()
                .performClick()
            compose.waitUntil(10000) {
                compose
                    .onAllNodesWithText(
                        "This action could not finish. Reconnect YouTube or reopen this draft to try again."
                    )
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            assertTrue(
                context.contentResolver.call(denied, "attempts", null, null)!!.getInt("count") >
                    before
            )
            compose
                .onNodeWithText("Title")
                .performScrollTo()
                .assertTextContains("Retained video title")
            compose
                .onNodeWithText("Description")
                .performScrollTo()
                .assertTextContains("Retained description")
            compose.onNodeWithText("Private").performScrollTo().assertIsSelected()
            compose.onNodeWithText("No").performScrollTo().assertIsSelected()
            compose
                .onNodeWithContentDescription("Accept YouTube terms and community guidelines")
                .performScrollTo()
                .assertIsOn()
            assertNull(runBlocking { store.discardSnapshot() })
            assertFalse(YouTubeBackground.isRunning(context))
            compose
                .onNodeWithText("Choose another video")
                .performScrollTo()
                .assertIsEnabled()
                .performClick()
            compose.runOnIdle { assertEquals(2, picks) }
            compose.onNodeWithText("Close").performClick()
            compose.onNodeWithText("YouTube Upload").assertDoesNotExist()
        } finally {
            runBlocking { store.clear(target) }
        }
    }
}
