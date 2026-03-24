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

static CameraDevice pack_CameraDevice_from_jni(JNIEnv* env, jobject obj) {
    CameraDevice result;
    jclass cls = env->GetObjectClass(obj);
    jfieldID fid_id = env->GetFieldID(cls, "id", "Ljava/lang/String;");
    jstring j_id = (jstring)env->GetObjectField(obj, fid_id);
    const char* str_id = env->GetStringUTFChars(j_id, 0);
    result.id = strdup(str_id);
    env->ReleaseStringUTFChars(j_id, str_id);
    jfieldID fid_name = env->GetFieldID(cls, "name", "Ljava/lang/String;");
    jstring j_name = (jstring)env->GetObjectField(obj, fid_name);
    const char* str_name = env->GetStringUTFChars(j_name, 0);
    result.name = strdup(str_name);
    env->ReleaseStringUTFChars(j_name, str_name);
    jfieldID fid_position = env->GetFieldID(cls, "position", "J");
    result.position = env->GetLongField(obj, fid_position);
    jfieldID fid_lensType = env->GetFieldID(cls, "lensType", "J");
    result.lensType = env->GetLongField(obj, fid_lensType);
    jfieldID fid_sensorOrientation = env->GetFieldID(cls, "sensorOrientation", "J");
    result.sensorOrientation = env->GetLongField(obj, fid_sensorOrientation);
    jfieldID fid_minZoom = env->GetFieldID(cls, "minZoom", "D");
    result.minZoom = env->GetDoubleField(obj, fid_minZoom);
    jfieldID fid_maxZoom = env->GetFieldID(cls, "maxZoom", "D");
    result.maxZoom = env->GetDoubleField(obj, fid_maxZoom);
    jfieldID fid_neutralZoom = env->GetFieldID(cls, "neutralZoom", "D");
    result.neutralZoom = env->GetDoubleField(obj, fid_neutralZoom);
    jfieldID fid_hasFlash = env->GetFieldID(cls, "hasFlash", "J");
    result.hasFlash = env->GetLongField(obj, fid_hasFlash);
    jfieldID fid_hasTorch = env->GetFieldID(cls, "hasTorch", "J");
    result.hasTorch = env->GetLongField(obj, fid_hasTorch);
    jfieldID fid_maxPhotoWidth = env->GetFieldID(cls, "maxPhotoWidth", "J");
    result.maxPhotoWidth = env->GetLongField(obj, fid_maxPhotoWidth);
    jfieldID fid_maxPhotoHeight = env->GetFieldID(cls, "maxPhotoHeight", "J");
    result.maxPhotoHeight = env->GetLongField(obj, fid_maxPhotoHeight);
    return result;
}
static jobject unpack_CameraDevice_to_jni(JNIEnv* env, const CameraDevice* st) {
    jclass cls = env->FindClass("nitro/nitro_camera_module/CameraDevice");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(Ljava/lang/String;Ljava/lang/String;JJJDDDJJJJ)V");
    return env->NewObject(cls, ctor, env->NewStringUTF(st->id), env->NewStringUTF(st->name), (jlong)st->position, (jlong)st->lensType, (jlong)st->sensorOrientation, (jdouble)st->minZoom, (jdouble)st->maxZoom, (jdouble)st->neutralZoom, (jlong)st->hasFlash, (jlong)st->hasTorch, (jlong)st->maxPhotoWidth, (jlong)st->maxPhotoHeight);
}
static CameraFrame pack_CameraFrame_from_jni(JNIEnv* env, jobject obj) {
    CameraFrame result;
    jclass cls = env->GetObjectClass(obj);
    jfieldID fid_pixels = env->GetFieldID(cls, "pixels", "Ljava/nio/ByteBuffer;");
    jobject buf_pixels = env->GetObjectField(obj, fid_pixels);
    result.pixels = (uint8_t*)env->GetDirectBufferAddress(buf_pixels);
    jfieldID fid_size = env->GetFieldID(cls, "size", "J");
    result.size = env->GetLongField(obj, fid_size);
    jfieldID fid_width = env->GetFieldID(cls, "width", "J");
    result.width = env->GetLongField(obj, fid_width);
    jfieldID fid_height = env->GetFieldID(cls, "height", "J");
    result.height = env->GetLongField(obj, fid_height);
    jfieldID fid_timestamp = env->GetFieldID(cls, "timestamp", "J");
    result.timestamp = env->GetLongField(obj, fid_timestamp);
    jfieldID fid_orientation = env->GetFieldID(cls, "orientation", "J");
    result.orientation = env->GetLongField(obj, fid_orientation);
    jfieldID fid_textureId = env->GetFieldID(cls, "textureId", "J");
    result.textureId = env->GetLongField(obj, fid_textureId);
    return result;
}
static jobject unpack_CameraFrame_to_jni(JNIEnv* env, const CameraFrame* st) {
    jclass cls = env->FindClass("nitro/nitro_camera_module/CameraFrame");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(Ljava/nio/ByteBuffer;JJJJJJ)V");
    return env->NewObject(cls, ctor, env->NewDirectByteBuffer((void*)st->pixels, st->size), (jlong)st->size, (jlong)st->width, (jlong)st->height, (jlong)st->timestamp, (jlong)st->orientation, (jlong)st->textureId);
}
static PhotoResult pack_PhotoResult_from_jni(JNIEnv* env, jobject obj) {
    PhotoResult result;
    jclass cls = env->GetObjectClass(obj);
    jfieldID fid_path = env->GetFieldID(cls, "path", "Ljava/lang/String;");
    jstring j_path = (jstring)env->GetObjectField(obj, fid_path);
    const char* str_path = env->GetStringUTFChars(j_path, 0);
    result.path = strdup(str_path);
    env->ReleaseStringUTFChars(j_path, str_path);
    jfieldID fid_width = env->GetFieldID(cls, "width", "J");
    result.width = env->GetLongField(obj, fid_width);
    jfieldID fid_height = env->GetFieldID(cls, "height", "J");
    result.height = env->GetLongField(obj, fid_height);
    jfieldID fid_fileSize = env->GetFieldID(cls, "fileSize", "J");
    result.fileSize = env->GetLongField(obj, fid_fileSize);
    return result;
}
static jobject unpack_PhotoResult_to_jni(JNIEnv* env, const PhotoResult* st) {
    jclass cls = env->FindClass("nitro/nitro_camera_module/PhotoResult");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(Ljava/lang/String;JJJ)V");
    return env->NewObject(cls, ctor, env->NewStringUTF(st->path), (jlong)st->width, (jlong)st->height, (jlong)st->fileSize);
}
static RecordingResult pack_RecordingResult_from_jni(JNIEnv* env, jobject obj) {
    RecordingResult result;
    jclass cls = env->GetObjectClass(obj);
    jfieldID fid_path = env->GetFieldID(cls, "path", "Ljava/lang/String;");
    jstring j_path = (jstring)env->GetObjectField(obj, fid_path);
    const char* str_path = env->GetStringUTFChars(j_path, 0);
    result.path = strdup(str_path);
    env->ReleaseStringUTFChars(j_path, str_path);
    jfieldID fid_durationMs = env->GetFieldID(cls, "durationMs", "J");
    result.durationMs = env->GetLongField(obj, fid_durationMs);
    jfieldID fid_fileSize = env->GetFieldID(cls, "fileSize", "J");
    result.fileSize = env->GetLongField(obj, fid_fileSize);
    return result;
}
static jobject unpack_RecordingResult_to_jni(JNIEnv* env, const RecordingResult* st) {
    jclass cls = env->FindClass("nitro/nitro_camera_module/RecordingResult");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(Ljava/lang/String;JJ)V");
    return env->NewObject(cls, ctor, env->NewStringUTF(st->path), (jlong)st->durationMs, (jlong)st->fileSize);
}

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

