# OBS CMake HarmonyOS defaults module.
#
# The install tree here is not a FHS layout: everything is staged into the
# shape a HAP expects, so `hvigorw assembleHap` can pick the artifacts up
# without a repackaging step.

include_guard(GLOBAL)

# Audio monitoring, scripting and the CEF browser panels all have no HarmonyOS
# backend yet. Default them off so a first configure does not fail on missing
# dependencies; each can be flipped on as its port lands.
option(ENABLE_SCRIPTING "Enable scripting support" OFF)
option(ENABLE_BROWSER "Enable browser panel support (CEF)" OFF)

# The new MPEGTS output needs Librist and Libsrt, neither of which is built for
# OHOS. obs-ffmpeg's dependencies.cmake hard-errors without them; the legacy
# MPEGTS path only needs FFmpeg, which we do have.
option(ENABLE_NEW_MPEGTS_OUTPUT "Enable the SRT/Rist-backed MPEGTS output" OFF)

set(OBS_EXECUTABLE_RPATH "")
set(OBS_LIBRARY_RPATH "")
set(OBS_MODULE_RPATH "")

# Root of the ArkUI application project, which consumes these artifacts.
set(OBS_HARMONY_APP_DIR "${CMAKE_SOURCE_DIR}/harmony" CACHE PATH "ArkUI application project consuming the native build")

# HAP native library directory. Must match the {abi} in module.json5's
# executableBinaryPaths and the device ABI being targeted.
set(OBS_HARMONY_ABI "arm64-v8a" CACHE STRING "HAP ABI directory (arm64-v8a, armeabi-v7a or x86_64)")
set(OBS_HARMONY_LIBS_DIR "${OBS_HARMONY_APP_DIR}/entry/libs/${OBS_HARMONY_ABI}")

# HAP rawfile directory, used for libobs data files (effect shaders, locale,
# images) that are read at runtime rather than linked.
set(OBS_HARMONY_RAWFILE_DIR "${OBS_HARMONY_APP_DIR}/entry/src/main/resources/rawfile")

set(OBS_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/rundir")
set(OBS_EXECUTABLE_DESTINATION "bin")
set(OBS_INCLUDE_DESTINATION "include/obs")
set(OBS_LIBRARY_DESTINATION "libs/${OBS_HARMONY_ABI}")
set(OBS_PLUGIN_DESTINATION "libs/${OBS_HARMONY_ABI}")
set(OBS_SCRIPT_PLUGIN_DESTINATION "libs/${OBS_HARMONY_ABI}")
set(OBS_DATA_DESTINATION "share/obs")
set(OBS_CMAKE_DESTINATION "lib/cmake")

set(OBS_PLUGIN_PATH "${OBS_LIBRARY_DESTINATION}")
set(OBS_SCRIPT_PLUGIN_PATH "${OBS_SCRIPT_PLUGIN_DESTINATION}")
set(OBS_DATA_PATH "${OBS_DATA_DESTINATION}")
set(OBS_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

set(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL TRUE)
