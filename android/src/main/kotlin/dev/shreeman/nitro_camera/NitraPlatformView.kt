package dev.shreeman.nitro_camera

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.platform.PlatformView

/**
 * A Native Platform View that renders the camera preview using a high-performance SurfaceView.
 * This takes advantage of hardware-accelerated overlays and bypasses the Flutter compositor.
 */
class NitraPlatformView(
    context: Context,
    private val viewId: Int,
    private val onAttach: (SurfaceView) -> Unit,
    private val onDetach: () -> Unit
) : PlatformView {

    private val surfaceView: SurfaceView = SurfaceView(context).apply {
        holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                onAttach(this@apply)
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                onDetach()
            }
        })
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        onDetach()
    }
}
