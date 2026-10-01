/******************************************************************************
Copyright (C) 2014 by Nibbles

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

/*
 * HarmonyOS font discovery for text-freetype2.
 *
 * Every other platform resolves a family name to a font file through an OS
 * service: CoreText on macOS (find-font-cocoa.m), GDI/DirectWrite on Windows
 * (find-font-windows.c), fontconfig on Linux and the BSDs (find-font-unix.c).
 * HarmonyOS offers none of those to native code — there is no fontconfig in the
 * SDK, and the ArkTS @ohos.font API is not callable from a C plugin without an
 * N-API bridge that libobs does not have.
 *
 * What HarmonyOS does have is a plain, readable directory of system fonts
 * (/system/fonts) containing .ttf/.ttc/.otf files. So this back end walks that
 * directory, opens every face with FreeType and feeds it to the shared
 * build_font_path_info()/get_font_path() machinery in find-font.c — the same
 * family-name -> file-path table, the same rating rules and the same on-disk
 * font_data.bin cache the plugin already uses on Windows and macOS. This file
 * supplies only the three back-end hooks find-font.c expects:
 * load_os_font_list(), sfnt_name_to_utf8() and get_font_checksum().
 *
 * Why not cross-compile fontconfig instead
 * ---------------------------------------
 * fontconfig would additionally require expat, a fonts.conf shipped in the HAP,
 * a writable cache directory inside the app sandbox, and a configure run that
 * survives musl feature probing — and its only job here is answering "which file
 * is family X" for a fixed, small (~30 file) set of system fonts that never
 * changes while OBS runs. A directory scan answers that with one dependency
 * (FreeType, which the plugin needs anyway) instead of four, and it also means
 * the plugin keeps working when the app is sandboxed away from fontconfig's
 * usual /etc/fonts. The one thing fontconfig would genuinely add — generic
 * family aliasing and substitution rules — is reproduced below by
 * register_generic_families(), which is all this plugin ever asked it for.
 *
 * Note that __linux__ is defined on HarmonyOS alongside __OHOS__, but nothing in
 * this plugin selects its font back end with the preprocessor: the choice is made
 * by $<PLATFORM_ID:...> in CMakeLists.txt, and the OHOS toolchain sets
 * CMAKE_SYSTEM_NAME=OHOS, so find-font-unix.c is never compiled here and no
 * fontconfig header is ever included.
 */

#include <string.h>
#include <sys/stat.h>

#include <util/base.h>
#include <util/crc32.h>
#include <util/darray.h>
#include <util/dstr.h>
#include <util/platform.h>

#include "find-font.h"
#include "text-freetype2.h"

extern void save_font_list(void);

/* The shared family-name -> path table lives in find-font.c. The Windows and
 * macOS back ends only ever append to it indirectly through
 * build_font_path_info(); this back end also appends aliases, so it refers to
 * the array directly. */
extern DARRAY(struct font_path_info) font_list;

/* HarmonyOS system font locations, most authoritative first. os_opendir()
 * returns NULL for any that do not exist on a given device or build, so probing
 * extra candidates costs nothing. /data/service/el1/public/fonts is where
 * enterprise-provisioned fonts land on HarmonyOS NEXT. */
static const char *const ohos_font_dirs[] = {
	"/system/fonts",
	"/system/font",
	"/data/service/el1/public/fonts",
};
static const size_t ohos_font_dir_count = sizeof(ohos_font_dirs) / sizeof(ohos_font_dirs[0]);

/* /system/fonts is flat in practice. The cap exists purely so that a symlink
 * loop or a pathological mount cannot recurse without bound. */
#define OHOS_FONT_SCAN_MAX_DEPTH 8

/* The family name HarmonyOS gives its own UI typeface, and the prefix used to
 * spot it among the faces the scan turned up. */
#define OHOS_PRIMARY_FAMILY "HarmonyOS Sans"

