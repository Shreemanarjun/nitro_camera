package dev.shreeman.nitro_camera

import android.hardware.camera2.CameraCharacteristics
import android.media.Image
import android.os.SystemClock
import android.util.Log
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native ML detector runner (barcode / face via Google ML Kit).
 *
 * ML Kit is an OPTIONAL dependency: the plugin compiles against it
 * (`compileOnly`), but host apps opt in by adding the implementation artifact
 * themselves (`com.google.mlkit:barcode-scanning` /
 * `com.google.mlkit:face-detection`). Availability is probed at runtime with
 * `Class.forName`; when the artifact is missing, a single error payload is
 * emitted and the detector stays disabled for that texture until [stop].
 *
 * Class-loading safety: this object contains no direct ML Kit type
 * references. All ML Kit API usage lives in the file-private engine classes
 * ([BarcodeEngine] / [FaceEngine]), which are only linked after the probe
 * succeeds — and instantiated inside a `catch (Throwable)` that also covers
 * `NoClassDefFoundError` — so a missing ML Kit can never crash verification.
 */
object NitraDetectors {
    private const val TAG = "NitroCamera"

    /** Minimum interval between detection dispatches per texture (~10 Hz). */
    private const val MIN_DETECT_INTERVAL_MS = 100L

    /** Minimum interval between EMPTY result emissions per texture. */
    private const val EMPTY_EMIT_INTERVAL_MS = 500L

    /**
     * How many CONSECUTIVE transient engine-creation failures are tolerated
     * (one retry per delivered frame) before the detector is disabled with a
     * generic error. Genuinely missing ML Kit artifacts are reported (and
     * disabled) on the FIRST attempt instead — see [createEngine].
     */
    private const val MAX_ENGINE_CREATE_FAILURES = 5

    /**
     * Detection input is DOWNSCALED so the short side is at most this many
     * pixels. Detecting at the full stream size (1080p+) makes both the NV21
     * copy on the camera thread and the ML Kit inference (especially face
     * detection with classification + tracking) slow enough to starve the
     * shared ImageReader of buffers, which stalls the whole capture session —
     * including the preview. ML Kit works fine at ~480p for faces/barcodes.
     */
    private const val MAX_DETECT_SHORT_SIDE = 480

    private val states = ConcurrentHashMap<Long, DetectorState>()

