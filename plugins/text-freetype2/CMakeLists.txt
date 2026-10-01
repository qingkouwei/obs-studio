cmake_minimum_required(VERSION 3.28...3.30)

option(ENABLE_FREETYPE "Enable FreeType text plugin" ON)

if(NOT ENABLE_FREETYPE)
  target_disable(text-freetype2)
  return()
endif()

find_package(Freetype REQUIRED)

# Font discovery is per-platform and only one back end is compiled at a time.
# HarmonyOS (OS_HARMONY) deliberately matches neither branch below: fontconfig
# is not cross-compiled for OHOS, and find-font-unix.c is the only file in this
# plugin that includes <fontconfig/fontconfig.h>. It is selected by
# $<PLATFORM_ID:Linux,FreeBSD,OpenBSD> further down, and the OHOS toolchain sets
# CMAKE_SYSTEM_NAME=OHOS, so PLATFORM_ID is "OHOS" and that translation unit is
# never part of the target — the header is never reached even though __linux__
# is defined on OHOS. find-font-ohos.c replaces it with a scan of the HarmonyOS
# system font directories, which needs no library beyond FreeType itself.
if(OS_MACOS)
  find_package(Iconv REQUIRED)
elseif(OS_LINUX OR OS_FREEBSD OR OS_OPENBSD)
  find_package(Fontconfig REQUIRED)
endif()

add_library(text-freetype2 MODULE)
add_library(OBS::text-freetype2 ALIAS text-freetype2)

target_sources(
  text-freetype2
  PRIVATE
    $<$<PLATFORM_ID:Darwin>:find-font-cocoa.m>
    $<$<PLATFORM_ID:Darwin>:find-font-iconv.c>
    # find-font.c holds the shared family-name -> path table, the font_data.bin
    # cache and get_font_path(); each back end supplies only load_os_font_list(),
    # sfnt_name_to_utf8() and get_font_checksum().
    $<$<PLATFORM_ID:Windows,Darwin,OHOS>:find-font.c>
    $<$<PLATFORM_ID:OHOS>:find-font-ohos.c>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:find-font-unix.c>
    $<$<PLATFORM_ID:Windows>:find-font-windows.c>
    find-font.h
    obs-convenience.c
    obs-convenience.h
    text-freetype2.c
    text-freetype2.h
    text-functionality.c
)

target_link_libraries(
  text-freetype2
  PRIVATE
    OBS::libobs
    Freetype::Freetype
    $<$<PLATFORM_ID:Darwin>:Iconv::Iconv>
    "$<$<PLATFORM_ID:Darwin>:$<LINK_LIBRARY:FRAMEWORK,Cocoa.framework>>"
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:Fontconfig::Fontconfig>
)

# FreeType is hard-coded with /DEFAULTLIB:MSVCRT
target_link_options(text-freetype2 PRIVATE $<$<PLATFORM_ID:Windows>:/IGNORE:4098>)

if(OS_WINDOWS)
  configure_file(cmake/windows/obs-module.rc.in text-freetype2.rc)
  target_sources(text-freetype2 PRIVATE text-freetype2.rc)
endif()

# HarmonyOS reads module data out of the HAP's rawfile assets rather than from a
# filesystem prefix (libobs/obs-harmony.c maps %module% to
# <rawfile>/obs-plugins/%module%). Without this, obs_module_file() would not
# resolve text_default.effect and the source would build a NULL draw effect and
# render nothing, and every property label would come back untranslated.
if(OS_HARMONY)
  install_obs_data(text-freetype2 data "obs-plugins/text-freetype2")
endif()

set_target_properties_obs(text-freetype2 PROPERTIES FOLDER plugins PREFIX "")