int64_t nitro_camera_request_camera_permission(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "requestCameraPermission_call", "()J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    return env->CallStaticLongMethod(g_bridgeClass, methodId);
}

int64_t nitro_camera_get_camera_permission_status(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getCameraPermissionStatus_call", "()J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    return env->CallStaticLongMethod(g_bridgeClass, methodId);
}

int64_t nitro_camera_request_microphone_permission(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "requestMicrophonePermission_call", "()J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    return env->CallStaticLongMethod(g_bridgeClass, methodId);
}

int64_t nitro_camera_get_microphone_permission_status(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getMicrophonePermissionStatus_call", "()J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    return env->CallStaticLongMethod(g_bridgeClass, methodId);
}

int64_t nitro_camera_get_device_count(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getDeviceCount_call", "()J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    return env->CallStaticLongMethod(g_bridgeClass, methodId);
}

void* nitro_camera_get_device(int64_t index) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getDevice_call", "(J)Lnitro/nitro_camera_module/CameraDevice;");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }
    jobject jobj = env->CallStaticObjectMethod(g_bridgeClass, methodId, index);
    if (jobj == nullptr) return nullptr;
    CameraDevice* result = (CameraDevice*)malloc(sizeof(CameraDevice));
    *result = pack_CameraDevice_from_jni(env, jobj);
    env->DeleteLocalRef(jobj);
    return result;
}

