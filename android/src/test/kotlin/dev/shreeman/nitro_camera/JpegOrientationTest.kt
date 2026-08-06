package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.JpegOrientation
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Locks the JPEG_ORIENTATION math (the official Camera2 getJpegOrientation
 * formula) that orients stills for the physical device orientation. A wrong
 * row here means landscape/upside-down photos save rotated.
 */
class JpegOrientationTest {

    @Test fun `back camera, typical 90 sensor, all device quadrants`() {
        // Portrait: unchanged from the sensor-only behaviour.
        assertEquals(90, JpegOrientation.compute(90, 0, isFrontFacing = false))
        // Device rotated clockwise to landscape.
        assertEquals(180, JpegOrientation.compute(90, 90, isFrontFacing = false))
        assertEquals(270, JpegOrientation.compute(90, 180, isFrontFacing = false))
        assertEquals(0, JpegOrientation.compute(90, 270, isFrontFacing = false))
    }

    @Test fun `front camera mirrors the device rotation`() {
        // Typical front sensor orientation is 270.
        assertEquals(270, JpegOrientation.compute(270, 0, isFrontFacing = true))
        assertEquals(180, JpegOrientation.compute(270, 90, isFrontFacing = true))
        assertEquals(90, JpegOrientation.compute(270, 180, isFrontFacing = true))
        assertEquals(0, JpegOrientation.compute(270, 270, isFrontFacing = true))
    }

    @Test fun `unknown device orientation falls back to sensor orientation`() {
        assertEquals(90, JpegOrientation.compute(90, -1, isFrontFacing = false))
        assertEquals(270, JpegOrientation.compute(270, -1, isFrontFacing = true))
    }

    @Test fun `landscape-natural sensor (tablets, sensor 0)`() {
        assertEquals(0, JpegOrientation.compute(0, 0, isFrontFacing = false))
        assertEquals(90, JpegOrientation.compute(0, 90, isFrontFacing = false))
        assertEquals(270, JpegOrientation.compute(0, 90, isFrontFacing = true))
    }

    @Test fun `display rotation and device orientation are inverses`() {
        assertEquals(0, JpegOrientation.deviceOrientationFromDisplayRotation(0))
        assertEquals(270, JpegOrientation.deviceOrientationFromDisplayRotation(90))
        assertEquals(180, JpegOrientation.deviceOrientationFromDisplayRotation(180))
        assertEquals(90, JpegOrientation.deviceOrientationFromDisplayRotation(270))
    }

    @Test fun `values normalize into 0-359`() {
        assertEquals(0, JpegOrientation.compute(360, 0, isFrontFacing = false))
        assertEquals(0, JpegOrientation.compute(90, 270, isFrontFacing = false))
        assertEquals(180, JpegOrientation.compute(90, 90 + 360, isFrontFacing = false))
    }
}
