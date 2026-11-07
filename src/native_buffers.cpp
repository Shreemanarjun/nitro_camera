// AHardwareBuffer* for a Java HardwareBuffer (CameraFrame.nativeBuffer).
// Resolved with dlsym: the symbol is API 26+ while the plugin's minSdk is 24.
#ifdef __ANDROID__
#include <dlfcn.h>
#include <jni.h>
#include <stdint.h>

typedef void* (*FromHardwareBuffer)(JNIEnv*, jobject);

extern "C" JNIEXPORT jlong JNICALL
Java_dev_shreeman_nitro_1camera_utils_NativeBuffers_nativeHandle(JNIEnv* env, jclass, jobject hardwareBuffer) {
  static FromHardwareBuffer fn = [] {
    void* lib = dlopen("libandroid.so", RTLD_NOW);
    return lib ? reinterpret_cast<FromHardwareBuffer>(dlsym(lib, "AHardwareBuffer_fromHardwareBuffer")) : nullptr;
  }();
  return fn ? static_cast<jlong>(reinterpret_cast<intptr_t>(fn(env, hardwareBuffer))) : 0;
}
#endif
