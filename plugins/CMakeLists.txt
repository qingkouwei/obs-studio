cmake_minimum_required(VERSION 3.28...3.30)

option(ENABLE_PLUGINS "Enable building OBS plugins" ON)

if(NOT ENABLE_PLUGINS)
  set_property(GLOBAL APPEND PROPERTY OBS_FEATURES_DISABLED "Plugin Support")
  return()
endif()

set_property(GLOBAL APPEND PROPERTY OBS_FEATURES_ENABLED "Plugin Support")

macro(check_obs_browser)
  if((OS_WINDOWS AND CMAKE_VS_PLATFORM_NAME MATCHES "(ARM64|x64)") OR OS_MACOS OR OS_LINUX)
    if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/obs-browser/CMakeLists.txt")
      message(FATAL_ERROR "Required submodule 'obs-browser' not available.")
    else()
      add_subdirectory(obs-browser)
    endif()
  else()
    add_custom_target(obs-browser)
    target_disable(obs-browser)
  endif()
endmacro()

macro(check_obs_websocket)
  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/obs-websocket/CMakeLists.txt")
    message(FATAL_ERROR "Required submodule 'obs-websocket' not available.")
  else()
    add_subdirectory(obs-websocket)
  endif()
endmacro()

# Add plugins in alphabetical order to retain order in IDE projects
add_obs_plugin(
    aja
    PLATFORMS WINDOWS MACOS LINUX
    WITH_MESSAGE
)
add_obs_plugin(aja-output-ui PLATFORMS WINDOWS MACOS LINUX WITH_MESSAGE)
add_obs_plugin(coreaudio-encoder PLATFORMS WINDOWS MACOS)
add_obs_plugin(
    decklink
    PLATFORMS WINDOWS MACOS LINUX
    WITH_MESSAGE
)
add_obs_plugin(
    decklink-captions
    PLATFORMS WINDOWS MACOS LINUX
    WITH_MESSAGE
)
add_obs_plugin(
    decklink-output-ui
    PLATFORMS WINDOWS MACOS LINUX
    WITH_MESSAGE
)
add_obs_plugin(
    frontend-tools
    PLATFORMS WINDOWS MACOS LINUX
    WITH_MESSAGE
)
add_obs_plugin(harmony-audio PLATFORMS HARMONY WITH_MESSAGE)
add_obs_plugin(harmony-camera PLATFORMS HARMONY WITH_MESSAGE)
add_obs_plugin(harmony-capture PLATFORMS HARMONY WITH_MESSAGE)
add_obs_plugin(harmony-vcodec PLATFORMS HARMONY WITH_MESSAGE)
add_obs_plugin(image-source)
add_obs_plugin(linux-alsa PLATFORMS LINUX FREEBSD OPENBSD)
add_obs_plugin(linux-capture PLATFORMS LINUX FREEBSD OPENBSD)
add_obs_plugin(linux-jack PLATFORMS LINUX FREEBSD OPENBSD)
add_obs_plugin(linux-pipewire PLATFORMS LINUX FREEBSD OPENBSD)
add_obs_plugin(linux-pulseaudio PLATFORMS LINUX FREEBSD OPENBSD)
add_obs_plugin(linux-v4l2 PLATFORMS LINUX FREEBSD OPENBSD)
add_obs_plugin(mac-avcapture PLATFORMS MACOS)
add_obs_plugin(mac-capture PLATFORMS MACOS)
add_obs_plugin(mac-syphon PLATFORMS MACOS)
add_obs_plugin(mac-videotoolbox PLATFORMS MACOS)
add_obs_plugin(mac-virtualcam PLATFORMS MACOS)
add_obs_plugin(nv-filters PLATFORMS WINDOWS)

check_obs_browser()

add_obs_plugin(obs-ffmpeg)
add_obs_plugin(obs-filters)
# libfdk-aac is not cross-compiled for HarmonyOS. Not a functional loss: the
# obs-deps FFmpeg build enables its native aac encoder.
if(NOT OS_HARMONY)
  add_obs_plugin(obs-libfdk)
endif()
add_obs_plugin(obs-nvenc PLATFORMS WINDOWS LINUX ARCHITECTURES x64 x86_64)
add_obs_plugin(obs-outputs)
add_obs_plugin(
    obs-qsv11
    PLATFORMS WINDOWS LINUX
    ARCHITECTURES x64 x86_64
)
add_obs_plugin(obs-text PLATFORMS WINDOWS)
add_obs_plugin(obs-transitions)
add_obs_plugin(
    obs-vst
    PLATFORMS WINDOWS MACOS LINUX
    WITH_MESSAGE
)
# obs-webrtc needs libdatachannel, which is not cross-compiled for HarmonyOS.
add_obs_plugin(obs-webrtc PLATFORMS WINDOWS MACOS LINUX)

# obs-websocket is a git submodule that depends on asio and websocketpp; neither
# is available for OHOS yet, and the ArkUI frontend talks to libobs in-process
# rather than over a socket.
if(NOT OS_HARMONY)
  check_obs_websocket()
endif()

add_obs_plugin(obs-x264)
add_obs_plugin(oss-audio PLATFORMS FREEBSD OPENBSD)
add_obs_plugin(rtmp-services)
add_obs_plugin(sndio PLATFORMS LINUX FREEBSD OPENBSD)
# text-freetype2 needs FreeType, which build-aux/harmony/deps/freetype.sh
# cross-compiles as a static, PIC library with every optional back end disabled
# (harfbuzz, fontconfig, brotli, bzip2, png, system zlib), so the whole chain is
# one self-contained libfreetype.a absorbed into text-freetype2.so. Font
# discovery on OHOS does not go through fontconfig: plugins/text-freetype2/
# find-font-ohos.c scans /system/fonts directly. vlc-video still needs libvlc.
add_obs_plugin(text-freetype2)
if(NOT OS_HARMONY)
  add_obs_plugin(vlc-video WITH_MESSAGE)
endif()
add_obs_plugin(win-capture PLATFORMS WINDOWS)
add_obs_plugin(win-dshow PLATFORMS WINDOWS)
add_obs_plugin(win-wasapi PLATFORMS WINDOWS)
