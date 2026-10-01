# OBS CMake helpers for HarmonyOS (OHOS) targets.
#
# HarmonyOS ships its platform APIs as prebuilt stub libraries inside the NDK
# sysroot rather than as CMake packages, so find_package() cannot locate them.
# These helpers resolve a stub by name and expose it as an IMPORTED target that
# the rest of the OBS build can link against uniformly.

include_guard(GLOBAL)

include(helpers_common)

# set_target_properties_obs: HarmonyOS variant.
#
# Two deliberate departures from the Linux version:
#   * No RPATH. A HAP's native libraries are loaded from the application
#     sandbox by the runtime loader, which does not honour DT_RUNPATH the way
#     glibc's does; dependencies resolve by soname within libs/{abi}/.
#   * No VERSION/SOVERSION suffixes. The HAP loader and OBS's own os_dlopen()
#     both expect the exact "libfoo.so" filename, so a "libfoo.so.0" symlink
#     would never be found. Everything is emitted unversioned.
function(set_target_properties_obs target)
  set(options "")
  set(oneValueArgs "")
  set(multiValueArgs PROPERTIES)
  cmake_parse_arguments(PARSE_ARGV 0 _STPO "${options}" "${oneValueArgs}" "${multiValueArgs}")

  message(DEBUG "Setting additional properties for target ${target}...")

  while(_STPO_PROPERTIES)
    list(POP_FRONT _STPO_PROPERTIES key value)

    # Callers set VERSION/SOVERSION for the desktop layout; drop them here
    # rather than editing every plugin's CMakeLists.txt.
    if(key STREQUAL "VERSION" OR key STREQUAL "SOVERSION")
      continue()
    endif()

    set_property(TARGET ${target} PROPERTY ${key} "${value}")
  endwhile()

  get_target_property(target_type ${target} TYPE)

  if(target_type STREQUAL EXECUTABLE)
    set_property(GLOBAL APPEND PROPERTY _OBS_EXECUTABLES ${target})

    install(TARGETS ${target} RUNTIME DESTINATION "${OBS_EXECUTABLE_DESTINATION}" COMPONENT Runtime)
  elseif(target_type STREQUAL SHARED_LIBRARY OR target_type STREQUAL MODULE_LIBRARY)
    # Deliberately do NOT set VERSION/SOVERSION here, not even to "". CMake
    # renders an empty SOVERSION as a trailing dot, producing "libobs.so." and a
    # matching DT_NEEDED entry that the HAP loader cannot resolve. Leaving both
    # unset yields a plain "libobs.so", which is what libs/{abi}/ expects.
    #
    # PREFIX is likewise left alone. OBS's own CMakeLists set PREFIX "" for
    # targets whose name already carries the decoration — libobs-opengl must
    # come out as exactly "libobs-opengl.so" because that is the string
    # obs_video_info.graphics_module is dlopened by, and plugins must come out as
    # "obs-ffmpeg.so". Forcing PREFIX "lib" here would produce
    # "liblibobs-opengl.so" and break module loading at runtime.
    set_target_properties(${target} PROPERTIES SUFFIX ".so")

    if(target_type STREQUAL MODULE_LIBRARY)
      set(_destination "${OBS_PLUGIN_DESTINATION}")
    else()
      set(_destination "${OBS_LIBRARY_DESTINATION}")
    endif()

    install(
      TARGETS ${target}
      LIBRARY DESTINATION "${_destination}" COMPONENT Runtime
      PUBLIC_HEADER DESTINATION "${OBS_INCLUDE_DESTINATION}" COMPONENT Development EXCLUDE_FROM_ALL
    )

    # Stage into the build tree so the ArkUI project can be packaged without a
    # separate install step.
    add_custom_command(
      TARGET ${target}
      POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${OBS_OUTPUT_DIR}/$<CONFIG>/${_destination}"
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:${target}>"
              "${OBS_OUTPUT_DIR}/$<CONFIG>/${_destination}/"
      COMMENT "Stage ${target} into ${_destination}"
      VERBATIM
    )

    set_property(GLOBAL APPEND PROPERTY OBS_MODULES_ENABLED ${target})
  endif()
endfunction()

# install_obs_data: stage libobs/plugin data files (effect shaders, locale,
# images) into both the build tree and the HAP rawfile directory, which is
# where find_libobs_data_file() looks at runtime.
function(install_obs_data target source_dir destination)
  # Resolve to an absolute path at configure time, where a relative path means
  # "relative to the source dir". POST_BUILD commands run with the binary dir as
  # their working directory, so passing "data" through unmodified would fail
  # with "Error copying directory from data".
  get_filename_component(source_dir "${source_dir}" ABSOLUTE)

  install(DIRECTORY "${source_dir}" DESTINATION "${OBS_DATA_DESTINATION}/${destination}" COMPONENT Runtime)

  add_custom_command(
    TARGET ${target}
    POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${OBS_HARMONY_RAWFILE_DIR}/${destination}"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${source_dir}" "${OBS_HARMONY_RAWFILE_DIR}/${destination}"
    COMMENT "Stage ${target} data into HAP rawfile/${destination}"
    VERBATIM
  )
