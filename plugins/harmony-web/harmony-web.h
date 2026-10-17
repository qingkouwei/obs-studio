/******************************************************************************
    Copyright (C) 2026 by OBS Studio contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

    HarmonyOS browser (ArkWeb) source — the libobs half of "a web page as an
    OBS input".

    ArkWeb is an ArkTS-only API: the only way to rasterise a page and read its
    pixels back on HarmonyOS is the ets `Web` component + componentSnapshot,
    which lives on the UI thread, far away from libobs' graphics thread. So
    the split is:

        ArkTS  : owns the off-screen Web component, polls componentSnapshot
                 into an RGBA ArrayBuffer, hands the bytes across the napi
                 bridge (nativeWebSourceFeed).
        bridge : links libobs, resolves the scene item -> obs_source_t, and
                 calls obs_source_output_video() with an RGBA frame — the very
                 async-source path harmony-remotecam already proved survives
                 being driven from a non-graphics thread (there, the codec
                 callback thread; here, the ArkTS napi thread).
        plugin : this file. It only needs to REGISTER an async-video source
                 type so `obs_source_create("harmony_web_source", ...)`
                 succeeds and the source appears in the scene. All the pixel
                 traffic bypasses it — obs_source_output_video() operates on
                 the obs_source_t directly, never on info.context.data.

    Kept deliberately minimal: create/destroy a tiny struct (libobs requires a
    non-NULL context.data for the source to be valid), expose "url" and
    "refresh_ms" settings for the ArkTS layer and re-add persistence, and
    declare the async-video capability. Width/height default to 0 until the
    first frame arrives, at which point libobs learns the real geometry from
    the video frame (same as remotecam before its stream format callback).
******************************************************************************/

#pragma once

#include <obs-module.h>

extern struct obs_source_info harmony_web_source_info;