    /**
     * Retired engines are closed OFF the caller thread: `close()` can race an
     * in-flight detection (typical during a camera switch), and it must never
     * block the camera/Dart thread nor poison the NEXT engine — the state is
     * detached from [states] before the close is scheduled, so nothing can
     * observe or reuse a closing engine.
     */
    private val closeExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "NitraDetectorClose").apply { isDaemon = true }
    }

    private fun closeEngineAsync(engine: DetectorEngine?) {
        if (engine == null) return
        closeExecutor.execute {
            try {
                engine.close()
            } catch (t: Throwable) {
                Log.w(TAG, "NitraDetectors: engine close failed: ${t.message}")
            }
        }
    }

    /**
     * Called on the camera thread with a LIVE YUV_420_888 [image]. Copies the
     * pixels it needs SYNCHRONOUSLY — the caller closes the image right after
     * this returns. Detection itself runs async with drop-while-busy plus a
     * ~100 ms throttle; results are delivered as a JSON string via [onResult]
     * (possibly from another thread). Empty result sets are still emitted so
     * UIs can clear stale highlights, but rate-limited to one per 500 ms.
     */
    fun process(
        image: Image,
        characteristics: CameraCharacteristics,
        textureId: Long,
        detector: String,
        onResult: (String) -> Unit,
    ) {
        val state = obtainState(textureId, detector)
        if (state.disabled) return

        // Drop-while-busy + minimum interval between detections.
        if (state.inFlight.get()) return
        val now = SystemClock.elapsedRealtime()
        if (now - state.lastRunMs < MIN_DETECT_INTERVAL_MS) return

        val engine = state.engine ?: when (val created = createEngine(detector)) {
            is EngineResult.Ready -> {
                state.createFailures = 0
                state.engine = created.engine
                created.engine
            }
            is EngineResult.Missing -> {
                // The ML Kit artifact is genuinely absent (or the detector name
                // is unknown) — report once per activation, then stay silent
                // until stop().
                state.disabled = true
                onResult(errorJson(detector, created.message))
                return
            }
            is EngineResult.Failed -> {
                // TRANSIENT failure (e.g. ML Kit init hiccup, or an engine
                // close from a camera switch racing creation) — retry on the
                // next frame, bounded so a persistent fault can't loop forever.
                state.createFailures++
                if (state.createFailures >= MAX_ENGINE_CREATE_FAILURES) {
                    state.disabled = true
                    onResult(errorJson(
                        detector,
                        "'$detector' detector failed to start after " +
                            "${state.createFailures} attempts: ${created.message}",
                    ))
                }
                return
            }
        }

        // Copy pixels synchronously into the pooled buffer, downscaling by an
        // integer skip factor so the short side is <= MAX_DETECT_SHORT_SIDE.
        // Output dims are forced EVEN so the NV21 chroma (2x2-subsampled VU
        // pairs) stays aligned. Reuse of the pooled buffer is safe because
        // frames are dropped while a detection is in flight.
        val width = image.width
        val height = image.height
        val skip = detectionSkip(width, height)
        val outW = ((width / skip) - (width / skip) % 2).coerceAtLeast(2)
        val outH = ((height / skip) - (height / skip) % 2).coerceAtLeast(2)
        val required = outW * outH * 3 / 2
        var nv21 = state.nv21
        if (nv21 == null || nv21.size != required) {
            nv21 = ByteArray(required)
            state.nv21 = nv21
        }
        try {
            if (skip == 1 && outW == width && outH == height) {
                yuv420ToNv21(image, nv21)
            } else {
                yuv420ToNv21Downscaled(image, nv21, skip, outW, outH)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "NitraDetectors: NV21 conversion failed: ${t.message}")
            return
        }

        val rotation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0

        if (!state.inFlight.compareAndSet(false, true)) return
        state.lastRunMs = now
        try {
            // NOTE: the SCALED dims are what ML Kit sees, and they are what the
            // engines report in the JSON payload — bounds match width/height.
            engine.detect(nv21, outW, outH, rotation) { json, resultCount ->
                try {
                    // Suppress results that complete after stop()/detector swap.
                    if (json != null && states[textureId] === state) {
                        if (resultCount > 0) {
                            onResult(json)
                        } else {
                            val emitNow = SystemClock.elapsedRealtime()
                            if (emitNow - state.lastEmptyEmitMs >= EMPTY_EMIT_INTERVAL_MS) {
                                state.lastEmptyEmitMs = emitNow
                                onResult(json)
                            }
                        }
                    }
                } finally {
                    state.inFlight.set(false)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "NitraDetectors: '$detector' dispatch failed: ${t.message}")
            state.inFlight.set(false)
        }
    }

    /** Releases any detector state held for [textureId]. */
    fun stop(textureId: Long) {
        val state = states.remove(textureId) ?: return
        // Detach the engine BEFORE scheduling the close so the retired state
        // can never hand it out again; close runs async because it may race an
        // in-flight detection (camera switch) and must not block the caller.
        val engine = state.engine
        state.engine = null
        closeEngineAsync(engine)
        Log.d(TAG, "NitraDetectors: stopped '${state.detector}' for texture $textureId")
    }

    /** Returns the state for [textureId], recycling it if the detector changed. */
    private fun obtainState(textureId: Long, detector: String): DetectorState {
        val existing = states[textureId]
        if (existing != null) {
            if (existing.detector == detector) return existing
            // Detector changed — release the old engine (async, see [stop])
            // and start fresh.
            states.remove(textureId)
            val engine = existing.engine
            existing.engine = null
            closeEngineAsync(engine)
        }
        val fresh = DetectorState(detector)
        states[textureId] = fresh
        return fresh
    }

    /**
     * Probes for the optional ML Kit artifact and instantiates the matching
     * engine.
     *
     * Failure classification matters: only [EngineResult.Missing] (the class
     * genuinely cannot be linked — `ClassNotFoundException` /
     * `NoClassDefFoundError`, or an unknown detector name) may produce the
     * "add the ML Kit dependency" error. Every other [Throwable] — e.g. an ML
     * Kit initialisation hiccup, or `getClient()` racing a concurrent engine
     * close during a camera switch — is TRANSIENT ([EngineResult.Failed]) and
     * is retried on later frames instead of permanently disabling the
     * detector with a misleading message.
     */
    private fun createEngine(detector: String): EngineResult {
        val probeClass = when (detector) {
            "barcode" -> "com.google.mlkit.vision.barcode.BarcodeScanning"
            "face" -> "com.google.mlkit.vision.face.FaceDetection"
            else -> return EngineResult.Missing(missingDependencyMessage(detector))
        }
        return try {
            Class.forName(probeClass)
            EngineResult.Ready(if (detector == "barcode") BarcodeEngine() else FaceEngine())
        } catch (e: ClassNotFoundException) {
            Log.w(TAG, "NitraDetectors: '$detector' unavailable: $e")
            EngineResult.Missing(missingDependencyMessage(detector))
        } catch (e: NoClassDefFoundError) {
            Log.w(TAG, "NitraDetectors: '$detector' unavailable: $e")
            EngineResult.Missing(missingDependencyMessage(detector))
        } catch (t: Throwable) {
            Log.w(TAG, "NitraDetectors: '$detector' engine creation failed (will retry): $t")
            EngineResult.Failed(t.toString())
        }
    }

    private fun missingDependencyMessage(detector: String): String = when (detector) {
        "barcode" ->
            "ML Kit barcode-scanning not found — add com.google.mlkit:barcode-scanning to your app's dependencies"
        "face" ->
            "ML Kit face-detection not found — add com.google.mlkit:face-detection to your app's dependencies"
        else -> "Unknown detector '$detector' — supported detectors: barcode, face"
    }

    private fun errorJson(detector: String, message: String): String =
        JSONObject().put("detector", detector).put("error", message).toString()

    /**
     * Smallest integer subsampling factor that brings the frame's short side
     * down to <= [MAX_DETECT_SHORT_SIDE] (1 when it already is).
     */
    private fun detectionSkip(width: Int, height: Int): Int {
        val shortSide = minOf(width, height)
        if (shortSide <= MAX_DETECT_SHORT_SIDE) return 1
        return (shortSide + MAX_DETECT_SHORT_SIDE - 1) / MAX_DETECT_SHORT_SIDE
    }

    /**
     * Integer-skip (nearest-neighbour) downscaling YUV_420_888 → NV21 copy.
     * [outW]/[outH] must be EVEN and satisfy `outW * skip <= width` and
     * `outH * skip <= height` (guaranteed by the floor division + even-crop in
     * [process]). Sampling the chroma planes with the SAME [skip] in chroma
     * space keeps every output VU pair aligned with its 2x2 luma block, for
     * any row/pixel stride layout.
     */
    private fun yuv420ToNv21Downscaled(
        image: Image,
        out: ByteArray,
        skip: Int,
        outW: Int,
        outH: Int,
    ) {
        val planes = image.planes
        val ySize = outW * outH

        // Luma.
        val yPlane = planes[0]
        val yBuf = yPlane.buffer.duplicate().apply { clear() }
        val yRowStride = yPlane.rowStride
        val yColStep = yPlane.pixelStride * skip
        var outPos = 0
        for (row in 0 until outH) {
            var src = row * skip * yRowStride
            for (col in 0 until outW) {
                out[outPos++] = yBuf.get(src)
                src += yColStep
            }
        }

        // Chroma (planes are already 2x2-subsampled relative to luma).
        val uPlane = planes[1]
        val vPlane = planes[2]
        val uBuf = uPlane.buffer.duplicate().apply { clear() }
        val vBuf = vPlane.buffer.duplicate().apply { clear() }
        val uRowStride = uPlane.rowStride
        val vRowStride = vPlane.rowStride
        val uColStep = uPlane.pixelStride * skip
        val vColStep = vPlane.pixelStride * skip
        outPos = ySize
        for (row in 0 until outH / 2) {
            var uSrc = row * skip * uRowStride
            var vSrc = row * skip * vRowStride
            for (col in 0 until outW / 2) {
                out[outPos++] = vBuf.get(vSrc)
                out[outPos++] = uBuf.get(uSrc)
                uSrc += uColStep
                vSrc += vColStep
            }
        }
    }

    /**
     * Copies a live YUV_420_888 [image] into [out] as NV21 (full Y plane
     * followed by interleaved VU). Works on buffer duplicates so plane
     * positions touched by other consumers of the same [Image] are never
     * disturbed. Handles arbitrary row/pixel strides, with a bulk-copy fast
     * path when the chroma planes already alias one interleaved VU buffer
     * (the common device layout).
     */
    private fun yuv420ToNv21(image: Image, out: ByteArray) {
        val width = image.width
        val height = image.height
        val ySize = width * height
        val planes = image.planes

        // Luma.
        val yPlane = planes[0]
        val yBuf = yPlane.buffer.duplicate().apply { clear() }
        val yRowStride = yPlane.rowStride
        val yPixelStride = yPlane.pixelStride
        if (yPixelStride == 1 && yRowStride == width) {
            yBuf.get(out, 0, ySize)
        } else {
            var outPos = 0
            for (row in 0 until height) {
                if (yPixelStride == 1) {
                    yBuf.position(row * yRowStride)
                    yBuf.get(out, outPos, width)
                    outPos += width
                } else {
                    val rowStart = row * yRowStride
                    for (col in 0 until width) {
                        out[outPos++] = yBuf.get(rowStart + col * yPixelStride)
                    }
                }
            }
        }

        // Chroma.
        if (!copyInterleavedChroma(planes[1], planes[2], out, ySize)) {
            copyPlanarChroma(planes[1], planes[2], out, width, height, ySize)
        }
    }

    /**
     * Bulk-copy fast path for the common case where the U/V planes are two
     * views of one interleaved VU buffer (NV21 chroma layout, pixelStride 2).
     * Verifies the aliasing by comparing V shifted one byte against U before
     * trusting it. Returns false when the layout doesn't match.
     */
    private fun copyInterleavedChroma(
        uPlane: Image.Plane,
        vPlane: Image.Plane,
        out: ByteArray,
        ySize: Int,
    ): Boolean {
        if (uPlane.pixelStride != 2 || vPlane.pixelStride != 2) return false
        val chromaBytes = ySize / 2
        val uBuf = uPlane.buffer.duplicate().apply { clear() }
        val vBuf = vPlane.buffer.duplicate().apply { clear() }
        // Aliased VU views each miss one byte of the full interleaved block.
        if (uBuf.capacity() != chromaBytes - 1 || vBuf.capacity() != chromaBytes - 1) return false

        // If aliased, V[1..end] and U[0..end-1] cover identical VU bytes.
        vBuf.position(1)
        uBuf.limit(chromaBytes - 2)
        if (vBuf.compareTo(uBuf) != 0) return false

        vBuf.clear()
        uBuf.clear()
        vBuf.get(out, ySize, 1)                   // leading V value
        uBuf.get(out, ySize + 1, chromaBytes - 1) // U0 V1 U1 V2 ... remainder
        return true
    }

    /** Generic per-sample chroma copy honoring arbitrary strides. */
    private fun copyPlanarChroma(
        uPlane: Image.Plane,
        vPlane: Image.Plane,
        out: ByteArray,
        width: Int,
        height: Int,
        ySize: Int,
    ) {
        val uBuf = uPlane.buffer.duplicate().apply { clear() }
        val vBuf = vPlane.buffer.duplicate().apply { clear() }
        val uRowStride = uPlane.rowStride
        val uPixelStride = uPlane.pixelStride
        val vRowStride = vPlane.rowStride
        val vPixelStride = vPlane.pixelStride
        var outPos = ySize
        for (row in 0 until height / 2) {
            val uRow = row * uRowStride
            val vRow = row * vRowStride
            for (col in 0 until width / 2) {
                out[outPos++] = vBuf.get(vRow + col * vPixelStride)
                out[outPos++] = uBuf.get(uRow + col * uPixelStride)
            }
        }
    }
}

