# ---------------------------------------------------------------------------
# libobs_bridge.so — NAPI bridge between the ArkUI frontend and libobs.
#
# The bridge MUST compile in two modes:
#
#   1. Shell-only (default): libobs has not been cross-compiled for HarmonyOS
#      yet. HAVE_LIBOBS is undefined; every libobs-dependent entry point
#      returns a napi error explaining that the core is not linked. The ArkUI
#      app still builds, installs and runs (XComponent surface plumbing and
#      OHAudio metering are real in this mode).
#
#   2. Linked core: point OBS_HARMONY_PREFIX at a staging directory produced
#      by the outer libobs cross-compile, laid out as:
#
#          <prefix>/include/obs/obs.h, obs-module.h, graphics/..., media-io/...
#              (or <prefix>/include/obs.h — both layouts are accepted)
#          <prefix>/lib/libobs.so [and its dependency .so files]
#
#      Set it either via the hvigor externalNativeOptions "arguments"
#      (-DOBS_HARMONY_PREFIX=...) in entry/build-profile.json5, or by
#      exporting OBS_HARMONY_PREFIX in the environment. HAVE_LIBOBS is then
#      defined automatically and the genuine libobs calls are compiled in.
# ---------------------------------------------------------------------------
cmake_minimum_required(VERSION 3.16)
project(obs_bridge LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# hvigor injects the resolved oh-package dependency graph through this file.
if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

# --- libobs staging prefix (cache var, overridable; env var as fallback) ----
set(OBS_HARMONY_PREFIX "" CACHE PATH
    "Staging prefix with include/ and lib/ from the cross-compiled libobs build")
if(NOT OBS_HARMONY_PREFIX AND DEFINED ENV{OBS_HARMONY_PREFIX})
    set(OBS_HARMONY_PREFIX "$ENV{OBS_HARMONY_PREFIX}"
        CACHE PATH "Staging prefix (from environment)" FORCE)
endif()

# Auto-discover the conventional staging location so a plain `hvigorw assembleHap`
# links the real core without anyone exporting an env var (which hvigor does not
# reliably forward anyway). This file sits at <repo>/harmony/entry/src/main/cpp.
if(NOT OBS_HARMONY_PREFIX)
    get_filename_component(_obs_repo_root "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
    if(EXISTS "${_obs_repo_root}/.ohos-stage/lib/libobs.so")
        set(OBS_HARMONY_PREFIX "${_obs_repo_root}/.ohos-stage"
            CACHE PATH "Staging prefix (auto-discovered)" FORCE)
        message(STATUS "Auto-discovered libobs staging prefix: ${OBS_HARMONY_PREFIX}")
    endif()
endif()

set(OBS_LIBOBS_FOUND FALSE)
if(OBS_HARMONY_PREFIX)
    if(EXISTS "${OBS_HARMONY_PREFIX}/lib/libobs.so")
        set(OBS_LIBOBS_FOUND TRUE)
    else()
        message(WARNING
            "OBS_HARMONY_PREFIX='${OBS_HARMONY_PREFIX}' has no lib/libobs.so — "
            "building the shell-only bridge (HAVE_LIBOBS undefined).")
    endif()
else()
    message(STATUS
        "OBS_HARMONY_PREFIX not set — building the shell-only bridge "
        "(HAVE_LIBOBS undefined). See the comment at the top of this file.")
endif()

add_library(obs_bridge SHARED
    napi_init.cpp
    obs_bridge.cpp
    xcomponent_surface.cpp
)

target_include_directories(obs_bridge PRIVATE ${NATIVERENDER_ROOT_PATH})

# HarmonyOS NDK stub libraries (linked by name; resolved by the OHOS toolchain).
target_link_libraries(obs_bridge PUBLIC
    libace_napi.z.so                    # NAPI runtime
    libhilog_ndk.z.so                   # hilog (native logging)
    libace_ndk.z.so                     # ArkUI native (drawing helpers)
    libnative_window.so                 # NativeWindow / external_window.h
    libEGL.so                           # EGL for the XComponent surface seam
    libGLESv3.so                        # GLES3 (used by the graphics backend)
    libohaudio.so                       # OH_AudioCapturer: loopback + mic
    libnative_avscreen_capture.so       # OH_AVScreenCapture: display/window capture
    libnative_media_venc.so             # OH_VideoEncoder: hardware H.264/H.265
    libnative_media_codecbase.so        # codec base types for the encoder
    libnative_media_core.so             # OH_Buffer etc. for codec payloads
    libdeviceinfo_ndk.z.so              # OH_GetSdkApiVersion (runtime API-level probe)
)

# --- optional: the real libobs ----------------------------------------------
if(OBS_LIBOBS_FOUND)
    # Locate the headers: OBS installs them under include/obs/ (obs.h,
    # graphics/, media-io/, util/ ...); accept a flat include/ too.
    if(EXISTS "${OBS_HARMONY_PREFIX}/include/obs/obs.h")
        set(OBS_INCLUDE_DIR "${OBS_HARMONY_PREFIX}/include/obs")
    elseif(EXISTS "${OBS_HARMONY_PREFIX}/include/obs.h")
        set(OBS_INCLUDE_DIR "${OBS_HARMONY_PREFIX}/include")
    else()
        message(FATAL_ERROR
            "OBS_HARMONY_PREFIX='${OBS_HARMONY_PREFIX}' has lib/libobs.so but no "
            "obs.h under include/obs/ or include/.")
    endif()

    target_compile_definitions(obs_bridge PRIVATE HAVE_LIBOBS=1)
    target_include_directories(obs_bridge PRIVATE ${OBS_INCLUDE_DIR})
    # libobs's public headers pull in vendored dependency headers (simde for
    # SSE emulation via util/sse-intrin.h, plus jansson/mbedTLS users). Stage
    # those under <prefix>/include as well — e.g. copy the contents of
    # obs-studio/.deps-harmony/include next to the libobs headers — so this
    # second include path resolves them.
    if(EXISTS "${OBS_HARMONY_PREFIX}/include"
       AND NOT OBS_INCLUDE_DIR STREQUAL "${OBS_HARMONY_PREFIX}/include")
        target_include_directories(obs_bridge PRIVATE "${OBS_HARMONY_PREFIX}/include")
    endif()

    add_library(libobs_core SHARED IMPORTED GLOBAL)
    set_target_properties(libobs_core PROPERTIES
        IMPORTED_LOCATION "${OBS_HARMONY_PREFIX}/lib/libobs.so")
    target_link_libraries(obs_bridge PUBLIC libobs_core)
    target_link_directories(obs_bridge PUBLIC "${OBS_HARMONY_PREFIX}/lib")

    # libobs depends on a handful of vendored/third-party libs. Link whichever
    # ones the staging dir actually provides; libobs's own RPATH/runpath or the
    # HAP lib dir must supply them at runtime.
    foreach(OBS_DEP jansson mbedcrypto mbedx509 mbedtls z lzma speexdsp curl)
        find_library(OBS_DEP_${OBS_DEP} NAMES ${OBS_DEP}
                     PATHS "${OBS_HARMONY_PREFIX}/lib" NO_DEFAULT_PATH)
        if(OBS_DEP_${OBS_DEP})
            message(STATUS "Linking staged libobs dependency: ${OBS_DEP}")
            target_link_libraries(obs_bridge PUBLIC ${OBS_DEP_${OBS_DEP}})
        endif()
    endforeach()
endif()
