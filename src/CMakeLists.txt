cmake_minimum_required(VERSION 3.10)
project(nitro_camera_library VERSION 0.0.1 LANGUAGES C CXX)


set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM a13ebe9b80e57e6a
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(nitro_camera SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_camera.bridge.g.cpp"
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
