package org.taggr.android

import android.Manifest
import android.app.NotificationManager
import android.app.job.JobScheduler
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.taggr.android.data.*

/** Actual OS services; missing TAGGR owner must stop before any Google authorization. */
@RunWith(AndroidJUnit4::class)
class YouTubeBackgroundDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun target(): YouTubeDraftTarget {
        val config = TaggrRuntime.configuration()
        return YouTubeDraftTarget(
            "test-owner",
            financialNetwork(config),
            config.canisterId,
            "channel",
            "new",
        )
    }

    private fun checkService(fallback: Boolean) {
        val namespace = "test-" + UUID.randomUUID()
        val store = YouTubeUploadJobStore(context, namespace)
        val target = target()
        val original = runBlocking {
            store.create(
                ByteArrayInputStream(byteArrayOf(1, 2, 3)),
                target,
                YouTubeUploadMetadata(
                    "Fixture",
                    madeForKids = false,
                    communityGuidelinesAccepted = true,
                ),
                "video/mp4",
                googleAccountEmail = "test@example.test",
            )
        }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        if (android.os.Build.VERSION.SDK_INT >= 33)
            automation.grantRuntimePermission(
                context.packageName,
                Manifest.permission.POST_NOTIFICATIONS,
            )
        runBlocking { YouTubeBackground.dispatch.lock() }
        var locked = true
        try {
            compose.setContent { Text("Upload service test") }
            YouTubeBackground.observeOwner(context, null)
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.cancel(YouTubeBackground.NOTIFICATION_ID)
            compose.runOnIdle {
                if (fallback)
                    YouTubeBackground.startFallback(
                        context,
                        YouTubeBackground.extras(original, namespace),
                    )
                else YouTubeBackground.start(context, original, namespace)
                assertTrue(
                    YouTubeBackground.isRunningForDraft(
                        context,
                        target.owner,
                        target.network,
                        target.canister,
                        target.draftSlot,
                    )
                )
            }
            compose.waitUntil(10000) {
                YouTubeBackground.isRunningForDraft(
                    context,
                    target.owner,
                    target.network,
                    target.canister,
                    target.draftSlot,
                )
            }
            assertFalse(
                YouTubeBackground.isRunningForDraft(
                    context,
                    "other-owner",
                    target.network,
                    target.canister,
                    target.draftSlot,
                )
            )
            assertFalse(
                YouTubeBackground.isRunningForDraft(
                    context,
                    target.owner,
                    "other-network",
                    target.canister,
                    target.draftSlot,
                )
            )
            assertFalse(
                YouTubeBackground.isRunningForDraft(
                    context,
                    target.owner,
                    target.network,
                    "other-canister",
                    target.draftSlot,
                )
            )
            assertFalse(
                YouTubeBackground.isRunningForDraft(
                    context,
                    target.owner,
                    target.network,
                    target.canister,
                    "reply/42",
                )
            )
            YouTubeBackground.dispatch.unlock()
            locked = false
            val pausedStarted = android.os.SystemClock.elapsedRealtime()
            var reported = false
            compose.waitUntil(15000) {
                if (!reported && android.os.SystemClock.elapsedRealtime() - pausedStarted > 5000) {
                    reported = true
                    val entries =
                        manager.activeNotifications.map {
                            "${it.id}: ${it.notification.extras.getCharSequence("android.text")}, flags=${it.notification.flags}"
                        }
                    InstrumentationRegistry.getInstrumentation()
                        .sendStatus(
                            2,
                            android.os.Bundle().apply {
                                putString(
                                    "stream",
                                    "SDK=${android.os.Build.VERSION.SDK_INT}, fallback=$fallback, enabled=${manager.areNotificationsEnabled()}, running=${YouTubeBackground.isRunning(context)}, notifications=$entries\n",
                                )
                            },
                        )
                    val dump = automation.executeShellCommand("dumpsys notification")
                    val text =
                        android.os.ParcelFileDescriptor.AutoCloseInputStream(dump)
                            .bufferedReader()
                            .use { it.readText() }
                    java.io
                        .File(context.cacheDir, "api33-notification-diagnostic.txt")
                        .writeText(text)
                    val relevant =
                        text
                            .lineSequence()
                            .filter {
                                it.contains("org.taggr.android") ||
                                    it.contains("fgs", true) ||
                                    it.contains("defer", true)
                            }
                            .take(30)
                            .joinToString("\n")
                    InstrumentationRegistry.getInstrumentation()
                        .sendStatus(
                            2,
                            android.os.Bundle().apply { putString("stream", "$relevant\n") },
                        )
                }
                manager.activeNotifications.any {
                    it.id == YouTubeBackground.NOTIFICATION_ID &&
                        it.notification.extras
                            .getCharSequence("android.text")
                            ?.contains("paused") == true
                }
            }
            compose.waitUntil(10000) { !YouTubeBackground.isRunning(context) }
            assertEquals(original, runBlocking { store.load(target) })
            assertTrue(store.source(original).exists())
            assertNull(
                context
                    .getSystemService(JobScheduler::class.java)
                    .getPendingJob(YouTubeBackground.JOB_ID)
            )
            val paused =
                manager.activeNotifications
                    .single { it.id == YouTubeBackground.NOTIFICATION_ID }
                    .notification
            assertEquals(0, paused.flags and android.app.Notification.FLAG_ONGOING_EVENT)
        } finally {
            if (locked) YouTubeBackground.dispatch.unlock()
            runBlocking {
                YouTubeBackground.pauseAndWait(context)
                store.clear(target)
            }
            context
                .getSystemService(NotificationManager::class.java)
                .cancel(YouTubeBackground.NOTIFICATION_ID)
        }
    }

    @Test
    fun platformBackgroundRoutePreservesSavedUploadWhenTaggrAccountIsUnavailable() =
        checkService(false)

    @Test
    fun actualForegroundFallbackStopsWithoutDeletingProgressWhenAccountIsUnavailable() =
        checkService(true)

    @Test
    fun failedFallbackStartClearsQueuedDraftOwnership() {
        val blocked =
            object : android.content.ContextWrapper(context) {
                override fun startForegroundService(
                    intent: Intent
                ): android.content.ComponentName? {
                    throw IllegalStateException("fixture start failure")
                }
            }
        val values =
            android.os.PersistableBundle().apply {
                putString("owner", "queued-owner")
                putString("network", "network")
                putString("canister", "canister")
                putString("draft", "new")
            }
        try {
            YouTubeBackground.startFallback(blocked, values)
            fail("Expected start failure")
        } catch (_: IllegalStateException) {}
        assertFalse(
            YouTubeBackground.isRunningForDraft(
                context,
                "queued-owner",
                "network",
                "canister",
                "new",
            )
        )
    }

    @Test
    fun schedulingExtrasContainNoGoogleAccountTokenOrSessionCapability() = runBlocking {
        val namespace = "test-" + UUID.randomUUID()
        val store = YouTubeUploadJobStore(context, namespace)
        val target = target()
        val original =
            store.create(
                ByteArrayInputStream(byteArrayOf(1)),
                target,
                YouTubeUploadMetadata(
                    "Private title",
                    madeForKids = false,
                    communityGuidelinesAccepted = true,
                ),
                "video/mp4",
                googleAccountEmail = "test@example.test",
            )
        try {
            val session =
                original.copy(
                    phase = YouTubeJobPhase.CHECKING,
                    sessionUrl =
                        "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=secret-session",
                )
            val extras = YouTubeBackground.extras(session, namespace)
            val joined = extras.keySet().joinToString { "$it=${extras.getString(it)}" }
            assertFalse(joined.contains("test@example.test"))
            assertFalse(joined.contains("secret-session"))
            assertFalse(joined.contains("Private title"))
            assertEquals(session.id, extras.getString("id"))
        } finally {
            store.clear(target)
        }
    }
}
