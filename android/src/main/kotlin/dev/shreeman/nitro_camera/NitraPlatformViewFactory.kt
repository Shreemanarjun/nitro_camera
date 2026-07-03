package dev.shreeman.nitro_camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Creates NitraPlatformView instances and connects them into the 
 * NitroCamera subsystem via the singleton-style [impl] registry.
 */
class NitraPlatformViewFactory(
    private val impl: NitroCameraImpl
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<String, Any?>
        val textureId = (params?.get("textureId") as? Number)?.toLong() ?: -1L
        
        return NitraPlatformView(
            context,
            viewId,
            onAttach = { surface ->
                Handler(Looper.getMainLooper()).post {
                    impl.attachPlatformView(textureId, surface)
                }
            },
            onDetach = {
                impl.detachPlatformView(textureId)
            }
        )
    }
}
