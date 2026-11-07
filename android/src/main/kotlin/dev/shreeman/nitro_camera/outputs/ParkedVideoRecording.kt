package dev.shreeman.nitro_camera.outputs

import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface

/**
 * A persistent recording between two sessions (vision-camera's
 * `enablePersistentRecorder`): the paused [MediaRecorder] and its GL input
 * [surface], handed over by a closing session ([VideoOutput.park]) until the
 * next one adopts it ([VideoOutput.adoptParked]). One recording can wait at a
 * time; one nobody claims within [CLAIM_WINDOW_MS] is finalised so the file
 * is never lost.
 */
class ParkedVideoRecording(
    val recorder: MediaRecorder,
    val surface: Surface,
    val outputPath: String,
    val startMs: Long,
    val pausedAccumulatedMs: Long,
    val pauseStartMs: Long,
    val userPaused: Boolean,
    val width: Int,
    val height: Int,
    val codec: Long,
    val fileType: Long,
) {
    /** Stops and releases the recorder, finalising the file. */
    fun finalise(reason: String) {
        try {
            // A paused recorder must resume before stop() writes the moov atom
            // on some encoders; resuming without new frames adds nothing.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try { recorder.resume() } catch (_: Exception) {}
            }
            recorder.stop()
            Log.i("NitroCamera", "Parked recording finalised ($reason) → $outputPath")
        } catch (e: Exception) {
            Log.e("NitroCamera", "Parked recording finalise failed ($reason): ${e.message}")
        } finally {
            try { recorder.release() } catch (_: Exception) {}
        }
    }

    companion object {
        const val CLAIM_WINDOW_MS = 10_000L

        private val slot = ParkingSlot<ParkedVideoRecording>(CLAIM_WINDOW_MS) { it.finalise(it.timeoutReason) }
        private val handler by lazy { Handler(Looper.getMainLooper()) }

        private val ParkedVideoRecording.timeoutReason
            get() = "no session reopened within ${CLAIM_WINDOW_MS / 1000} s"

        fun park(recording: ParkedVideoRecording) {
            slot.park(recording, schedule = { delayMs, run -> handler.postDelayed(run, delayMs) })
                ?.finalise("replaced by a newer persistent recording")
        }

        fun claim(): ParkedVideoRecording? = slot.claim()

        val isWaiting: Boolean get() = slot.isWaiting
    }
}

/**
 * One-item hand-off slot with a claim deadline — the platform-free core of
 * [ParkedVideoRecording] (JVM-testable). [park] returns the item it
 * displaced; an item still parked when its deadline fires goes to
 * [onUnclaimed]. A [claim] or a newer [park] cancels the pending deadline.
 */
class ParkingSlot<T : Any>(
    private val claimWindowMs: Long,
    private val onUnclaimed: (T) -> Unit,
) {
    private val lock = Any()
    private var item: T? = null
    private var generation = 0

    fun park(value: T, schedule: (delayMs: Long, run: Runnable) -> Unit): T? {
        val displaced: T?
        val mine: Int
        synchronized(lock) {
            displaced = item
            item = value
            mine = ++generation
        }
        schedule(claimWindowMs, Runnable {
            val unclaimed = synchronized(lock) {
                if (generation != mine) return@synchronized null
                item.also { item = null }
            }
            unclaimed?.let(onUnclaimed)
        })
        return displaced
    }

    fun claim(): T? = synchronized(lock) {
        generation++ // a pending deadline no longer applies
        item.also { item = null }
    }

    val isWaiting: Boolean get() = synchronized(lock) { item != null }
}
