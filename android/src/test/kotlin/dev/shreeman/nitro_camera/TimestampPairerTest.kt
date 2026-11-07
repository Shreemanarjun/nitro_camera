package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.outputs.TimestampPairer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Frame ↔ depth pairing by sensor timestamp (SyncOutput). */
class TimestampPairerTest {
    private val p = TimestampPairer<String, String>()

    @Test
    fun framesThenDepthPairOnTheSameTimestamp() {
        assertNull(p.offerFirst(100, "f100"))
        assertEquals("f100" to "d100", p.offerSecond(100, "d100"))
    }

    @Test
    fun depthThenFramePairToo() {
        assertNull(p.offerSecond(100, "d100"))
        assertEquals("f100" to "d100", p.offerFirst(100, "f100"))
    }

    @Test
    fun aPairIsDeliveredOnce() {
        p.offerFirst(100, "f100")
        p.offerSecond(100, "d100")
        assertNull(p.offerSecond(100, "d100-again"))
    }

    @Test
    fun aNewerFrameReplacesAnUnmatchedOlderOne() {
        p.offerFirst(100, "f100")
        p.offerFirst(133, "f133")
        assertNull(p.offerSecond(100, "d100"))
        assertEquals("f133" to "d133", p.offerSecond(133, "d133"))
    }

    @Test
    fun depthAtLowerRateMatchesOnlyItsOwnFrame() {
        // 30 fps video, 15 fps depth: every other frame has a partner.
        val pairs = mutableListOf<Pair<String, String>>()
        for (i in 0 until 6) {
            val ts = i * 33L
            p.offerFirst(ts, "f$ts")?.let(pairs::add)
            if (i % 2 == 0) p.offerSecond(ts, "d$ts")?.let(pairs::add)
        }
        assertEquals(listOf("f0" to "d0", "f66" to "d66", "f132" to "d132"), pairs)
    }

    @Test
    fun aStaleDepthIsDroppedOnceANewerFrameArrives() {
        p.offerSecond(100, "d100")
        assertNull(p.offerFirst(133, "f133"))
        assertNull(p.offerFirst(100, "f100-late")) // d100 is gone
    }
}