/**
 * Mutable per-texture detector state. [inFlight] and the volatile fields are
 * shared between the camera thread and ML Kit's callback thread; [nv21] is
 * only written on the camera thread while no detection is in flight.
 */
private class DetectorState(val detector: String) {
    val inFlight = AtomicBoolean(false)
    @Volatile var lastRunMs = 0L
    @Volatile var lastEmptyEmitMs = 0L
    @Volatile var engine: DetectorEngine? = null
    @Volatile var disabled = false
    /** Consecutive TRANSIENT engine-creation failures (reset on success). */
    @Volatile var createFailures = 0
    var nv21: ByteArray? = null
}

/** Outcome of an engine-creation attempt — see [NitraDetectors.createEngine]. */
private sealed interface EngineResult {
    /** Engine created successfully. */
    class Ready(val engine: DetectorEngine) : EngineResult

    /** The ML Kit artifact is missing (or the detector name is unknown) — permanent. */
    class Missing(val message: String) : EngineResult

    /** Transient creation failure — retry on a later frame (bounded). */
    class Failed(val message: String) : EngineResult
}

/**
 * Detection engine abstraction — deliberately free of ML Kit types so that
 * [NitraDetectors] itself never triggers ML Kit class loading. Concrete
 * engines are only instantiated after a successful `Class.forName` probe.
 */
