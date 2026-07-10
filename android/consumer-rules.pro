# Consumer ProGuard/R8 rules for nitro_camera — automatically applied to any
# app that depends on this plugin.
#
# The generated Nitro bridge (nitro.nitro_camera_module.NitroCameraJniBridge)
# and the impl (dev.shreeman.nitro_camera.*) are reached from C++ via JNI:
# FindClass("nitro/nitro_camera_module/NitroCameraJniBridge") +
# GetStaticMethodID("create_instance_call", "...") by EXACT name and signature.
# R8 has no way to see those native references, so without these rules it may
# rename, remove, or (in "full mode") mis-optimise them — most visibly a
# VerifyError on a suspend bridge method with several long params
# ("copy-cat2 ... Long (Low Half)") that aborts GeneratedPluginRegistrant and
# leaves the JNI bridge uninitialised → "failed to create native instance".
-keep class nitro.nitro_camera_module.** { *; }
-keep class dev.shreeman.nitro_camera.** { *; }

# JNI resolves native methods by name — never rename or strip their declarations.
-keepclasseswithmembernames class * {
    native <methods>;
}