/* Generic family names that must resolve for the plugin to be usable at all.
 *
 * DEFAULT_FACE in text-freetype2.c falls through to "Sans Serif" on every
 * platform that is neither Windows nor macOS, HarmonyOS included, and no font on
 * the device is actually named that — without an alias a freshly added text
 * source would load no face and render nothing. "sans-serif" is the generic
 * family fontconfig resolves, i.e. what find-font-unix.c would have answered, so
 * aliasing it keeps scenes authored on a Linux host working. */
static const char *const ohos_generic_families[] = {
	"Sans Serif",
	"sans-serif",
	OHOS_PRIMARY_FAMILY,
};
static const size_t ohos_generic_family_count =
	sizeof(ohos_generic_families) / sizeof(ohos_generic_families[0]);

/* --------------------------------------------------------------------------
 * SFNT name decoding
 *
 * FreeType hands back the raw bytes of a name record. Windows decodes them with
 * MultiByteToWideChar and macOS with iconv; OHOS has neither, and musl's iconv
 * is not guaranteed to know the Mac code pages. Only two encodings actually
 * occur in the TT_NAME_ID_FONT_FAMILY records this plugin reads:
 *
 *   UTF-16BE — every Unicode-platform record: Apple Unicode (platform 0),
 *              ISO 10646 (platform 2, encoding 1) and Microsoft (platform 3)
 *              with encoding TT_MS_ID_UNICODE_CS or TT_MS_ID_UCS_4.
 *   8-bit    — Mac Roman (platform 1, encoding 0) and ISO 8859-1 (platform 2,
 *              encoding 2).
 *
 * The 8-bit branch is decoded as Latin-1. That is exact for the ASCII that
 * family names are overwhelmingly made of and for Western European accents; Mac
 * Roman differs from Latin-1 only in 0x80..0xA0, and a face using those also
 * carries a UTF-16BE Microsoft record that is decoded exactly, with
 * build_font_path_info() de-duplicating the two results. Anything else returns
 * NULL and the caller keeps face->family_name, which FreeType fills from the
 * preferred record.
 * -------------------------------------------------------------------------- */

/* Same bound find-font-iconv.c uses for a converted family name. */
#define OHOS_NAME_MAX_UTF8 256

static bool name_is_utf16be(const FT_SfntName *name)
{
	switch (name->platform_id) {
	case TT_PLATFORM_APPLE_UNICODE:
		return true;
	case TT_PLATFORM_ISO:
		return name->encoding_id == TT_ISO_ID_10646;
	case TT_PLATFORM_MICROSOFT:
		return name->encoding_id == TT_MS_ID_UNICODE_CS || name->encoding_id == TT_MS_ID_UCS_4;
	default:
		return false;
	}
}

static bool name_is_8bit_latin(const FT_SfntName *name)
{
	switch (name->platform_id) {
	case TT_PLATFORM_MACINTOSH:
		return name->encoding_id == TT_MAC_ID_ROMAN;
	case TT_PLATFORM_ISO:
		return name->encoding_id == TT_ISO_ID_8859_1 || name->encoding_id == TT_ISO_ID_7BIT_ASCII;
	default:
		return false;
	}
}

/* Appends one code point as UTF-8 at dst[len]. Returns the new length, or len
 * unchanged if the remaining space (cap, including the terminator the caller
 * writes) cannot hold it. */
