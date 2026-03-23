#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include "dart_api_dl.h"
#include "nitro_camera.bridge.g.h"

extern "C" {
intptr_t InitDartApiDL(void* data) {
    return Dart_InitializeApiDL(data);
}
}

#ifdef __ANDROID__
#include <jni.h>
#include <android/log.h>
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "Nitrogen", __VA_ARGS__)

static JavaVM* g_jvm = nullptr;
static jclass g_bridgeClass = nullptr;


extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_jvm = vm;
    __android_log_print(ANDROID_LOG_INFO, "Nitrogen", "JNI_OnLoad called for nitro_camera");
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return -1;
    }
    jclass localClass = env->FindClass("nitro/nitro_camera_module/NitroCameraJniBridge");
    if (localClass != nullptr) {
        g_bridgeClass = (jclass)env->NewGlobalRef(localClass);
    } else {
        LOGE("Failed to find JniBridge class");
    }
    return JNI_VERSION_1_6;
}

static JNIEnv* GetEnv() {
    if (g_jvm == nullptr) return nullptr;
    JNIEnv* env = nullptr;
    int status = g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        g_jvm->AttachCurrentThread(&env, nullptr);
    }
    return env;
}

double nitro_camera_add(double a, double b) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0.0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "add_call", "(DD)D");
    if (methodId == nullptr) { LOGE("Method not found"); return 0.0; }
    return env->CallStaticDoubleMethod(g_bridgeClass, methodId, a, b);
}

const char* nitro_camera_get_greeting(const char* name) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return "";
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getGreeting_call", "(Ljava/lang/String;)Ljava/lang/String;");
    if (methodId == nullptr) { LOGE("Method not found"); return ""; }
    jstring j_name = env->NewStringUTF(name);
    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId, j_name);
    const char* nativeStr = env->GetStringUTFChars(jstr, 0);
    char* result = strdup(nativeStr);
    env->ReleaseStringUTFChars(jstr, nativeStr);
    env->DeleteLocalRef(j_name);
    env->DeleteLocalRef(jstr);
    return result;
}

JNIEXPORT void JNICALL Java_nitro_nitro_1camera_1module_NitroCameraJniBridge_initialize(JNIEnv* env, jobject thiz, jclass bridgeClass) {
    if (g_bridgeClass == nullptr) {
        g_bridgeClass = (jclass)env->NewGlobalRef(bridgeClass);
    }
}

} // extern "C"
#elif __APPLE__
extern "C" {
extern double _call_add(double a, double b);
double nitro_camera_add(double a, double b) {
    return _call_add(a, b);
}

extern const char* _call_getGreeting(const char* name);
const char* nitro_camera_get_greeting(const char* name) {
    return _call_getGreeting(name);
}

} // extern "C"
#endif
