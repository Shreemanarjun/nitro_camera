cmake_minimum_required(VERSION 3.10)
project(nitro_camera_example_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "/Users/shreemanarjunsahu/.puro/shared/pub_cache/hosted/pub.dev/nitro-0.2.2/src/native")

add_library(nitro_camera_example SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_camera_example.bridge.g.cpp"
  "nitro_camera_example.cpp"
  "dart_api_dl.c"
)
target_include_directories(nitro_camera_example PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
target_compile_definitions(nitro_camera_example PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(nitro_camera_example PRIVATE android log)
  target_link_options(nitro_camera_example PRIVATE "-Wl,-z,max-page-size=16384")
endif()