private interface DetectorEngine {
    /**
     * Runs detection on an NV21 frame asynchronously. Invokes [onDone]
     * exactly once — with the result JSON and the number of detections on
     * success, or with a null JSON payload on failure.
     */
    fun detect(
        nv21: ByteArray,
        width: Int,
        height: Int,
        rotation: Int,
        onDone: (json: String?, resultCount: Int) -> Unit,
    )

    /** Releases the underlying ML Kit client. */
    fun close()
}

/** ML Kit barcode scanning engine (all formats). */
private class BarcodeEngine : DetectorEngine {
    private val client = BarcodeScanning.getClient()

    override fun detect(
        nv21: ByteArray,
        width: Int,
        height: Int,
        rotation: Int,
        onDone: (json: String?, resultCount: Int) -> Unit,
    ) {
        val input = InputImage.fromByteArray(nv21, width, height, rotation, InputImage.IMAGE_FORMAT_NV21)
        client.process(input)
            .addOnSuccessListener { barcodes ->
                try {
                    val results = JSONArray()
                    for (barcode in barcodes) {
                        val item = JSONObject()
                        item.put("text", barcode.rawValue ?: barcode.displayValue ?: "")
                        item.put("format", barcode.format)
                        barcode.boundingBox?.let { box ->
                            item.put("bounds", JSONArray().put(box.left).put(box.top).put(box.right).put(box.bottom))
                        }
                        results.put(item)
                    }
                    val json = JSONObject()
                        .put("detector", "barcode")
                        .put("width", width)
                        .put("height", height)
                        .put("rotation", rotation)
                        .put("results", results)
                    onDone(json.toString(), results.length())
                } catch (t: Throwable) {
                    Log.w("NitroCamera", "NitraDetectors: barcode result encoding failed: ${t.message}")
                    onDone(null, 0)
                }
            }
            .addOnFailureListener { e ->
                Log.w("NitroCamera", "NitraDetectors: barcode detection failed: ${e.message}")
                onDone(null, 0)
            }
    }

