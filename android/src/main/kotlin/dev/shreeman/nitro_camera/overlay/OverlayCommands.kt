package dev.shreeman.nitro_camera.overlay

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decoded `CameraOverlay` draw commands (Dart `CameraOverlay.encode`).
 * Coordinates are normalised to the upright frame (0..1, top-left origin);
 * sizes are fractions of the frame's shorter side. Platform-free (JVM-tested).
 */
sealed class OverlayCommand {
    abstract val argb: Int

    data class Rect(override val argb: Int, val l: Float, val t: Float, val r: Float, val b: Float, val stroke: Float) : OverlayCommand()
    data class Circle(override val argb: Int, val x: Float, val y: Float, val radius: Float, val stroke: Float) : OverlayCommand()
    data class Line(override val argb: Int, val x1: Float, val y1: Float, val x2: Float, val y2: Float, val stroke: Float) : OverlayCommand()
    data class Text(override val argb: Int, val x: Float, val y: Float, val size: Float, val text: String) : OverlayCommand()
}

object OverlayCommands {
    /** Parses the wire form; a malformed or unknown-version buffer yields what was read before the fault. */
    fun parse(data: ByteBuffer): List<OverlayCommand> {
        val buf = data.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        buf.rewind()
        if (buf.remaining() < 5 || buf.get().toInt() != 1) return emptyList()
        val count = buf.int
        val out = ArrayList<OverlayCommand>(count.coerceIn(0, 4096))
        try {
            repeat(count) {
                val op = buf.get().toInt()
                val argb = buf.int
                out += when (op) {
                    0 -> OverlayCommand.Rect(argb, buf.float, buf.float, buf.float, buf.float, buf.float)
                    1 -> OverlayCommand.Circle(argb, buf.float, buf.float, buf.float, buf.float)
                    2 -> OverlayCommand.Line(argb, buf.float, buf.float, buf.float, buf.float, buf.float)
                    3 -> {
                        val x = buf.float
                        val y = buf.float
                        val size = buf.float
                        val len = buf.int
                        val bytes = ByteArray(len)
                        buf.get(bytes)
                        OverlayCommand.Text(argb, x, y, size, String(bytes, Charsets.UTF_8))
                    }
                    else -> return out // unknown op: stop rather than misread the rest
                }
            }
        } catch (_: java.nio.BufferUnderflowException) {
        }
        return out
    }
}
