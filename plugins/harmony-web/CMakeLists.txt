cmake_minimum_required(VERSION 3.28...3.30)

add_library(harmony-web MODULE)
add_library(OBS::harmony-web ALIAS harmony-web)

target_sources(harmony-web PRIVATE harmony-web.c harmony-web.h)

# Pure registration: no capture, no codec, no sockets — libobs only. The
# pixel feed lives in libobs_bridge.so (nativeWebSourceFeed), and the Web
# component itself is ArkTS (ArkWeb is not exposed to the native SDK).
target_link_libraries(harmony-web PRIVATE OBS::libobs)

install_obs_data(harmony-web data "obs-plugins/harmony-web")

set_target_properties_obs(harmony-web PROPERTIES FOLDER plugins PREFIX "")
