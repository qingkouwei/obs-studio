// remotecam_wire.h — RCTM frame header constants shared by the bridge-side
// sender (phone wireless-camera role) and mirrors
// plugins/harmony-remotecam/remotecam-protocol.h. Kept as a tiny standalone
// header so the bridge does not need the plugin directory on its include path.
// If you change one, change the other.
#pragma once

#include <stdint.h>

constexpr uint32_t kRctmMagic = 0x5243544Du;   // 'RCTM'
constexpr uint32_t kRctmFlagKey = 0x1u;
constexpr uint32_t kRctmFlagConfig = 0x2u;
constexpr uint32_t kRctmFlagAudio = 0x4u;      // payload = AAC audio AU (not video)
constexpr uint16_t kRemoteCamDefaultPort = 25890u;
