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

    HarmonyOS browser (ArkWeb) source.

    ArkWeb is an ArkTS-only API: the only way to rasterise a page and read its
    pixels back on HarmonyOS is the ets `Web` component + componentSnapshot,
    which lives on the UI thread, far from libobs' graphics thread. So the
    work is split:

        ArkTS  : owns an off-screen Web component, polls componentSnapshot
                 into an RGBA ArrayBuffer, hands the bytes across the napi
                 bridge (nativeWebSourceFeed).
        bridge : links libobs, resolves scene item -> obs_source_t, calls
                 obs_source_output_video() with an RGBA frame — the same
                 async-source path harmony-remotecam proved survives being
                 driven from a non-graphics thread (there: the codec callback;
                 here: the ArkTS napi thread).
        plugin : THIS file. Registers the async-video source type so
                 obs_source_create("harmony_web_source", ...) resolves and the
                 source shows up in scenes, and stores the url/viewport so the
                 ArkTS host can (re)build its component after a scene reload.

    Kept deliberately minimal: pixels never pass through these callbacks —
    obs_source_output_video() operates on the obs_source_t directly. Width
    and height start at 0 and are learned by libobs from the first video
    frame, exactly as remotecam does before its stream-format callback.
******************************************************************************/

#include "harmony-web.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("harmony-web", "en-US")

struct harmony_web {
	obs_source_t *source;

	/* Mirrors the settings the ArkTS Web host reads back when building /
	 * reattaching its off-screen component. The snapshot feed learns
	 * nothing from these; they exist so a source survives a scene reload
	 * with its URL and viewport size intact. */
	char *url;
	uint32_t width;
	uint32_t height;
	uint32_t refresh_ms;
};

static const char *web_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("WebBrowser.Name");
}

static void web_update(void *data, obs_data_t *settings)
{
	struct harmony_web *web = data;
	if (!settings)
		return;

	const char *url = obs_data_get_string(settings, "url");
	bfree(web->url);
	web->url = bstrdup(url && *url ? url : "about:blank");

	/* A viewport of 0 means "not set yet" — keep the last known size so
	 * get_width/get_height stay stable until the first real snapshot. */
	const long long w = obs_data_get_int(settings, "width");
	const long long h = obs_data_get_int(settings, "height");
	if (w > 0)
		web->width = (uint32_t)w;
	if (h > 0)
		web->height = (uint32_t)h;

	const long long r = obs_data_get_int(settings, "refresh_ms");
	if (r >= 16)
		web->refresh_ms = (uint32_t)r;
}

static void *web_create(obs_data_t *settings, obs_source_t *source)
{
	struct harmony_web *web = bzalloc(sizeof(*web));
	web->source = source;
	web->refresh_ms = 100; /* 10 fps default; snapshot is not free */
	web->url = bstrdup("about:blank");
	web_update(web, settings);
	return web;
}

static void web_destroy(void *data)
{
	struct harmony_web *web = data;
	bfree(web->url);
	bfree(web);
}

static uint32_t web_get_width(void *data)
{
	struct harmony_web *web = data;
	return web->width;
}

static uint32_t web_get_height(void *data)
{
	struct harmony_web *web = data;
	return web->height;
}

static obs_properties_t *web_properties(void *data)
{
	UNUSED_PARAMETER(data);
	obs_properties_t *props = obs_properties_create();
	obs_properties_add_text(props, "url", obs_module_text("WebBrowser.URL"), OBS_TEXT_DEFAULT);
	obs_properties_add_int(props, "width", obs_module_text("WebBrowser.Width"), 16, 3840, 16);
	obs_properties_add_int(props, "height", obs_module_text("WebBrowser.Height"), 16, 2160, 16);
	obs_properties_add_int(props, "refresh_ms", obs_module_text("WebBrowser.Refresh"), 33, 5000, 17);
	return props;
}

static void web_get_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, "url", "https://example.com");
	obs_data_set_default_int(settings, "width", 800);
	obs_data_set_default_int(settings, "height", 600);
	obs_data_set_default_int(settings, "refresh_ms", 100);
}

/* Pure consumer: no video_render, no self-capture. Frames arrive only from
 * obs_bridge.cpp's nativeWebSourceFeed via obs_source_output_video() —
 * OBS_SOURCE_ASYNC_VIDEO is the whole contract, libobs buffers them on its
 * async thread exactly like the remote-camera source's decoded frames. */
struct obs_source_info harmony_web_source_info = {
	.id = "harmony_web_source",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_DO_NOT_DUPLICATE,
	.get_name = web_get_name,
	.create = web_create,
	.destroy = web_destroy,
	.update = web_update,
	.get_width = web_get_width,
	.get_height = web_get_height,
	.get_defaults = web_get_defaults,
	.get_properties = web_properties,
};

bool obs_module_load(void)
{
	obs_register_source(&harmony_web_source_info);

	blog(LOG_INFO, "[harmony-web] browser (ArkWeb) source registered");
	return true;
}
