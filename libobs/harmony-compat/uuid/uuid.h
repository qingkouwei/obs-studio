/* libuuid shim for HarmonyOS.
 *
 * libobs/util/platform-nix.c calls uuid_generate()/uuid_unparse_lower() from
 * <uuid/uuid.h>. HarmonyOS uses musl and ships no libuuid, and there is no
 * UUID generator in the NDK. platform-nix.c is otherwise correct for OHOS
 * (musl provides sysinfo, statvfs, glob, spawn and friends), so rather than
 * fork it we supply the two functions here.
 *
 * This directory is placed ahead of the system include path for HarmonyOS
 * builds only; no other platform sees it.
 *
 * OBS uses the generated value purely as an opaque per-installation identity,
 * so a random version-4 UUID is the correct substitute for libuuid's
 * time-and-MAC-address variant.
 */

#pragma once

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef unsigned char uuid_t[16];

static inline void uuid_generate(uuid_t out)
{
	FILE *urandom = fopen("/dev/urandom", "rb");

	if (urandom) {
		size_t read_bytes = fread(out, 1, sizeof(uuid_t), urandom);
		fclose(urandom);

		if (read_bytes == sizeof(uuid_t)) {
			/* RFC 4122 version 4 */
			out[6] = (unsigned char)((out[6] & 0x0f) | 0x40);
			out[8] = (unsigned char)((out[8] & 0x3f) | 0x80);
			return;
		}
	}

	/* Fall back to the libc PRNG if /dev/urandom is unavailable inside the
	 * application sandbox. Identity collisions here are tolerable because
	 * the value is only used to distinguish concurrent OBS instances.
	 */
	for (size_t i = 0; i < sizeof(uuid_t); i++)
		out[i] = (unsigned char)(rand() & 0xff);

	out[6] = (unsigned char)((out[6] & 0x0f) | 0x40);
	out[8] = (unsigned char)((out[8] & 0x3f) | 0x80);
}

/* Writes exactly 36 characters plus a NUL terminator, matching libuuid's
 * contract; callers allocate 37 bytes.
 */
static inline void uuid_unparse_lower(const uuid_t uu, char *out)
{
	static const char hex[] = "0123456789abcdef";
	size_t pos = 0;

	for (size_t i = 0; i < sizeof(uuid_t); i++) {
		/* Hyphens after bytes 3, 5, 7 and 9 */
		if (i == 4 || i == 6 || i == 8 || i == 10)
			out[pos++] = '-';

		out[pos++] = hex[(uu[i] >> 4) & 0x0f];
		out[pos++] = hex[uu[i] & 0x0f];
	}

	out[pos] = '\0';
}

static inline void uuid_unparse_upper(const uuid_t uu, char *out)
{
	static const char hex[] = "0123456789ABCDEF";
	size_t pos = 0;

	for (size_t i = 0; i < sizeof(uuid_t); i++) {
		if (i == 4 || i == 6 || i == 8 || i == 10)
			out[pos++] = '-';

		out[pos++] = hex[(uu[i] >> 4) & 0x0f];
		out[pos++] = hex[uu[i] & 0x0f];
	}

	out[pos] = '\0';
}
