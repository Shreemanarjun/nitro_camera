package dev.shreeman.nitro_camera

import android.content.Context
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import android.view.View
import io.flutter.plugin.platform.PlatformView

/**
 * A Native Platform View that renders the camera preview into a [TextureView].
 *
 * TextureView (not SurfaceView) on purpose: Flutter composites TextureView-backed
 * platform views via the Texture Layer (TLHC) path — correct aspect and z-order.
 * A SurfaceView here either falls back to Virtual Display (scaled → slightly
 * squeezed preview) or, under Hybrid Composition, punches through BEHIND the
 * Flutter content (black preview). This mirrors vision-camera's COMPATIBLE mode.
 */
class NitraPlatformView(
    context: Context,
    private val viewId: Int,
    private val onAttach: (Surface) -> Unit,
    private val onDetach: () -> Unit
) : PlatformView {

    private var surface: Surface? = null

    private val textureView: TextureView = TextureView(context).apply {
        surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(st: SurfaceTexture, width: Int, height: Int) {
                surface = Surface(st).also(onAttach)
            }

            override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, width: Int, height: Int) {
                // Rebind so the EGL surface picks up the NEW size immediately —
                // stale dimensions would cover-crop for the wrong aspect.
                surface?.let(onAttach)
            }

            override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                onDetach()
                surface?.release()
                surface = null
                return true
            }

            override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
        }
    }

    override fun getView(): View = textureView

    override fun dispose() {
        onDetach()
        surface?.release()
        surface = null
    }
}
