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
        (binding.activity as? LifecycleOwner)?.lifecycle?.addObserver(impl!!)
        binding.addRequestPermissionsResultListener { requestCode, _, grantResults ->
            impl?.handlePermissionResult(requestCode, grantResults) ?: false
        }
    }

    override fun onDetachedFromActivity() {
        val target = impl
        if (target != null) {
            (target.activity as? LifecycleOwner)?.lifecycle?.removeObserver(target)
            target.activity = null
        }
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }
}
