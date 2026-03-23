cmake_minimum_required(VERSION 3.10)
project(nitro_camera_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "/Users/shreemanarjunsahu/.puro/shared/pub_cache/hosted/pub.dev/nitro-0.1.0/src/native")
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(nitro_camera SHARED
  "nitro_camera.cpp"
  "dart_api_dl.c"
)

target_include_directories(nitro_camera PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(nitro_camera PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(nitro_camera PRIVATE android log)
  target_link_options(nitro_camera PRIVATE "-Wl,-z,max-page-size=16384")
endif()
