package dev.shreeman.nitro_camera

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
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
        NitroCameraJniBridge.register(nitroImpl)
    }

    @OptIn(DelicateCoroutinesApi::class)
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        GlobalScope.launch { impl?.reset() }
        impl = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        impl?.activity = binding.activity
        binding.addRequestPermissionsResultListener { requestCode, _, grantResults ->
            impl?.handlePermissionResult(requestCode, grantResults) ?: false
        }
    }

    override fun onDetachedFromActivity() {
        impl?.activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        impl?.activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        impl?.activity = null
    }
}
