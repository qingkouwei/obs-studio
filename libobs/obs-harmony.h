/******************************************************************************
    HarmonyOS platform layer for libobs.

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

#include "obs-internal.h"
#include "obs-nix.h"
#include "util/c99defs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Hotkey state is pushed in from ArkUI rather than polled from a system-level
 * input tap. Global (out-of-app) hotkeys require
 * ohos.permission.INPUT_MONITORING, which is system_basic and needs an AGC
 * application; without it only app-scoped hotkeys are available, which is what
 * this design supports unconditionally.
 */
struct obs_hotkeys_platform {
	bool pressed[OBS_KEY_LAST_VALUE];
};

const struct obs_nix_hotkeys_vtable *obs_harmony_get_hotkeys_vtable(void);

/* The bridge-facing entry points live in their own header so that
 * out-of-tree consumers do not inherit obs-internal.h (which in turn
 * needs <caption/caption.h>). */
#include "obs-harmony-api.h"

#ifdef __cplusplus
}
#endif
