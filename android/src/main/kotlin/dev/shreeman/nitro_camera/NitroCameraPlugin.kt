package dev.shreeman.nitro_camera

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import kotlinx.coroutines.*
import androidx.lifecycle.LifecycleOwner
import nitro.nitro_camera_module.NitroCameraJniBridge

class NitroCameraPlugin : FlutterPlugin, ActivityAware {

    companion object {
        init { System.loadLibrary("nitro_camera") }
    }

    private var impl: NitroCameraImpl? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val nitroImpl = NitroCameraImpl(
            context        = binding.applicationContext,
            textureRegistry = binding.textureRegistry,
        )
        impl = nitroImpl
        // nitro >= 0.5: register a factory + app context. We return the same shared
        // instance so the plugin, the platform view and the Dart-side singleton all
        // talk to one NitroCameraImpl.
        NitroCameraJniBridge.registerFactory({ nitroImpl }, binding.applicationContext)

        binding.platformViewRegistry.registerViewFactory(
            "dev.shreeman.nitro_camera/platform_view",
            NitraPlatformViewFactory(nitroImpl)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val target = impl
        impl = null
        if (target != null) {
            runBlocking { target.reset() }
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        NitroCameraJniBridge.onActivityAttached(binding.activity)
        impl?.let { (binding.activity as? LifecycleOwner)?.lifecycle?.addObserver(it) }
        binding.addRequestPermissionsResultListener { requestCode, _, grantResults ->
            impl?.handlePermissionResult(requestCode, grantResults) ?: false
        }
    }

    override fun onDetachedFromActivity() {
        val act = NitroCameraJniBridge.activity
        impl?.let { i -> (act as? LifecycleOwner)?.lifecycle?.removeObserver(i) }
        NitroCameraJniBridge.onActivityDetached()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }
}
