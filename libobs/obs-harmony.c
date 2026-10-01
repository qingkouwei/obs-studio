/******************************************************************************
    HarmonyOS platform layer for libobs.

    Provides the same four symbols obs.c expects from the platform layer
    (get_module_extension, add_default_module_paths, find_libobs_data_file,
    log_system_info) plus the hotkeys vtable, without X11, Wayland, D-Bus or
    libuuid — none of which exist on HarmonyOS.

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
******************************************************************************/

#include "obs-harmony.h"

#include "util/config-file.h"
#include "util/dstr.h"
#include "util/platform.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysinfo.h>
#include <sys/utsname.h>
#include <unistd.h>

const char *get_module_extension(void)
{
	return ".so";
}

/* Two distinct roots, because HarmonyOS splits read-only code from writable
 * data across different sandboxes:
 *   code — the bundle's libs/{abi}/ directory, where every plugin .so lives.
 *   data — a writable directory ArkTS populates by extracting the HAP's rawfile
 *          assets. rawfile is not addressable as a filesystem path, and libobs
 *          resolves data files with access(), so extraction is mandatory: the
 *          .effect shaders under data/libobs/ are loaded during
 *          obs_reset_video() and without them nothing renders.
 */
static struct dstr g_code_root = {0};
static struct dstr g_data_root = {0};

void obs_harmony_set_paths(const char *code_dir, const char *data_dir)
{
	if (code_dir && *code_dir) {
		dstr_free(&g_code_root);
		dstr_init_copy(&g_code_root, code_dir);
	}

	if (data_dir && *data_dir) {
		dstr_free(&g_data_root);
		dstr_init_copy(&g_data_root, data_dir);
	}
}

static const char *harmony_code_root(void)
{
	const char *env;

	if (g_code_root.array && g_code_root.len)
		return g_code_root.array;

	env = getenv("OBS_HARMONY_CODE_DIR");
	if (env && *env)
		return env;

	return "/data/app/el1/bundle/public/com.obsproject.studio.harmony/libs/arm64-v8a";
}

static const char *harmony_data_root(void)
{
	const char *env;

	if (g_data_root.array && g_data_root.len)
		return g_data_root.array;

	env = getenv("OBS_HARMONY_DATA_DIR");
	if (env && *env)
		return env;

	return "/data/app/el1/bundle/public/com.obsproject.studio.harmony/resources/rawfile";
}

void add_default_module_paths(void)
{
	struct dstr bin_path = {0};
	struct dstr data_path = {0};

	dstr_init_copy(&bin_path, harmony_code_root());

	dstr_init_copy(&data_path, harmony_data_root());
	dstr_cat(&data_path, "/obs-plugins/%module%");

	obs_add_module_path(bin_path.array, data_path.array);

	dstr_free(&bin_path);
	dstr_free(&data_path);
}

char *find_libobs_data_file(const char *file)
{
	struct dstr output = {0};
	struct dstr dir = {0};

	dstr_init_copy(&dir, harmony_data_root());
	dstr_cat(&dir, "/libobs/");

	if (check_path(file, dir.array, &output)) {
		dstr_free(&dir);
		return output.array;
	}

	dstr_free(&dir);
	dstr_free(&output);
	return NULL;
}

static void log_processor_cores(void)
{
	long cores = sysconf(_SC_NPROCESSORS_ONLN);

	if (cores > 0)
		blog(LOG_INFO, "Processor Cores: %ld", cores);
}

static void log_memory_info(void)
{
	struct sysinfo info;

	if (sysinfo(&info) < 0)
		return;

	blog(LOG_INFO, "Physical Memory: %" PRIu64 "MB Total, %" PRIu64 "MB Free",
	     (uint64_t)info.totalram * info.mem_unit / 1024 / 1024,
	     ((uint64_t)info.freeram + (uint64_t)info.bufferram) * info.mem_unit / 1024 / 1024);
}

static void log_kernel_version(void)
{
	struct utsname info;

	if (uname(&info) < 0)
		return;

	blog(LOG_INFO, "Kernel Version: %s %s", info.sysname, info.release);
}

static void log_harmony_version(void)
{
	blog(LOG_INFO, "Operating System: HarmonyOS (OHOS_FAMILY, musl libc, API %d)", __OHOS_Major__);
}

void log_system_info(void)
{
	log_harmony_version();
	log_processor_cores();
	log_memory_info();
	log_kernel_version();
}

/* ------------------------------------------------------------------------- */
/* Hotkeys                                                                   */
/* ------------------------------------------------------------------------- */

static struct obs_hotkeys_platform *g_hotkeys = NULL;

void obs_harmony_set_key_state(obs_key_t key, bool pressed)
{
	if (!g_hotkeys || key < 0 || key >= OBS_KEY_LAST_VALUE)
		return;

	g_hotkeys->pressed[key] = pressed;
}

static bool harmony_hotkeys_init(struct obs_core_hotkeys *hotkeys)
{
	hotkeys->platform_context = bzalloc(sizeof(obs_hotkeys_platform_t));
	g_hotkeys = hotkeys->platform_context;

	return true;
}