int64_t nitro_camera_open_camera(const char* deviceId, int64_t width, int64_t height, int64_t fps, int64_t enableAudio) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "openCamera_call", "(Ljava/lang/String;JJJJ)J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    jstring j_deviceId = env->NewStringUTF(deviceId);
    return env->CallStaticLongMethod(g_bridgeClass, methodId, j_deviceId, width, height, fps, enableAudio);
}

void nitro_camera_close_camera(int64_t textureId) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "closeCamera_call", "(J)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId);
}

void nitro_camera_start_preview(int64_t textureId) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "startPreview_call", "(J)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId);
}

void nitro_camera_stop_preview(int64_t textureId) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "stopPreview_call", "(J)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId);
}

void nitro_camera_set_zoom(int64_t textureId, double zoom) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setZoom_call", "(JD)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, zoom);
}

void nitro_camera_set_focus_point(int64_t textureId, double x, double y) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setFocusPoint_call", "(JDD)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, x, y);
}

void nitro_camera_set_auto_focus(int64_t textureId, int64_t mode) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setAutoFocus_call", "(JJ)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, mode);
}

void nitro_camera_set_exposure(int64_t textureId, double value) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setExposure_call", "(JD)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, value);
}

void nitro_camera_set_flash(int64_t textureId, int64_t mode) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setFlash_call", "(JJ)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, mode);
}

void nitro_camera_set_torch(int64_t textureId, int64_t enabled) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setTorch_call", "(JJ)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, enabled);
}

void nitro_camera_set_white_balance(int64_t textureId, int64_t temperature) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setWhiteBalance_call", "(JJ)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, temperature);
}

void nitro_camera_set_hdr(int64_t textureId, int64_t enabled) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setHdr_call", "(JJ)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, enabled);
}

void* nitro_camera_take_photo(int64_t textureId) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "takePhoto_call", "(J)Lnitro/nitro_camera_module/PhotoResult;");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }
    jobject jobj = env->CallStaticObjectMethod(g_bridgeClass, methodId, textureId);
    if (jobj == nullptr) return nullptr;
    PhotoResult* result = (PhotoResult*)malloc(sizeof(PhotoResult));
    *result = pack_PhotoResult_from_jni(env, jobj);
    env->DeleteLocalRef(jobj);
    return result;
}

void nitro_camera_start_video_recording(int64_t textureId, const char* outputPath) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "startVideoRecording_call", "(JLjava/lang/String;)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    jstring j_outputPath = env->NewStringUTF(outputPath);
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, j_outputPath);
}

