cmake_minimum_required(VERSION 3.28...3.30)

add_library(harmony-camera MODULE)
add_library(OBS::harmony-camera ALIAS harmony-camera)

target_sources(harmony-camera PRIVATE camera-capture.c harmony-camera.c harmony-camera.h)

# libimage_receiver.so backs OH_ImageReceiverOptions_*/OH_ImageReceiverNative_*,
# libohimage.so backs OH_ImageNative_* (the CPU frame readback path) and
# libnative_buffer.so backs OH_NativeBuffer_Map*; none of them are part of
# libohcamera.so nor of the shared HarmonyOS::media group.
harmony_find_ndk_library(HarmonyOS::image_receiver image_receiver ohimage)
harmony_find_ndk_library(HarmonyOS::native_buffer native_buffer)

target_link_libraries(harmony-camera PRIVATE OBS::libobs HarmonyOS::camera HarmonyOS::image_receiver
                                             HarmonyOS::native_buffer)

install_obs_data(harmony-camera data "obs-plugins/harmony-camera")

set_target_properties_obs(harmony-camera PROPERTIES FOLDER plugins PREFIX "")
