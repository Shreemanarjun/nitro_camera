package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.outputs.ParkingSlot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The hand-off slot behind persistent recordings (ParkedVideoRecording). */
class ParkingSlotTest {
    private val unclaimed = mutableListOf<String>()
    private val deadlines = mutableListOf<Runnable>()
    private val slot = ParkingSlot<String>(10_000) { unclaimed += it }
    private fun park(v: String) = slot.park(v) { delay, run ->
        assertEquals(10_000L, delay)
        deadlines += run
    }

    @Test
    fun claimTakesTheParkedItemOnceAndCancelsItsDeadline() {
        assertNull(park("a"))
        assertTrue(slot.isWaiting)
        assertEquals("a", slot.claim())
        assertNull(slot.claim())
        assertFalse(slot.isWaiting)
        deadlines.single().run()
        assertTrue("a claimed item is never finalised", unclaimed.isEmpty())
    }

    @Test
    fun anUnclaimedItemGoesToTheTimeoutHandler() {
        park("a")
        deadlines.single().run()
        assertEquals(listOf("a"), unclaimed)
        assertNull(slot.claim())
    }

    @Test
    fun aNewerParkDisplacesTheOlderAndOnlyItsOwnDeadlineFires() {
        park("a")
        assertEquals("a", park("b"))
        deadlines[0].run() // the displaced item's deadline is stale
        assertTrue(unclaimed.isEmpty())
        assertTrue(slot.isWaiting)
        deadlines[1].run()
        assertEquals(listOf("b"), unclaimed)
    }

    @Test
    fun aDeadlineAfterAClaimAndReParkDoesNotFinaliseTheNewItem() {
        park("a")
        slot.claim()
        park("b")
        deadlines[0].run()
        assertTrue(unclaimed.isEmpty())
        assertEquals("b", slot.claim())
    }
}