static size_t utf8_put(char *dst, size_t len, size_t cap, uint32_t cp)
{
	if (cp < 0x80) {
		if (len + 1 >= cap)
			return len;
		dst[len++] = (char)cp;
	} else if (cp < 0x800) {
		if (len + 2 >= cap)
			return len;
		dst[len++] = (char)(0xC0 | (cp >> 6));
		dst[len++] = (char)(0x80 | (cp & 0x3F));
	} else if (cp < 0x10000) {
		if (len + 3 >= cap)
			return len;
		dst[len++] = (char)(0xE0 | (cp >> 12));
		dst[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
		dst[len++] = (char)(0x80 | (cp & 0x3F));
	} else {
		if (len + 4 >= cap)
			return len;
		dst[len++] = (char)(0xF0 | (cp >> 18));
		dst[len++] = (char)(0x80 | ((cp >> 12) & 0x3F));
		dst[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
		dst[len++] = (char)(0x80 | (cp & 0x3F));
	}

	return len;
}

static char *utf16be_to_utf8(const FT_Byte *src, FT_UInt len)
{
	char out[OHOS_NAME_MAX_UTF8];
	size_t n = 0;
	FT_UInt i = 0;

	while (i + 1 < len) {
		uint32_t cp = ((uint32_t)src[i] << 8) | (uint32_t)src[i + 1];
		i += 2;

		/* Surrogate pair. A lead surrogate without a valid trail is
		 * emitted as-is, matching what iconv does with //IGNORE off. */
		if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len) {
			uint32_t lo = ((uint32_t)src[i] << 8) | (uint32_t)src[i + 1];

			if (lo >= 0xDC00 && lo <= 0xDFFF) {
				cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
				i += 2;
			}
		}

		n = utf8_put(out, n, sizeof(out), cp);
	}

	out[n] = 0;
	return bstrdup(out);
}

static char *latin_to_utf8(const FT_Byte *src, FT_UInt len)
{
	char out[OHOS_NAME_MAX_UTF8];
	size_t n = 0;

	for (FT_UInt i = 0; i < len; i++)
		n = utf8_put(out, n, sizeof(out), (uint32_t)src[i]);

	out[n] = 0;
	return bstrdup(out);
}

char *sfnt_name_to_utf8(FT_SfntName *sfnt_name)
{
	if (name_is_utf16be(sfnt_name))
		return utf16be_to_utf8(sfnt_name->string, sfnt_name->string_len);

	if (name_is_8bit_latin(sfnt_name))
		return latin_to_utf8(sfnt_name->string, sfnt_name->string_len);

	blog(LOG_DEBUG,
	     "FT2-text: unsupported name encoding, platform_id: %d, "
	     "encoding_id: %d, language_id: %d",
	     (int)sfnt_name->platform_id, (int)sfnt_name->encoding_id, (int)sfnt_name->language_id);
	return NULL;
}

/* --------------------------------------------------------------------------
 * Directory scan
 * -------------------------------------------------------------------------- */

static bool is_dot_entry(const char *name)
{
	if (name[0] != '.')
		return false;

	return name[1] == 0 || (name[1] == '.' && name[2] == 0);
}

static void add_path_font(const char *path)
{
	FT_Face face;
	FT_Long idx = 0;
	FT_Long max_faces = 1;

	/* A .ttc collection holds several faces; walk every index in it. */
	while (idx < max_faces) {
		if (FT_New_Face(ft2_lib, path, idx, &face) != 0)
			break;

		build_font_path_info(face, idx++, path);
		max_faces = face->num_faces;
		FT_Done_Face(face);
	}
}

static void add_path_fonts(const char *dir, int depth)
{
	os_dir_t *d;
	struct os_dirent *ent;

	if (depth > OHOS_FONT_SCAN_MAX_DEPTH)
		return;

	d = os_opendir(dir);
	if (!d)
		return;

	while ((ent = os_readdir(d)) != NULL) {
		struct dstr full = {0};

		/* libobs' POSIX os_readdir() does not filter "." and "..", so
		 * without this the walk would recurse into itself. */
		if (is_dot_entry(ent->d_name))
			continue;

		dstr_copy(&full, dir);
		dstr_cat(&full, "/");
		dstr_cat(&full, ent->d_name);

		if (ent->directory)
			add_path_fonts(full.array, depth + 1);
		else
			add_path_font(full.array);

		dstr_free(&full);
	}

	os_closedir(d);
}

/* --------------------------------------------------------------------------
 * Generic family aliases
 * -------------------------------------------------------------------------- */

static bool family_already_listed(const char *family)
{
	const size_t fam_len = strlen(family);

	for (size_t i = 0; i < font_list.num; i++) {
		const struct font_path_info *info = &font_list.array[i];

		if (info->face_len == fam_len && astrcmpi_n(info->face_and_style, family, fam_len) == 0)
			return true;
	}

	return false;
}

static void register_generic_families(void)
{
	const size_t prefix_len = strlen(OHOS_PRIMARY_FAMILY);
	const struct font_path_info *primary;
	char *path;
	FT_Long index;
	bool bold;
	bool italic;
	size_t pick = 0;

	if (font_list.num == 0)
		return;

	/* Prefer the genuine HarmonyOS UI face; otherwise take the first face the
	 * scan managed to open, which beats rendering nothing. */
	for (size_t i = 0; i < font_list.num; i++) {
		const struct font_path_info *info = &font_list.array[i];

		if (info->face_len >= prefix_len && astrcmpi_n(info->face_and_style, OHOS_PRIMARY_FAMILY, prefix_len) == 0) {
			pick = i;
			break;
		}
	}

	/* Snapshot the fields by value before pushing: da_push_back() may
	 * reallocate font_list.array and invalidate `primary`. The path string
	 * itself is heap-allocated by add_font_path() and survives the realloc. */
	primary = &font_list.array[pick];
	path = primary->path;
	index = primary->index;
	bold = primary->bold;
	italic = primary->italic;

	for (size_t i = 0; i < ohos_generic_family_count; i++) {
		const char *family = ohos_generic_families[i];
		struct font_path_info alias;

		if (family_already_listed(family))
			continue;

		memset(&alias, 0, sizeof(alias));
		alias.face_and_style = bstrdup(family);
		alias.face_len = (uint32_t)strlen(family);
		alias.full_len = alias.face_len;
		/* Deliberately not a bitmap face: an alias carries no
		 * available_sizes list, so claiming otherwise would make
		 * get_font_path() rate it against an empty size table. */
		alias.is_bitmap = false;
		alias.num_sizes = 0;
		alias.sizes = NULL;
		alias.bold = bold;
		alias.italic = italic;
		alias.path = bstrdup(path);
		alias.index = index;

		da_push_back(font_list, &alias);
	}
}

void load_os_font_list(void)
{
	for (size_t i = 0; i < ohos_font_dir_count; i++)
		add_path_fonts(ohos_font_dirs[i], 0);

	if (font_list.num == 0) {
		blog(LOG_WARNING,
		     "FT2-text: no fonts found in /system/fonts, /system/font or "
		     "/data/service/el1/public/fonts; text sources cannot render");
		return;
	}

	register_generic_families();

	blog(LOG_INFO, "FT2-text: enumerated %zu HarmonyOS system font faces", (size_t)font_list.num);

	save_font_list();
}

/* --------------------------------------------------------------------------
 * Cache invalidation
 *
 * find-font.c stamps font_data.bin with get_font_checksum() and re-scans when
 * the value changes, so a device update that swaps a system font cannot leave a
 * stale path behind. Mirrors find-font-cocoa.m: crc32 over each entry's path,
 * plus its mtime so an in-place replacement is caught too.
 * -------------------------------------------------------------------------- */

static uint32_t add_dir_checksum(uint32_t checksum, const char *dir, int depth)
{
	os_dir_t *d;
	struct os_dirent *ent;

	if (depth > OHOS_FONT_SCAN_MAX_DEPTH)
		return checksum;

	d = os_opendir(dir);
	if (!d)
		return checksum;

	while ((ent = os_readdir(d)) != NULL) {
		struct dstr full = {0};
		struct stat st;

		if (is_dot_entry(ent->d_name))
			continue;

		dstr_copy(&full, dir);
		dstr_cat(&full, "/");
		dstr_cat(&full, ent->d_name);

		if (ent->directory) {
			checksum = add_dir_checksum(checksum, full.array, depth + 1);
		} else {
			checksum = calc_crc32(checksum, full.array, full.len);

			if (os_stat(full.array, &st) == 0)
				checksum = calc_crc32(checksum, &st.st_mtime, sizeof(st.st_mtime));
		}

		dstr_free(&full);
	}

	os_closedir(d);
	return checksum;
}

uint32_t get_font_checksum(void)
{
	uint32_t checksum = 0;

	for (size_t i = 0; i < ohos_font_dir_count; i++)
		checksum = add_dir_checksum(checksum, ohos_font_dirs[i], 0);

	return checksum;
}
