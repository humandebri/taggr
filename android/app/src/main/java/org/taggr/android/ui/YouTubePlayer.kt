package org.taggr.android.ui

import android.annotation.SuppressLint
import android.view.View
import android.view.ViewGroup
import android.webkit.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.taggr.android.data.PostBodyBlock

internal val LocalVideoActive = staticCompositionLocalOf { true }

/** Each view owns its lifecycle and is destroyed when its visible content leaves composition. */
internal class VideoWebView(context: android.content.Context) : WebView(context) {
    var released = false
        private set

    fun release() {
        if (released) return
        released = true
        stopLoading()
        onPause()
        (parent as? ViewGroup)?.removeView(this)
        removeAllViews()
        destroy()
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
internal fun YouTubePlayer(video: PostBodyBlock.YouTube) {
    val active = LocalVideoActive.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var visible by remember(video.id) { mutableStateOf(false) }
    var web by remember(video.id) { mutableStateOf<VideoWebView?>(null) }
    var error by remember(video.id) { mutableStateOf(false) }
    var fullScreen by remember(video.id) { mutableStateOf<View?>(null) }
    var callback by remember(video.id) { mutableStateOf<WebChromeClient.CustomViewCallback?>(null) }
    fun hideFullScreen() {
        fullScreen = null
        callback?.onCustomViewHidden()
        callback = null
    }
    DisposableEffect(lifecycle, web) {
        val view = web
        val observer = LifecycleEventObserver { _, event ->
            if (view?.released == false)
                when (event) {
                    Lifecycle.Event.ON_RESUME -> view.onResume()
                    Lifecycle.Event.ON_PAUSE -> {
                        hideFullScreen()
                        view.onPause()
                    }
                    else -> Unit
                }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    Box(
        Modifier.fillMaxWidth()
            .aspectRatio(16f / 9f)
            .clip(RoundedCornerShape(10.dp))
            .background(Color.Black)
            .testTag("youtube-${video.id}")
            .semantics { contentDescription = "YouTube video" }
            .onGloballyPositioned {
                val bounds = it.boundsInWindow()
                // Window bounds are already clipped. The Android host View can still have
                // height zero during restoration even though Compose has laid out this box.
                visible = bounds.width > 0 && bounds.height > 0
            }
    ) {
        if (visible && active && !error)
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { context ->
                    VideoWebView(context).apply {
                        web = this
                        setBackgroundColor(android.graphics.Color.BLACK)
                        isVerticalScrollBarEnabled = false
                        isHorizontalScrollBarEnabled = false
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.mediaPlaybackRequiresUserGesture = true
                        settings.allowFileAccess = false
                        settings.allowContentAccess = false
                        settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                        webViewClient =
                            object : WebViewClient() {
                                override fun onReceivedError(
                                    view: WebView,
                                    request: WebResourceRequest,
                                    errorInfo: WebResourceError,
                                ) {
                                    if (request.isForMainFrame) error = true
                                }

                                override fun onReceivedHttpError(
                                    view: WebView,
                                    request: WebResourceRequest,
                                    response: WebResourceResponse,
                                ) {
                                    if (request.isForMainFrame && response.statusCode >= 400)
                                        error = true
                                }

                                override fun onRenderProcessGone(
                                    view: WebView,
                                    detail: RenderProcessGoneDetail,
                                ): Boolean {
                                    error = true
                                    (view as VideoWebView).release()
                                    return true
                                }

                                override fun shouldOverrideUrlLoading(
                                    view: WebView,
                                    request: WebResourceRequest,
                                ): Boolean {
                                    if (!request.isForMainFrame) return false
                                    val uri = request.url
                                    if (
                                        uri.scheme == "https" &&
                                            uri.host in
                                                setOf(
                                                    "www.youtube.com",
                                                    "youtube.com",
                                                    "m.youtube.com",
                                                ) &&
                                            uri.path?.startsWith("/embed/") == true
                                    )
                                        return false
                                    if (request.hasGesture() && uri.scheme == "https")
                                        context.startActivity(
                                            android.content.Intent(
                                                android.content.Intent.ACTION_VIEW,
                                                uri,
                                            )
                                        )
                                    return true
                                }
                            }
                        webChromeClient =
                            object : WebChromeClient() {
                                override fun onShowCustomView(
                                    view: View,
                                    customCallback: CustomViewCallback,
                                ) {
                                    if (fullScreen != null) customCallback.onCustomViewHidden()
                                    else {
                                        fullScreen = view
                                        callback = customCallback
                                    }
                                }

                                override fun onHideCustomView() {
                                    hideFullScreen()
                                }
                            }
                        loadUrl(video.embedUrl, video.headers(context.packageName))
                    }
                },
                onRelease = { view ->
                    hideFullScreen()
                    view.release()
                    if (web === view) web = null
                },
            )
        if (error)
            Column(
                Modifier.fillMaxSize().padding(12.dp),
                verticalArrangement = Arrangement.Center,
            ) {
                Text("YouTube video could not be loaded.")
                TextButton(onClick = { error = false }) { Text("Retry video") }
            }
    }
    fullScreen?.let { view ->
        Dialog(
            onDismissRequest = { hideFullScreen() },
            properties =
                DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
        ) {
            Column(Modifier.fillMaxSize().background(Color.Black).safeDrawingPadding()) {
                TextButton(onClick = { hideFullScreen() }) { Text("Close video") }
                AndroidView(
                    factory = { view },
                    modifier =
                        Modifier.weight(1f).fillMaxWidth().testTag("youtube-fullscreen-player"),
                    onRelease = { (it.parent as? ViewGroup)?.removeView(it) },
                )
            }
        }
    }
}
