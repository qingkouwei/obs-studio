/******************************************************************************
    HarmonyOS window-system backend for libobs-opengl.

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

#include <native_window/external_window.h>

#include "gl-subsystem.h"

/* HarmonyOS exposes no window handle of its own through gs_window; the
 * ArkUI layer hands us the XComponent's OHNativeWindow* via
 * gs_init_data.window.display. Keeping it there means libobs's public
 * graphics.h needs no HarmonyOS-specific struct branch.
 */
static inline OHNativeWindow *gs_window_native_window(const struct gs_window *window)
{
	return (OHNativeWindow *)window->display;
}

/* Called by the ArkUI bridge before obs_startup()/gs_create() so the very
 * first swapchain has a surface to render into.
 */
void gl_harmony_set_default_window(OHNativeWindow *window);
OHNativeWindow *gl_harmony_get_default_window(void);