    override fun close() = client.close()
}

/** ML Kit face detection engine (classification + tracking enabled). */
private class FaceEngine : DetectorEngine {
    private val client = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
            .enableTracking()
            .build()
    )

    override fun detect(
        nv21: ByteArray,
        width: Int,
        height: Int,
        rotation: Int,
        onDone: (json: String?, resultCount: Int) -> Unit,
    ) {
        val input = InputImage.fromByteArray(nv21, width, height, rotation, InputImage.IMAGE_FORMAT_NV21)
        client.process(input)
            .addOnSuccessListener { faces ->
                try {
                    val results = JSONArray()
                    for (face in faces) {
                        val item = JSONObject()
                        val box = face.boundingBox
                        item.put("bounds", JSONArray().put(box.left).put(box.top).put(box.right).put(box.bottom))
                        face.trackingId?.let { item.put("trackingId", it) }
                        face.smilingProbability?.let { item.put("smilingProbability", it.toDouble()) }
                        face.leftEyeOpenProbability?.let { item.put("leftEyeOpenProbability", it.toDouble()) }
                        face.rightEyeOpenProbability?.let { item.put("rightEyeOpenProbability", it.toDouble()) }
                        item.put("headEulerAngleY", face.headEulerAngleY.toDouble())
                        item.put("headEulerAngleZ", face.headEulerAngleZ.toDouble())
                        results.put(item)
                    }
                    val json = JSONObject()
                        .put("detector", "face")
                        .put("width", width)
                        .put("height", height)
                        .put("rotation", rotation)
                        .put("results", results)
                    onDone(json.toString(), results.length())
                } catch (t: Throwable) {
                    Log.w("NitroCamera", "NitraDetectors: face result encoding failed: ${t.message}")
                    onDone(null, 0)
                }
            }
            .addOnFailureListener { e ->
                Log.w("NitroCamera", "NitraDetectors: face detection failed: ${e.message}")
                onDone(null, 0)
            }
    }

    override fun close() = client.close()
}
