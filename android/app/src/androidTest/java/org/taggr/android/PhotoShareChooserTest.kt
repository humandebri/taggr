package org.taggr.android

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PhotoShareChooserTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun systemImageChooserOpensAndCancellationReturnsWithoutSelectingRecipient() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.BLUE)
        val bytes =
            ByteArrayOutputStream()
                .also {
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
                }
                .toByteArray()
        bitmap.recycle()
        val send =
            preparedPhotoShareIntent(
                context,
                AccountPhoto(7, 0, "https://images.example/chooser.png", "", 0),
                bytes,
            )
        compose.runOnUiThread {
            compose.activity.startActivity(Intent.createChooser(send, "Share image"))
        }
        assertSystemImageChooserAndCancel("photo-share-chooser")
    }
}
