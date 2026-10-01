# OBS CMake HarmonyOS compiler configuration module.
#
# The compiler is always the SDK's clang 15 (ohos.toolchain.cmake sets it), so
# there is no GNU branch here. The toolchain already supplies --target,
# --sysroot, the hardening flags and -D__MUSL__.

include_guard(GLOBAL)

include(compiler_common)

option(ENABLE_COMPILER_TRACE "Enable Clang time-trace (requires Ninja)" OFF)
mark_as_advanced(ENABLE_COMPILER_TRACE)

# The SDK toolchain passes --gcc-toolchain= on every compile line, which clang
# 15 considers unused and warns about. Any dependency or OBS target built with
# -Werror would then fail on every translation unit. Suppressing the warning
# class is cheaper and safer than stripping a toolchain flag we do not own.
add_compile_options(-Qunused-arguments)

add_compile_options(
  "$<$<COMPILE_LANG_AND_ID:C,Clang>:${_obs_clang_c_options}>"
  "$<$<COMPILE_LANG_AND_ID:CXX,Clang>:${_obs_clang_cxx_options}>"
)

if(CMAKE_VERSION VERSION_LESS 3.24.0)
  if(CMAKE_COMPILE_WARNING_AS_ERROR)
    add_compile_options(-Werror)
  endif()
endif()

if(ENABLE_COMPILER_TRACE AND CMAKE_GENERATOR STREQUAL "Ninja")
  add_compile_options($<$<COMPILE_LANG_AND_ID:C,Clang>:-ftime-trace> $<$<COMPILE_LANG_AND_ID:CXX,Clang>:-ftime-trace>)
else()
  set(ENABLE_COMPILER_TRACE OFF CACHE STRING "Enable Clang time-trace (requires Ninja)" FORCE)
endif()

# SIMDe emulates the x86 SSE intrinsics libobs uses on arm64. OpenMP is left
# off: OHOS ships libomp.so but enabling it adds a runtime dependency for a
# path that is not on the critical rendering loop.
add_compile_definitions($<$<CONFIG:DEBUG>:DEBUG> $<$<CONFIG:DEBUG>:_DEBUG>)
