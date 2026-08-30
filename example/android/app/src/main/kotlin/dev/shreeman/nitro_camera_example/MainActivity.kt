package dev.shreeman.nitro_camera_example

import dev.shreeman.nitro_camera.utils.DetectorEngine
import dev.shreeman.nitro_camera.utils.NitraDetectors
import io.flutter.embedding.android.FlutterActivity
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    init {
        // Demo of the native frame-processor plugin registry: a dependency-free
        // custom detector registered by the host app, selectable from Dart via
        // controller.setNativeDetector("meanLuma"). Proves the registry works
        // end-to-end without ML Kit. Registration is idempotent (overwrites).
        NitraDetectors.register("meanLuma") { MeanLumaEngine() }
    }
}

/// Computes the average scene luminance (0..255) from the NV21 luma plane.
private class MeanLumaEngine : DetectorEngine {
    override fun detect(
        nv21: ByteArray,
        width: Int,
        height: Int,
        rotation: Int,
        onDone: (json: String?, resultCount: Int) -> Unit,
    ) {
        val lumaCount = width * height
        if (lumaCount <= 0 || nv21.size < lumaCount) {
            onDone(null, 0)
            return
        }
        // Subsample every 16th luma byte — plenty for a mean, cheap per frame.
        var sum = 0L
        var n = 0
        var i = 0
        while (i < lumaCount) {
            sum += nv21[i].toInt() and 0xFF
            n++
            i += 16
        }
        val mean = if (n > 0) (sum / n).toInt() else 0
        val json = JSONObject()
            .put("detector", "meanLuma")
            .put("width", width)
            .put("height", height)
            .put("rotation", rotation)
            .put("results", JSONArray().put(JSONObject().put("luma", mean)))
        onDone(json.toString(), 1)
    }

    override fun close() {}
}
