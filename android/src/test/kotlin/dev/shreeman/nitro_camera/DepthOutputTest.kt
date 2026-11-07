package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.outputs.DepthOutput
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** DEPTH16 → float32 metres: range bits, confidence bits, stride padding. */
class DepthOutputTest {
    private fun convert(samples: List<Int>, w: Int, h: Int, rowStride: Int, pixelStride: Int = 2): FloatArray {
        val src = ByteBuffer.allocate(rowStride * h).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEachIndexed { i, v -> src.putShort((i / w) * rowStride + (i % w) * pixelStride, v.toShort()) }
        val dst = ByteBuffer.allocate(w * h * 4).order(ByteOrder.LITTLE_ENDIAN)
        DepthOutput.toMetres(src, rowStride, pixelStride, w, h, dst)
        dst.rewind()
        return FloatArray(w * h) { dst.float }
    }

    @Test
    fun millimetresBecomeMetres() {
        val out = convert(listOf(1500, 0, 8191, 1), w = 2, h = 2, rowStride = 4)
        assertEquals(listOf(1.5f, 0f, 8.191f, 0.001f), out.toList())
    }

    @Test
    fun confidenceBitsAreMaskedAndZeroConfidenceIsMissing() {
        val conf0 = (0 shl 13) or 2000 // 100 % confident
        val conf1 = (1 shl 13) or 2000 // "0 % confident" → missing
        val conf7 = (7 shl 13) or 2000 // 6/7 confident
        val out = convert(listOf(conf0, conf1, conf7), w = 3, h = 1, rowStride = 6)
        assertEquals(listOf(2f, 0f, 2f), out.toList())
    }

    @Test
    fun rowPaddingIsSkipped() {
        // 2x2 with an 8-byte stride: bytes 4..7 of each row are padding (0x7FFF).
        val src = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until 8) src.putShort(i * 2, 0x7FFF)
        src.putShort(0, 1000); src.putShort(2, 2000); src.putShort(8, 3000); src.putShort(10, 4000)
        val dst = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
        DepthOutput.toMetres(src, 8, 2, 2, 2, dst)
        dst.rewind()
        assertEquals(listOf(1f, 2f, 3f, 4f), List(4) { dst.float })
    }
}
