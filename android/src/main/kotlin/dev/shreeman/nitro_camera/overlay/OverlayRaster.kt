package dev.shreeman.nitro_camera.overlay

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint

/** Draws [OverlayCommand]s into a transparent ARGB bitmap of the frame's upright size. */
object OverlayRaster {
    fun render(commands: List<OverlayCommand>, width: Int, height: Int): Bitmap {
        val bmp = Bitmap.createBitmap(width.coerceAtLeast(1), height.coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val unit = minOf(width, height).toFloat()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        fun style(argb: Int, stroke: Float) {
            paint.color = argb
            if (stroke > 0f) {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = stroke * unit
            } else {
                paint.style = Paint.Style.FILL
            }
        }
        for (c in commands) {
            when (c) {
                is OverlayCommand.Rect -> {
                    style(c.argb, c.stroke)
                    canvas.drawRect(c.l * width, c.t * height, c.r * width, c.b * height, paint)
                }
                is OverlayCommand.Circle -> {
                    style(c.argb, c.stroke)
                    canvas.drawCircle(c.x * width, c.y * height, c.radius * unit, paint)
                }
                is OverlayCommand.Line -> {
                    style(c.argb, c.stroke.coerceAtLeast(0.001f))
                    canvas.drawLine(c.x1 * width, c.y1 * height, c.x2 * width, c.y2 * height, paint)
                }
                is OverlayCommand.Text -> {
                    paint.style = Paint.Style.FILL
                    paint.color = c.argb
                    paint.textSize = c.size * unit
                    // [y] is the text's top; drawText takes the baseline.
                    canvas.drawText(c.text, c.x * width, c.y * height - paint.ascent(), paint)
                }
            }
        }
        return bmp
    }
}
