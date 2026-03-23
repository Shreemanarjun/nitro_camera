package dev.shreeman.nitro_camera

import io.flutter.embedding.engine.plugins.FlutterPlugin
import nitro.nitro_camera_module.NitroCameraJniBridge

class NitroCameraPlugin : FlutterPlugin {

    companion object {
        init { System.loadLibrary("nitro_camera") }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NitroCameraJniBridge.register(
            NitroCameraImpl(binding.applicationContext)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}