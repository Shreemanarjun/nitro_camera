package dev.shreeman.nitro_camera

import dev.shreeman.nitro_camera.utils.DirectFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

/** The nitro bridge's per-port collector must run on the emitting (camera) thread. */
class DirectFlowTest {
    @Test
    fun collectorRunsInlineOnTheEmitterUntilCancelled() = runBlocking {
        val flow = DirectFlow<Int>()
        val seen = mutableListOf<Pair<Int, String>>()
        // Same shape as the generated register_*_stream_call.
        val job = CoroutineScope(Dispatchers.Default).launch(start = CoroutineStart.UNDISPATCHED) {
            flow.collect { seen += it to Thread.currentThread().name }
        }
        assertEquals(1, flow.subscriptionCount)

        val camera = Thread({ flow.emit(1); flow.emit(2) }, "camera").apply { start(); join() }
        assertEquals(listOf(1 to "camera", 2 to "camera"), seen)

        job.cancel(); job.join()
        assertEquals(0, flow.subscriptionCount)
        flow.emit(3)
        assertEquals(2, seen.size)
    }
}
