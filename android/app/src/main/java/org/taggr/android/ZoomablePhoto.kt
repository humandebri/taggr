package org.taggr.android

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/** Reuses the sampled bitmap; zooming never allocates a larger decoded image. */
@Composable
internal fun ZoomablePhoto(
    bitmap: Bitmap,
    description: String,
    modifier: Modifier,
    zoomChanged: (Boolean) -> Unit,
    backgroundTap: () -> Unit = {},
) {
    var scale by remember(bitmap) { mutableFloatStateOf(1f) }
    var offset by remember(bitmap) { mutableStateOf(Offset.Zero) }
    val notify by rememberUpdatedState(zoomChanged)
    val dismiss by rememberUpdatedState(backgroundTap)
    LaunchedEffect(scale > 1f) { notify(scale > 1f) }
    var viewport by remember { mutableStateOf(IntSize.Zero) }
    val density = LocalDensity.current
    val width = viewport.width.toFloat()
    val height = viewport.height.toFloat()
    val inset = with(density) { 18.dp.toPx() }
    val fit =
        minOf(
            (width - inset * 2).coerceAtLeast(1f) / bitmap.width,
            (height - inset * 2).coerceAtLeast(1f) / bitmap.height,
        )
    val imageWidth = bitmap.width * fit
    val imageHeight = bitmap.height * fit
    fun bounded(value: Offset, zoom: Float): Offset {
        val x = ((imageWidth * zoom - width) / 2).coerceAtLeast(0f)
        val y = ((imageHeight * zoom - height) / 2).coerceAtLeast(0f)
        return Offset(value.x.coerceIn(-x, x), value.y.coerceIn(-y, y))
    }
    // Keep input in stable viewport coordinates, outside the transformed image layer.
    val transform = rememberTransformableState { centroid, zoom, pan, _ ->
        val next = (scale * zoom).coerceIn(1f, 4f)
        val ratio = next / scale
        val pivot =
            if (centroid.x.isFinite() && centroid.y.isFinite())
                centroid - Offset(width / 2, height / 2)
            else Offset.Zero
        // Retain the gesture's unclamped focal translation while the fitted margins
        // disappear. Clamping every delta discards the anchor at small zoom levels.
        offset = if (next == 1f) Offset.Zero else offset * ratio + pivot * (1 - ratio) + pan
        scale = next
    }
    LaunchedEffect(width, height, transform.isTransformInProgress) {
        if (!transform.isTransformInProgress) offset = bounded(offset, scale)
    }
    Box(
        modifier
            .clipToBounds()
            .onSizeChanged { viewport = it }
            .transformable(transform, canPan = { scale > 1f }),
        contentAlignment = Alignment.Center,
    ) {
        // A separate sibling receives only taps outside the fitted/transformed image.
        Box(
            Modifier.matchParentSize().pointerInput(Unit) {
                detectTapGestures(onTap = { dismiss() })
            }
        )
        Image(
            bitmap.asImageBitmap(),
            description,
            Modifier.size(with(density) { imageWidth.toDp() }, with(density) { imageHeight.toDp() })
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    val displayed = bounded(offset, scale)
                    translationX = displayed.x
                    translationY = displayed.y
                }
                .pointerInput(bitmap) {
                    detectTapGestures(
                        onTap = {},
                        onDoubleTap = {
                            scale = if (scale > 1f) 1f else 2.5f
                            offset = Offset.Zero
                        },
                    )
                }
                .semantics { stateDescription = "${(scale * 100).roundToInt()}% zoom" },
        )
    }
}
