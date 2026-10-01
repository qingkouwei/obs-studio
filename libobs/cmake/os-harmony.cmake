# libobs platform configuration for HarmonyOS (OHOS).
#
# Modelled on os-linux.cmake but without X11, XCB, libdrm, D-Bus, GIO,
# Wayland or libuuid — none of which exist on HarmonyOS. The window system is
# an ArkUI XComponent, and input arrives through the ArkUI layer rather than
# an X event queue.

harmony_setup_platform_libraries()

target_sources(
  libobs
  PRIVATE
    obs-harmony.c
    obs-harmony.h
    util/pipe-posix.c
    util/platform-nix.c
    util/threading-posix.c
    util/threading-posix.h
)

# libobs/util/platform-nix.c needs <uuid/uuid.h>; the shim in harmony-compat
# must win over the (absent) system header.
target_include_directories(libobs PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/harmony-compat")

target_compile_definitions(
  libobs
  PRIVATE
    OBS_INSTALL_PREFIX="${OBS_INSTALL_PREFIX}"
    $<$<COMPILE_LANG_AND_ID:C,GNU>:ENABLE_DARRAY_TYPE_TEST>
    $<$<COMPILE_LANG_AND_ID:CXX,GNU>:ENABLE_DARRAY_TYPE_TEST>
)

# musl puts libm symbols in libc, but the CMake probe below handles either
# layout rather than assuming.
set(CMAKE_M_LIBS "")
include(CheckCSourceCompiles)
set(LIBM_TEST_SOURCE "#include<math.h>\nfloat f; int main(){sqrt(f);return 0;}")
check_c_source_compiles("${LIBM_TEST_SOURCE}" HAVE_MATH_IN_STD_LIB)

target_link_libraries(
  libobs
  PRIVATE
    HarmonyOS::hilog
    HarmonyOS::ohaudio
    ${CMAKE_DL_LIBS}
    $<$<NOT:$<BOOL:${HAVE_MATH_IN_STD_LIB}>>:m>
)

# Audio monitoring plays a source back through the local output device, backed
# by OHAudio's pull-based renderer API (see audio-monitoring/harmony/ for the
# ring buffer bridging libobs's push-side audio thread and OHAudio's callback
# thread). HarmonyOS::ohaudio is resolved from the NDK sysroot stub by
# harmony_setup_platform_libraries() above, not by find_package().
target_sources(
  libobs
  PRIVATE
    audio-monitoring/harmony/harmony-audio-monitoring.c
    audio-monitoring/harmony/harmony-audio-monitoring.h
    audio-monitoring/harmony/harmony-audio-output.c
)
target_enable_feature(libobs "Audio monitoring (HarmonyOS OHAudio)")

set_target_properties(libobs PROPERTIES OUTPUT_NAME obs)
