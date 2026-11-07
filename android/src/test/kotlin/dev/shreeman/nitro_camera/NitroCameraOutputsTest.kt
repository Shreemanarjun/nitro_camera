package dev.shreeman.nitro_camera

import android.graphics.SurfaceTexture
import android.view.Surface
import org.junit.Assert.assertEquals
import org.junit.Test

/** Guards the plugin-output registry other plugins (RTMP, …) attach through. */
class NitroCameraOutputsTest {
    private fun surface() = Surface(null as SurfaceTexture?)

    @Test
    fun addRemoveNotifiesAndDedupes() {
        val id = 9001L
        var changes = 0
        NitroCameraOutputs.listen(id) { changes++ }
        val a = surface()
        val b = surface()
        NitroCameraOutputs.add(id, a)
        NitroCameraOutputs.add(id, a, mirror = true) // re-add replaces, no duplicate
        NitroCameraOutputs.add(id, b)
        assertEquals(2, NitroCameraOutputs.outputsFor(id).size)
        assertEquals(true, NitroCameraOutputs.outputsFor(id).first { it.surface === a }.mirror)
        assertEquals(3, changes)

        NitroCameraOutputs.remove(id, a)
        NitroCameraOutputs.remove(id, a) // unknown: no notification
        assertEquals(4, changes)
        assertEquals(listOf(b), NitroCameraOutputs.outputsFor(id).map { it.surface })

        NitroCameraOutputs.clear(id)
        NitroCameraOutputs.add(id, a) // listener gone with the session
        assertEquals(4, changes)
        NitroCameraOutputs.clear(id)
        assertEquals(0, NitroCameraOutputs.outputsFor(id).size)
    }

    @Test
    fun outputsAreScopedPerSession() {
        val a = surface()
        NitroCameraOutputs.add(1L, a)
        assertEquals(0, NitroCameraOutputs.outputsFor(2L).size)
        NitroCameraOutputs.clear(1L)
    }
}
