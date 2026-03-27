package dev.shreeman.nitro_camera

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import kotlinx.coroutines.*
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

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val target = impl
        impl = null
        if (target != null) {
            runBlocking { target.reset() }
        }
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
