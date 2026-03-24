#pragma once

#include <stdint.h>
#include <stdbool.h>

// --- Enums ---
typedef enum {
  CAMERAPOSITION_FRONT = 0,
  CAMERAPOSITION_BACK = 1,
  CAMERAPOSITION_EXTERNAL = 2,
} CameraPosition;

typedef enum {
  CAMERALENSTYPE_UNKNOWN = 0,
  CAMERALENSTYPE_WIDE_ANGLE = 1,
  CAMERALENSTYPE_ULTRA_WIDE_ANGLE = 2,
  CAMERALENSTYPE_TELEPHOTO = 3,
} CameraLensType;

typedef enum {
  FLASHMODE_OFF = 0,
  FLASHMODE_ON = 1,
  FLASHMODE_AUTO = 2,
} FlashMode;

typedef enum {
  AUTOFOCUSMODE_OFF = 0,
  AUTOFOCUSMODE_CONTINUOUS = 1,
  AUTOFOCUSMODE_LOCKED = 2,
} AutoFocusMode;

typedef enum {
  PERMISSIONSTATUS_NOT_DETERMINED = 0,
  PERMISSIONSTATUS_GRANTED = 1,
  PERMISSIONSTATUS_DENIED = 2,
  PERMISSIONSTATUS_RESTRICTED = 3,
} PermissionStatus;

// --- Structs ---
#pragma pack(push, 1)
typedef struct {
  const char* id; 
  const char* name; 
  int64_t position; 
  int64_t lensType; 
  int64_t sensorOrientation; 
  double minZoom; 
  double maxZoom; 
  double neutralZoom; 
  int64_t hasFlash; 
  int64_t hasTorch; 
  int64_t maxPhotoWidth; 
  int64_t maxPhotoHeight; 
} CameraDevice;
#pragma pack(pop)

typedef struct {
  uint8_t* pixels; /* zero-copy */
  int64_t size; 
  int64_t width; 
  int64_t height; 
  int64_t timestamp; 
  int64_t orientation; 
  int64_t textureId; 
} CameraFrame;

#pragma pack(push, 1)
typedef struct {
  const char* path; 
  int64_t width; 
  int64_t height; 
  int64_t fileSize; 
} PhotoResult;
#pragma pack(pop)

#pragma pack(push, 1)
typedef struct {
  const char* path; 
  int64_t durationMs; 
  int64_t fileSize; 
} RecordingResult;
#pragma pack(pop)

#ifdef __cplusplus
extern "C" {
#endif

// Methods
int64_t nitro_camera_request_camera_permission(void);
int64_t nitro_camera_get_camera_permission_status(void);
int64_t nitro_camera_request_microphone_permission(void);
int64_t nitro_camera_get_microphone_permission_status(void);
int64_t nitro_camera_get_device_count(void);
void* nitro_camera_get_device(int64_t index);
int64_t nitro_camera_open_camera(const char* deviceId, int64_t width, int64_t height, int64_t fps, int64_t enableAudio);
void nitro_camera_close_camera(int64_t textureId);
void nitro_camera_start_preview(int64_t textureId);
void nitro_camera_stop_preview(int64_t textureId);
void nitro_camera_set_zoom(int64_t textureId, double zoom);
void nitro_camera_set_focus_point(int64_t textureId, double x, double y);
void nitro_camera_set_auto_focus(int64_t textureId, int64_t mode);
void nitro_camera_set_exposure(int64_t textureId, double value);
void nitro_camera_set_flash(int64_t textureId, int64_t mode);
void nitro_camera_set_torch(int64_t textureId, int64_t enabled);
void nitro_camera_set_white_balance(int64_t textureId, int64_t temperature);
void nitro_camera_set_hdr(int64_t textureId, int64_t enabled);
void* nitro_camera_take_photo(int64_t textureId);
void nitro_camera_start_video_recording(int64_t textureId, const char* outputPath);
void* nitro_camera_stop_video_recording(int64_t textureId);
void nitro_camera_enable_frame_processing(int64_t textureId, int64_t enabled);
void nitro_camera_set_frame_format(int64_t textureId, int64_t format);
void nitro_camera_set_filter_shader(int64_t textureId, const char* shaderSource);
void nitro_camera_update_overlay(int64_t textureId, const char* overlayData);

// Streams
// Stream<CameraFrame> frameStream
void nitro_camera_register_frame_stream_stream(int64_t dart_port);
void nitro_camera_release_frame_stream_stream(int64_t dart_port);

#ifdef __cplusplus
}
#endif
