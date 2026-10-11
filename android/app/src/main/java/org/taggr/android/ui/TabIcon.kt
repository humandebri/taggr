package org.taggr.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

/** Small system-style navigation symbols without another icon dependency. */
@Composable
fun TabIcon(index: Int) {
    val color = LocalContentColor.current
    Canvas(Modifier.size(24.dp)) {
        val unit = size.width / 24
        val stroke = Stroke(1.7f * unit)
        fun point(x: Float, y: Float) = Offset(x * unit, y * unit)
        when (index) {
            0 ->
                for (y in listOf(6f, 12f, 18f)) {
                    drawCircle(color, 1f * unit, point(3f, y))
                    drawLine(color, point(7f, y), point(21f, y), 1.7f * unit)
                }
            1 ->
                for (x in listOf(3f, 14f)) for (y in listOf(3f, 14f)) drawRect(
                    color,
                    point(x, y),
                    Size(7f * unit, 7f * unit),
                    style = stroke,
                )
            2 -> {
                val path =
                    Path().apply {
                        moveTo(4f * unit, 18f * unit)
                        lineTo(6f * unit, 15f * unit)
                        lineTo(6f * unit, 9f * unit)
                        cubicTo(6f * unit, 1f * unit, 18f * unit, 1f * unit, 18f * unit, 9f * unit)
                        lineTo(18f * unit, 15f * unit)
                        lineTo(20f * unit, 18f * unit)
                        close()
                    }
                drawPath(path, color, style = stroke)
                drawArc(
                    color,
                    0f,
                    180f,
                    false,
                    point(10f, 18f),
                    Size(4f * unit, 4f * unit),
                    style = stroke,
                )
            }
            3 -> {
                drawCircle(color, 10f * unit, point(12f, 12f), style = stroke)
                drawCircle(color, 3f * unit, point(12f, 9f), style = stroke)
                drawArc(
                    color,
                    180f,
                    180f,
                    false,
                    point(6f, 14f),
                    Size(12f * unit, 10f * unit),
                    style = stroke,
                )
            }
        }
    }
}
