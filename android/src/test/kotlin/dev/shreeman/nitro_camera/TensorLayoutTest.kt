package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.TensorLayout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** GL read-back (bottom-up RGBA) → top-down tensor layouts. */
class TensorLayoutTest {
    // 2x2 image; GL rows bottom-up: row0 = bottom (B1, B2), row1 = top (T1, T2).
    private fun gl(): ByteBuffer = ByteBuffer.wrap(byteArrayOf(
        10, 11, 12, 13, 20, 21, 22, 23, // bottom row
        30, 31, 32, 33, 40, 41, 42, 43, // top row
    ))

    @Test
    fun rgbUint8IsTopDown() {
        val out = ByteBuffer.allocate(12)
        TensorLayout.fromGlRgba(gl(), 2, 2, 3, bgr = false, float32 = false, out = out)
        assertArrayEquals(byteArrayOf(30, 31, 32, 40, 41, 42, 10, 11, 12, 20, 21, 22), out.array())
    }

    @Test
    fun bgraKeepsAlphaAndSwapsRedBlue() {
        val out = ByteBuffer.allocate(16)
        TensorLayout.fromGlRgba(gl(), 2, 2, 4, bgr = true, float32 = false, out = out)
        assertArrayEquals(byteArrayOf(32, 31, 30, 33, 42, 41, 40, 43, 12, 11, 10, 13, 22, 21, 20, 23), out.array())
    }

    @Test
    fun float32IsNormalised() {
        val px = ByteBuffer.wrap(byteArrayOf(0, 255.toByte(), 51, 0))
        val out = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN)
        TensorLayout.fromGlRgba(px, 1, 1, 3, bgr = false, float32 = true, out = out)
        out.flip()
        assertEquals(0f, out.float, 1e-6f)
        assertEquals(1f, out.float, 1e-6f)
        assertEquals(0.2f, out.float, 1e-6f)
    }
}
