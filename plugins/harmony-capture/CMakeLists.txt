cmake_minimum_required(VERSION 3.28...3.30)

add_library(harmony-capture MODULE)
add_library(OBS::harmony-capture ALIAS harmony-capture)

target_sources(harmony-capture PRIVATE display-capture.c harmony-capture.c harmony-capture.h window-capture.c)

# libnative_buffer.so backs OH_NativeBuffer_Map*/GetConfig for the CPU readback
# path; it is not part of the shared HarmonyOS::media group.
harmony_find_ndk_library(HarmonyOS::native_buffer native_buffer)

target_link_libraries(harmony-capture PRIVATE OBS::libobs HarmonyOS::media HarmonyOS::native_buffer)

install_obs_data(harmony-capture data "obs-plugins/harmony-capture")

set_target_properties_obs(harmony-capture PROPERTIES FOLDER plugins PREFIX "")