void* nitro_camera_stop_video_recording(int64_t textureId) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "stopVideoRecording_call", "(J)Lnitro/nitro_camera_module/RecordingResult;");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }
    jobject jobj = env->CallStaticObjectMethod(g_bridgeClass, methodId, textureId);
    if (jobj == nullptr) return nullptr;
    RecordingResult* result = (RecordingResult*)malloc(sizeof(RecordingResult));
    *result = pack_RecordingResult_from_jni(env, jobj);
    env->DeleteLocalRef(jobj);
    return result;
}

void nitro_camera_enable_frame_processing(int64_t textureId, int64_t enabled) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "enableFrameProcessing_call", "(JJ)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, enabled);
}

void nitro_camera_set_frame_format(int64_t textureId, int64_t format) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setFrameFormat_call", "(JJ)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, format);
}

void nitro_camera_set_filter_shader(int64_t textureId, const char* shaderSource) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "setFilterShader_call", "(JLjava/lang/String;)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    jstring j_shaderSource = env->NewStringUTF(shaderSource);
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, j_shaderSource);
}

void nitro_camera_update_overlay(int64_t textureId, const char* overlayData) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "updateOverlay_call", "(JLjava/lang/String;)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    jstring j_overlayData = env->NewStringUTF(overlayData);
    env->CallStaticVoidMethod(g_bridgeClass, methodId, textureId, j_overlayData);
}

void nitro_camera_register_frame_stream_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "nitro_camera_register_frame_stream_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

void nitro_camera_release_frame_stream_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "nitro_camera_release_frame_stream_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

JNIEXPORT void JNICALL Java_nitro_nitro_1camera_1module_NitroCameraJniBridge_emit_1frameStream(JNIEnv* env, jobject thiz, jlong dartPort, jobject item) {
    Dart_CObject obj;
    CameraFrame* st_ptr = (CameraFrame*)malloc(sizeof(CameraFrame));
    *st_ptr = pack_CameraFrame_from_jni(env, item);
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)st_ptr;
    Dart_PostCObject_DL(dartPort, &obj);
}

