package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.DetectorEngine
import dev.shreeman.nitro_camera.utils.EngineResult
import dev.shreeman.nitro_camera.utils.NitraDetectors
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the open native-detector registry (the extensibility primitive host
 * apps use). Runs on the JVM without ML Kit on the runtime classpath, so the
 * built-in barcode/face factories resolve to [EngineResult.Missing] — which is
 * exactly the classification the on-device probe produces when the artifact is
 * absent.
 */
class NitraDetectorsRegistryTest {
    /** A detector with no native dependency, so it always constructs. */
    private class FakeEngine : DetectorEngine {
        override fun detect(
            nv21: ByteArray, width: Int, height: Int, rotation: Int,
            onDone: (json: String?, resultCount: Int) -> Unit,
        ) = onDone("{}", 0)
        override fun close() {}
    }

    @After fun cleanup() {
        NitraDetectors.unregister("fake")
        NitraDetectors.unregister("boom")
    }

    @Test fun `built-ins are always registered`() {
        val names = NitraDetectors.registeredNames()
        assertTrue("barcode built-in missing", names.contains("barcode"))
        assertTrue("face built-in missing", names.contains("face"))
    }

    @Test fun `a registered detector resolves to a Ready engine`() {
        NitraDetectors.register("fake") { FakeEngine() }
        assertTrue(NitraDetectors.registeredNames().contains("fake"))
        assertTrue(NitraDetectors.createEngine("fake") is EngineResult.Ready)
    }

    @Test fun `an unknown detector is Missing with a helpful message`() {
        val r = NitraDetectors.createEngine("does-not-exist")
        assertTrue(r is EngineResult.Missing)
        assertTrue((r as EngineResult.Missing).message.contains("Unknown detector"))
    }

    @Test fun `unregister removes a detector`() {
        NitraDetectors.register("fake") { FakeEngine() }
        NitraDetectors.unregister("fake")
        assertFalse(NitraDetectors.registeredNames().contains("fake"))
        assertTrue(NitraDetectors.createEngine("fake") is EngineResult.Missing)
    }

    @Test fun `a factory that throws a generic error is a transient Failed`() {
        NitraDetectors.register("boom") { throw IllegalStateException("boom") }
        assertTrue(NitraDetectors.createEngine("boom") is EngineResult.Failed)
    }

    @Test fun `built-in barcode is Missing when ML Kit is off the classpath`() {
        // The factory probes com.google.mlkit... which is compileOnly and not on
        // the test runtime classpath → ClassNotFound → Missing (not Failed).
        assertTrue(NitraDetectors.createEngine("barcode") is EngineResult.Missing)
    }
}
