cmake_minimum_required(VERSION 3.28...3.30)

add_library(libobs-opengl SHARED)
add_library(OBS::libobs-opengl ALIAS libobs-opengl)

# deps/glad generates and loads desktop OpenGL and unconditionally calls
# find_package(OpenGL REQUIRED), neither of which is valid on HarmonyOS. The
# OpenGL ES entry points there come straight out of libGLESv3.so, and the
# shim under harmony/glad satisfies the <glad/glad.h> includes everywhere
# else in this directory, so glad is skipped entirely for that target.
if(NOT OS_HARMONY AND NOT TARGET OBS::glad)
  add_subdirectory("${CMAKE_SOURCE_DIR}/deps/glad" "${CMAKE_BINARY_DIR}/deps/glad")
endif()

if(OS_HARMONY)
  harmony_setup_platform_libraries()
endif()

if(OS_LINUX OR OS_FREEBSD OR OS_OPENBSD)
  find_package(Libdrm REQUIRED)
  find_package(X11 REQUIRED)
  find_package(XCB REQUIRED XCB)
  find_package(X11_XCB REQUIRED)

  if(ENABLE_WAYLAND)
    find_package(OpenGL REQUIRED EGL)
    find_package(Wayland REQUIRED)
  endif()
endif()

target_sources(
  libobs-opengl
  PRIVATE
    $<$<AND:$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>,$<BOOL:${ENABLE_WAYLAND}>>:gl-wayland-egl.c>
    $<$<PLATFORM_ID:Darwin>:gl-cocoa.m>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:gl-egl-common.c>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:gl-nix.c>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:gl-x11-egl.c>
    $<$<PLATFORM_ID:Windows>:gl-windows.c>
    $<$<BOOL:${OS_HARMONY}>:gl-harmony-egl.c>
    $<$<BOOL:${OS_HARMONY}>:gl-harmony-egl.h>
    gl-helpers.c
    gl-helpers.h
    gl-indexbuffer.c
    gl-shader.c
    gl-shaderparser.c
    gl-shaderparser.h
    gl-stagesurf.c
    gl-subsystem.c
    gl-subsystem.h
    gl-texture2d.c
    gl-texture3d.c
    gl-texturecube.c
    gl-vertexbuffer.c
    gl-zstencil.c
)

# Must precede OBS::glad's include directory so the GLES shim is the one that
# resolves <glad/glad.h>. Harmless on other platforms because the directory is
# only populated for HarmonyOS builds.
if(OS_HARMONY)
  target_include_directories(libobs-opengl PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/harmony")
endif()

target_compile_options(libobs-opengl PRIVATE $<$<COMPILE_LANG_AND_ID:C,AppleClang,Clang>:-Wno-strict-prototypes>)

target_compile_definitions(libobs-opengl PRIVATE $<$<PLATFORM_ID:Darwin>:GL_SILENCE_DEPRECATION>)

target_link_libraries(
  libobs-opengl
  PRIVATE
    OBS::libobs
    $<$<NOT:$<BOOL:${OS_HARMONY}>>:OBS::glad>
    "$<$<PLATFORM_ID:Darwin>:$<LINK_LIBRARY:FRAMEWORK,Cocoa.framework>>"
    "$<$<PLATFORM_ID:Darwin>:$<LINK_LIBRARY:FRAMEWORK,IOSurface.framework>>"
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:Libdrm::Libdrm>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:XCB::XCB>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:X11::XCB>
    $<$<AND:$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>,$<BOOL:${ENABLE_WAYLAND}>>:OpenGL::EGL>
    $<$<AND:$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>,$<BOOL:${ENABLE_WAYLAND}>>:Wayland::Egl>
    $<$<BOOL:${OS_HARMONY}>:HarmonyOS::EGL>
    $<$<BOOL:${OS_HARMONY}>:HarmonyOS::GLESv3>
    $<$<BOOL:${OS_HARMONY}>:HarmonyOS::native_window>
    $<$<BOOL:${OS_HARMONY}>:HarmonyOS::hilog>
)

if(OS_WINDOWS)
  configure_file(cmake/windows/obs-module.rc.in libobs-opengl.rc)
  target_sources(libobs-opengl PRIVATE libobs-opengl.rc)
endif()

target_enable_feature(libobs "OpenGL renderer")

set_target_properties_obs(
  libobs-opengl
  PROPERTIES FOLDER core
             VERSION 0
             PREFIX ""
             SOVERSION "${OBS_VERSION_MAJOR}"
)