JNIEXPORT void JNICALL Java_nitro_nitro_1camera_1module_NitroCameraJniBridge_initialize(JNIEnv* env, jobject thiz, jclass bridgeClass) {
    if (g_bridgeClass == nullptr) {
        g_bridgeClass = (jclass)env->NewGlobalRef(bridgeClass);
    }
}

} // extern "C"
#elif __APPLE__
extern "C" {
extern int64_t _call_requestCameraPermission(void);
int64_t nitro_camera_request_camera_permission(void) {
    return _call_requestCameraPermission();
}

extern int64_t _call_getCameraPermissionStatus(void);
int64_t nitro_camera_get_camera_permission_status(void) {
    return _call_getCameraPermissionStatus();
}

extern int64_t _call_requestMicrophonePermission(void);
int64_t nitro_camera_request_microphone_permission(void) {
    return _call_requestMicrophonePermission();
}

extern int64_t _call_getMicrophonePermissionStatus(void);
int64_t nitro_camera_get_microphone_permission_status(void) {
    return _call_getMicrophonePermissionStatus();
}

extern int64_t _call_getDeviceCount(void);
int64_t nitro_camera_get_device_count(void) {
    return _call_getDeviceCount();
}

extern void* _call_getDevice(int64_t index);
void* nitro_camera_get_device(int64_t index) {
    return _call_getDevice(index);
}

extern int64_t _call_openCamera(const char* deviceId, int64_t width, int64_t height, int64_t fps, int64_t enableAudio);
int64_t nitro_camera_open_camera(const char* deviceId, int64_t width, int64_t height, int64_t fps, int64_t enableAudio) {
    return _call_openCamera(deviceId, width, height, fps, enableAudio);
}

extern void _call_closeCamera(int64_t textureId);
void nitro_camera_close_camera(int64_t textureId) {
    _call_closeCamera(textureId);
}

extern void _call_startPreview(int64_t textureId);
void nitro_camera_start_preview(int64_t textureId) {
    _call_startPreview(textureId);
}

extern void _call_stopPreview(int64_t textureId);
void nitro_camera_stop_preview(int64_t textureId) {
    _call_stopPreview(textureId);
}

extern void _call_setZoom(int64_t textureId, double zoom);
void nitro_camera_set_zoom(int64_t textureId, double zoom) {
    _call_setZoom(textureId, zoom);
}

extern void _call_setFocusPoint(int64_t textureId, double x, double y);
void nitro_camera_set_focus_point(int64_t textureId, double x, double y) {
    _call_setFocusPoint(textureId, x, y);
}

extern void _call_setAutoFocus(int64_t textureId, int64_t mode);
void nitro_camera_set_auto_focus(int64_t textureId, int64_t mode) {
    _call_setAutoFocus(textureId, mode);
}

extern void _call_setExposure(int64_t textureId, double value);
void nitro_camera_set_exposure(int64_t textureId, double value) {
    _call_setExposure(textureId, value);
}

extern void _call_setFlash(int64_t textureId, int64_t mode);
void nitro_camera_set_flash(int64_t textureId, int64_t mode) {
    _call_setFlash(textureId, mode);
}

extern void _call_setTorch(int64_t textureId, int64_t enabled);
void nitro_camera_set_torch(int64_t textureId, int64_t enabled) {
    _call_setTorch(textureId, enabled);
}

extern void _call_setWhiteBalance(int64_t textureId, int64_t temperature);
void nitro_camera_set_white_balance(int64_t textureId, int64_t temperature) {
    _call_setWhiteBalance(textureId, temperature);
}

extern void _call_setHdr(int64_t textureId, int64_t enabled);
void nitro_camera_set_hdr(int64_t textureId, int64_t enabled) {
    _call_setHdr(textureId, enabled);
}

extern void* _call_takePhoto(int64_t textureId);
void* nitro_camera_take_photo(int64_t textureId) {
    return _call_takePhoto(textureId);
}

extern void _call_startVideoRecording(int64_t textureId, const char* outputPath);
void nitro_camera_start_video_recording(int64_t textureId, const char* outputPath) {
    _call_startVideoRecording(textureId, outputPath);
}

extern void* _call_stopVideoRecording(int64_t textureId);
void* nitro_camera_stop_video_recording(int64_t textureId) {
    return _call_stopVideoRecording(textureId);
}

extern void _call_enableFrameProcessing(int64_t textureId, int64_t enabled);
void nitro_camera_enable_frame_processing(int64_t textureId, int64_t enabled) {
    _call_enableFrameProcessing(textureId, enabled);
}

extern void _call_setFrameFormat(int64_t textureId, int64_t format);
void nitro_camera_set_frame_format(int64_t textureId, int64_t format) {
    _call_setFrameFormat(textureId, format);
}

extern void _call_setFilterShader(int64_t textureId, const char* shaderSource);
void nitro_camera_set_filter_shader(int64_t textureId, const char* shaderSource) {
    _call_setFilterShader(textureId, shaderSource);
}

extern void _call_updateOverlay(int64_t textureId, const char* overlayData);
void nitro_camera_update_overlay(int64_t textureId, const char* overlayData) {
    _call_updateOverlay(textureId, overlayData);
}

void _emit_frameStream_to_dart(int64_t dartPort, void* item) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)item;
    Dart_PostCObject_DL(dartPort, &obj);
}

extern void _register_frameStream_stream(int64_t dartPort, void (*emitCb)(int64_t, void*));
void nitro_camera_register_frame_stream_stream(int64_t dart_port) {
    _register_frameStream_stream(dart_port, _emit_frameStream_to_dart);
}
extern void _release_frameStream_stream(int64_t dart_port);
void nitro_camera_release_frame_stream_stream(int64_t dart_port) {
    _release_frameStream_stream(dart_port);
}

} // extern "C"
#endif
