cmake_minimum_required(VERSION 3.28...3.30)

add_library(harmony-vcodec MODULE)
add_library(OBS::harmony-vcodec ALIAS harmony-vcodec)

target_sources(harmony-vcodec PRIVATE harmony-vcodec.c)

# ENABLE_HEVC is propagated by OBS::libobs as a public compile definition when
# the option is ON, gating the harmony_hevc registration in the C sources.

target_link_libraries(
  harmony-vcodec
  PRIVATE
    OBS::libobs
    HarmonyOS::media
    HarmonyOS::native_window
    HarmonyOS::EGL
    HarmonyOS::GLESv3
)

install_obs_data(harmony-vcodec data "obs-plugins/harmony-vcodec")

set_target_properties_obs(harmony-vcodec PROPERTIES FOLDER plugins PREFIX "")
