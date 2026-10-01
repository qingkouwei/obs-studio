# OBS CMake operating system bootstrap module

include_guard(GLOBAL)

# HarmonyOS is a cross-compilation target: the host is whatever machine runs the
# build (typically Darwin or Linux) while the target is OHOS. It must therefore
# be matched before any host-based branch below, or a macOS build host would
# silently configure OBS for Metal.
#
# CMAKE_SYSTEM_NAME cannot be used for this test. osconfig is included from
# bootstrap.cmake near the top of CMakeLists.txt, which runs BEFORE project(),
# and the SDK's ohos.toolchain.cmake only sets CMAKE_SYSTEM_NAME during
# project()'s compiler detection — at this point it is still empty.
# CMAKE_TOOLCHAIN_FILE by contrast is a cache variable supplied on the command
# line and is available immediately.
set(_obs_harmony_target FALSE)
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
  set(_obs_harmony_target TRUE)
elseif(DEFINED CMAKE_TOOLCHAIN_FILE AND CMAKE_TOOLCHAIN_FILE MATCHES "(ohos|hmos)\\.toolchain\\.cmake$")
  set(_obs_harmony_target TRUE)
endif()

if(_obs_harmony_target)
  # Match the Linux branch, not Windows/macOS: leave C extensions enabled.
  # HarmonyOS uses musl, and -std=c17 (C_EXTENSIONS FALSE) puts the libc headers
  # into strict ISO mode, which hides POSIX declarations such as fseeko/ftello.
  set(CMAKE_CXX_EXTENSIONS FALSE)
  list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/harmony")
  set(OS_HARMONY TRUE)
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
  set(CMAKE_C_EXTENSIONS FALSE)
  set(CMAKE_CXX_EXTENSIONS FALSE)
  list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/windows")
  set(OS_WINDOWS TRUE)
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
  set(CMAKE_C_EXTENSIONS FALSE)
  set(CMAKE_CXX_EXTENSIONS FALSE)
  list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/macos")
  set(OS_MACOS TRUE)
elseif(CMAKE_HOST_SYSTEM_NAME MATCHES "Linux|FreeBSD|OpenBSD")
  set(CMAKE_CXX_EXTENSIONS FALSE)
  list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/linux")
  string(TOUPPER "${CMAKE_HOST_SYSTEM_NAME}" _SYSTEM_NAME_U)
  set(OS_${_SYSTEM_NAME_U} TRUE)
endif()
