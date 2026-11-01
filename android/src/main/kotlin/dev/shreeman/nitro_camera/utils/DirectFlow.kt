package dev.shreeman.nitro_camera.utils

import android.util.Log
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector

/**
 * A hot [Flow] that runs every collector inline on the thread that calls [emit],
 * with no buffer and no dispatcher hop. A `MutableSharedFlow` collected on
 * `Dispatchers.Default` (what the nitro bridge does for each Dart port) costs a
 * thread hand-off per frame; this delivers on the camera thread instead, like
 * vision-camera's frame processor.
 *
 * Collectors must not suspend (the nitro bridge's only posts to a Dart port).
 * A collector stays registered until its collecting coroutine is cancelled.
 */
internal class DirectFlow<T> : Flow<T> {
    private val collectors = CopyOnWriteArrayList<FlowCollector<T>>()

    val subscriptionCount: Int get() = collectors.size

    override suspend fun collect(collector: FlowCollector<T>) {
        collectors += collector
        try {
            awaitCancellation()
        } finally {
            collectors -= collector
        }
    }

    fun emit(value: T) {
        for (c in collectors) {
            suspend { c.emit(value) }.startCoroutine(Continuation(EmptyCoroutineContext) { r ->
                r.exceptionOrNull()?.let { Log.w("DirectFlow", "collector threw", it) }
            })
        }
    }
}
