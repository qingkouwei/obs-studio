/******************************************************************************
    Public HarmonyOS integration surface of libobs.

    Kept separate from obs-harmony.h on purpose: that header pulls in
    obs-internal.h (it needs struct obs_core_hotkeys and the hotkeys vtable),
    which would drag libobs's entire internal header set — including
    <caption/caption.h> — into every out-of-tree consumer. The NAPI bridge only
    needs the two entry points below.

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

#pragma once

#include <stdbool.h>

#include "obs-hotkey.h"
#include "util/c99defs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Tells libobs where the HAP put things. MUST be called before obs_startup(),
 * because obs_startup() runs add_default_module_paths() and the graphics
 * subsystem loads libobs's .effect shaders through find_libobs_data_file()
 * during obs_reset_video(). Injecting the roots afterwards is too late.
 *
 *   code_dir — bundle native library directory (ArkTS
 *              context.bundleCodeDir + "/libs/arm64-v8a"). Holds every plugin
 *              .so and is what libobs dlopens. Read-only.
 *   data_dir — writable directory ArkTS has already populated by extracting the
 *              HAP's rawfile tree. Expected layout:
 *                data_dir/libobs/ (effect shaders)
 *                data_dir/obs-plugins/<module>/locale/ (ini files)
 *              rawfile has no filesystem path inside a HAP, so this extraction
 *              is mandatory rather than an optimisation.
 *
 * Passing NULL for either keeps the previously set value; with neither set,
 * libobs falls back to OBS_HARMONY_CODE_DIR / OBS_HARMONY_DATA_DIR and then to
 * the documented sandbox defaults.
 */
EXPORT void obs_harmony_set_paths(const char *code_dir, const char *data_dir);

/* Feeds key state in from ArkUI. Global (out-of-app) hotkeys would need
 * ohos.permission.INPUT_MONITORING, which is system_basic and requires an AGC
 * application; app-scoped hotkeys work unconditionally through this path.
 */
EXPORT void obs_harmony_set_key_state(obs_key_t key, bool pressed);

#ifdef __cplusplus
}
#endif
