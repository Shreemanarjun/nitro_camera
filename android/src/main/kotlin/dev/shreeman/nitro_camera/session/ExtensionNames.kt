package dev.shreeman.nitro_camera.session

/**
 * Dart `CameraExtension` names ↔ Camera2 `CameraExtensionCharacteristics`
 * extension ids (values inlined so this stays JVM-testable without the
 * API 31 constants).
 */
object ExtensionNames {
    const val AUTOMATIC = 0 // EXTENSION_AUTOMATIC
    const val FACE_RETOUCH = 1 // EXTENSION_FACE_RETOUCH (formerly BEAUTY)
    const val BOKEH = 2 // EXTENSION_BOKEH
    const val HDR = 3 // EXTENSION_HDR
    const val NIGHT = 4 // EXTENSION_NIGHT

    private val byName = mapOf(
        "auto" to AUTOMATIC,
        "face-retouch" to FACE_RETOUCH,
        "bokeh" to BOKEH,
        "hdr" to HDR,
        "night" to NIGHT,
    )

    /** The Camera2 id for [name], or null when unknown. */
    fun toCamera2(name: String): Int? = byName[name]

    /** The Dart name for a Camera2 id, or null when unknown. */
    fun fromCamera2(id: Int): String? = byName.entries.firstOrNull { it.value == id }?.key

    /**
     * The supported size closest in aspect to [targetW]×[targetH], preferring
     * the largest among equals (≤ [maxPixels]); null when [sizes] is empty.
     */
    fun pickSize(sizes: List<Pair<Int, Int>>, targetW: Int, targetH: Int, maxPixels: Long = Long.MAX_VALUE): Pair<Int, Int>? {
        val target = maxOf(targetW, targetH).toDouble() / minOf(targetW, targetH).coerceAtLeast(1)
        return sizes
            .filter { it.first.toLong() * it.second <= maxPixels }
            .ifEmpty { sizes }
            .minWithOrNull(
                compareBy<Pair<Int, Int>> {
                    val a = maxOf(it.first, it.second).toDouble() / minOf(it.first, it.second).coerceAtLeast(1)
                    Math.round(Math.abs(a - target) * 100)
                }.thenByDescending { it.first.toLong() * it.second },
            )
    }
}
