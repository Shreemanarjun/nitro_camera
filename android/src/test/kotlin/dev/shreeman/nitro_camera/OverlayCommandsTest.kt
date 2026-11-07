package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.overlay.OverlayCommand
import dev.shreeman.nitro_camera.overlay.OverlayCommands
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** The CameraOverlay wire format (Dart CameraOverlay.encode). */
class OverlayCommandsTest {
    private fun wire(build: ByteBuffer.() -> Unit): ByteBuffer =
        ByteBuffer.allocate(512).order(ByteOrder.LITTLE_ENDIAN).apply(build).also { it.flip() }

    @Test
    fun decodesEveryOp() {
        val text = "QR ✓".toByteArray(Charsets.UTF_8)
        val buf = wire {
            put(1); putInt(4)
            put(0); putInt(0xFF00FF00.toInt()); putFloat(0.1f); putFloat(0.2f); putFloat(0.5f); putFloat(0.6f); putFloat(0.006f)
            put(1); putInt(0x80FF0000.toInt()); putFloat(0.5f); putFloat(0.5f); putFloat(0.1f); putFloat(0f)
            put(2); putInt(-1); putFloat(0f); putFloat(0f); putFloat(1f); putFloat(1f); putFloat(0.01f)
            put(3); putInt(0xFFFFFFFF.toInt()); putFloat(0.2f); putFloat(0.18f); putFloat(0.04f); putInt(text.size); put(text)
        }
        val cmds = OverlayCommands.parse(buf)
        assertEquals(
            listOf(
                OverlayCommand.Rect(0xFF00FF00.toInt(), 0.1f, 0.2f, 0.5f, 0.6f, 0.006f),
                OverlayCommand.Circle(0x80FF0000.toInt(), 0.5f, 0.5f, 0.1f, 0f),
                OverlayCommand.Line(-1, 0f, 0f, 1f, 1f, 0.01f),
                OverlayCommand.Text(0xFFFFFFFF.toInt(), 0.2f, 0.18f, 0.04f, "QR ✓"),
            ),
            cmds,
        )
    }

    @Test
    fun anEmptyOverlayClears() {
        assertTrue(OverlayCommands.parse(wire { put(1); putInt(0) }).isEmpty())
    }

    @Test
    fun anUnknownVersionOrTruncatedBufferIsSafe() {
        assertTrue(OverlayCommands.parse(wire { put(2); putInt(1) }).isEmpty())
        val truncated = wire { put(1); putInt(2); put(1); putInt(-1); putFloat(0.5f); putFloat(0.5f); putFloat(0.1f); putFloat(0f); put(0); putInt(-1); putFloat(0.1f) }
        assertEquals(1, OverlayCommands.parse(truncated).size)
    }
}
