cmake_minimum_required(VERSION 3.28...3.30)

add_library(harmony-audio MODULE)
add_library(OBS::harmony-audio ALIAS harmony-audio)

target_sources(harmony-audio PRIVATE desktop-audio.c harmony-audio.c harmony-audio.h mic-capture.c)

target_link_libraries(harmony-audio PRIVATE OBS::libobs HarmonyOS::ohaudio)

install_obs_data(harmony-audio data "obs-plugins/harmony-audio")

set_target_properties_obs(harmony-audio PROPERTIES FOLDER plugins PREFIX "")