endfunction()

# Map the OHOS_ARCH value used by ohos.toolchain.cmake onto the sysroot's
# per-ABI directory name.
function(_harmony_abi_triple OUT_VAR)
  if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH "arm64-v8a")
  endif()

  if(OHOS_ARCH STREQUAL "arm64-v8a")
    set(_triple "aarch64-linux-ohos")
  elseif(OHOS_ARCH STREQUAL "armeabi-v7a")
    set(_triple "arm-linux-ohos")
  elseif(OHOS_ARCH STREQUAL "x86_64")
    set(_triple "x86_64-linux-ohos")
  else()
    message(FATAL_ERROR "Unsupported OHOS_ARCH '${OHOS_ARCH}'. Expected arm64-v8a, armeabi-v7a or x86_64.")
  endif()

  set(${OUT_VAR} "${_triple}" PARENT_SCOPE)
endfunction()

function(_harmony_sysroot_libdir OUT_VAR)
  _harmony_abi_triple(_triple)

  if(NOT CMAKE_SYSROOT)
    message(FATAL_ERROR "CMAKE_SYSROOT is not set. Configure with -DCMAKE_TOOLCHAIN_FILE=<sdk>/native/build/cmake/ohos.toolchain.cmake")
  endif()

  set(${OUT_VAR} "${CMAKE_SYSROOT}/usr/lib/${_triple}" PARENT_SCOPE)
endfunction()

# harmony_find_ndk_library(<target> <stub-name> [<stub-name>...])
#
# Resolves one or more sysroot stub libraries and creates an INTERFACE target
# named <target> that links all of them. Stub names are given without the
# leading "lib" or trailing ".so", e.g. "native_window" finds libnative_window.so.
function(harmony_find_ndk_library TARGET_NAME)
  if(TARGET ${TARGET_NAME})
    return()
  endif()

  _harmony_sysroot_libdir(_libdir)

  set(_libs "")

  foreach(_stub IN LISTS ARGN)
    # Stub files already carry the lib/.so decoration in the sysroot, and some
    # (libace_napi.z.so) have a dotted suffix, so search for the exact filename.
    find_library(
      HARMONY_LIB_${_stub}
      NAMES "lib${_stub}.so"
      PATHS "${_libdir}"
      NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH
    )

    if(NOT HARMONY_LIB_${_stub})
      message(FATAL_ERROR "HarmonyOS stub library 'lib${_stub}.so' not found in ${_libdir}. Is the SDK API level new enough?")
    endif()

    list(APPEND _libs "${HARMONY_LIB_${_stub}}")
  endforeach()

  # GLOBAL is required: a plain IMPORTED target is scoped to the directory that
  # created it and its subdirectories, so the targets made while configuring
  # libobs/ would be invisible to plugins/ and every plugin linking
  # HarmonyOS::ohaudio would fail with "the target was not found".
  add_library(${TARGET_NAME} INTERFACE IMPORTED GLOBAL)
  set_target_properties(${TARGET_NAME} PROPERTIES INTERFACE_LINK_LIBRARIES "${_libs}")
endfunction()

# The full set of HarmonyOS platform libraries OBS needs, grouped by subsystem.
function(harmony_setup_platform_libraries)
  # ArkUI XComponent + NAPI bridge
  harmony_find_ndk_library(HarmonyOS::ace_napi ace_napi.z)
  harmony_find_ndk_library(HarmonyOS::ace_ndk ace_ndk.z)
  harmony_find_ndk_library(HarmonyOS::hilog hilog_ndk.z)

  # Windowing / graphics
  harmony_find_ndk_library(HarmonyOS::native_window native_window)
  harmony_find_ndk_library(HarmonyOS::EGL EGL)
  harmony_find_ndk_library(HarmonyOS::GLESv3 GLESv3)

  # Screen capture and codec
  harmony_find_ndk_library(
    HarmonyOS::media
    native_avscreen_capture
    native_media_venc
    native_media_codecbase
    native_media_core
  )

  # Audio, including system-audio loopback ("内录") from API 26
  harmony_find_ndk_library(HarmonyOS::ohaudio ohaudio)

  # Camera
  harmony_find_ndk_library(HarmonyOS::camera ohcamera)
endfunction()