static void harmony_hotkeys_free(struct obs_core_hotkeys *hotkeys)
{
	if (!hotkeys->platform_context)
		return;

	g_hotkeys = NULL;
	bfree(hotkeys->platform_context);
	hotkeys->platform_context = NULL;
}

static bool harmony_hotkeys_is_pressed(obs_hotkeys_platform_t *context, obs_key_t key)
{
	if (!context || key < 0 || key >= OBS_KEY_LAST_VALUE)
		return false;

	return context->pressed[key];
}

static const char *harmony_key_names[] = {
	[OBS_KEY_RETURN] = "Return",
	[OBS_KEY_ESCAPE] = "Escape",
	[OBS_KEY_TAB] = "Tab",
	[OBS_KEY_BACKSPACE] = "Backspace",
	[OBS_KEY_INSERT] = "Insert",
	[OBS_KEY_DELETE] = "Delete",
	[OBS_KEY_PAUSE] = "Pause",
	[OBS_KEY_PRINT] = "Print",
	[OBS_KEY_HOME] = "Home",
	[OBS_KEY_END] = "End",
	[OBS_KEY_LEFT] = "Left",
	[OBS_KEY_UP] = "Up",
	[OBS_KEY_RIGHT] = "Right",
	[OBS_KEY_DOWN] = "Down",
	[OBS_KEY_PAGEUP] = "Page Up",
	[OBS_KEY_PAGEDOWN] = "Page Down",
	[OBS_KEY_SHIFT] = "Shift",
	[OBS_KEY_CONTROL] = "Control",
	[OBS_KEY_META] = "Meta",
	[OBS_KEY_ALT] = "Alt",
	[OBS_KEY_ALTGR] = "AltGr",
	[OBS_KEY_CAPSLOCK] = "Caps Lock",
	[OBS_KEY_NUMLOCK] = "Num Lock",
	[OBS_KEY_SCROLLLOCK] = "Scroll Lock",
	[OBS_KEY_SPACE] = "Space",
};

static void harmony_key_to_str(obs_key_t key, struct dstr *dstr)
{
	if (key >= 0 && key < (obs_key_t)(sizeof(harmony_key_names) / sizeof(harmony_key_names[0])) &&
	    harmony_key_names[key]) {
		dstr_copy(dstr, harmony_key_names[key]);
		return;
	}

	if (key >= OBS_KEY_A && key <= OBS_KEY_Z) {
		dstr_printf(dstr, "%c", (char)('A' + (key - OBS_KEY_A)));
		return;
	}

	if (key >= OBS_KEY_0 && key <= OBS_KEY_9) {
		dstr_printf(dstr, "%c", (char)('0' + (key - OBS_KEY_0)));
		return;
	}

	if (key >= OBS_KEY_F1 && key <= OBS_KEY_F35) {
		dstr_printf(dstr, "F%d", (int)(key - OBS_KEY_F1) + 1);
		return;
	}

	if (key >= OBS_KEY_MOUSE1 && key <= OBS_KEY_MOUSE29) {
		dstr_printf(dstr, "Mouse %d", (int)(key - OBS_KEY_MOUSE1) + 1);
		return;
	}

	dstr_printf(dstr, "0x%04X", (unsigned int)key);
}

static obs_key_t harmony_key_from_virtual_key(int sym)
{
	return (obs_key_t)sym;
}

static int harmony_key_to_virtual_key(obs_key_t key)
{
	return (int)key;
}

static const struct obs_nix_hotkeys_vtable harmony_hotkeys_vtable = {
	.init = harmony_hotkeys_init,
	.free = harmony_hotkeys_free,
	.is_pressed = harmony_hotkeys_is_pressed,
	.key_to_str = harmony_key_to_str,
	.key_from_virtual_key = harmony_key_from_virtual_key,
	.key_to_virtual_key = harmony_key_to_virtual_key,
};

const struct obs_nix_hotkeys_vtable *obs_harmony_get_hotkeys_vtable(void)
{
	return &harmony_hotkeys_vtable;
}

/* The nix hotkey dispatch layer lives in obs-nix.c and routes through a
 * vtable selected by obs_get_nix_platform(). HarmonyOS has only one winsys and
 * one input model, so bind it directly here.
 */
static const struct obs_nix_hotkeys_vtable *hotkeys_vtable = NULL;

bool obs_hotkeys_platform_init(struct obs_core_hotkeys *hotkeys)
{
	hotkeys_vtable = obs_harmony_get_hotkeys_vtable();

	return hotkeys_vtable->init(hotkeys);
}

void obs_hotkeys_platform_free(struct obs_core_hotkeys *hotkeys)
{
	if (!hotkeys_vtable)
		return;

	hotkeys_vtable->free(hotkeys);
	hotkeys_vtable = NULL;
}

bool obs_hotkeys_platform_is_pressed(obs_hotkeys_platform_t *context, obs_key_t key)
{
	return hotkeys_vtable->is_pressed(context, key);
}

void obs_key_to_str(obs_key_t key, struct dstr *dstr)
{
	return hotkeys_vtable->key_to_str(key, dstr);
}

obs_key_t obs_key_from_virtual_key(int sym)
{
	return hotkeys_vtable->key_from_virtual_key(sym);
}

int obs_key_to_virtual_key(obs_key_t key)
{
	return hotkeys_vtable->key_to_virtual_key(key);
}
