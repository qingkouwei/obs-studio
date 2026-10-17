cmake_minimum_required(VERSION 3.28...3.30)

add_library(harmony-remotecam MODULE)
add_library(OBS::harmony-remotecam ALIAS harmony-remotecam)

target_sources(harmony-remotecam PRIVATE remote-camera.c harmony-remotecam.c harmony-remotecam.h
                                         remotecam-protocol.h)

# The decoder half of the media NDK group (libnative_media_vdec + codecbase +
# core, see cmake/harmony/helpers.cmake); sockets come from libc.
target_link_libraries(harmony-remotecam PRIVATE OBS::libobs HarmonyOS::media)

install_obs_data(harmony-remotecam data "obs-plugins/harmony-remotecam")

set_target_properties_obs(harmony-remotecam PROPERTIES FOLDER plugins PREFIX "")
