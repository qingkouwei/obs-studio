# OBS Studio → HarmonyOS PC 迁移技术方案

> 目标平台：HarmonyOS PC / 2in1，API 26 / platformVersion 26.0.0，arm64-v8a
> 代码基线：OBS Studio 32.2.2（libobs 内核 + Qt6 Widgets 前端）
> 文档状态：本方案中的**每一条技术结论都经过实测验证**，验证方法见文末「复现命令」。
> **接手或新开会话时先读同目录的 `harmonyos-session-log.md`**（当前状态、决策理由、已验证事实、待办与风险）；
> 本文件是其技术细节支撑，不必通读。

---

## 1. 结论先行

**可行，且核心已经跑通。** 当前状态下，OBS Studio 的 C 内核、图形后端、以及全部平台无关插件已经能够交叉编译并链接为 HarmonyOS arm64 共享库：

```
$ ./build-aux/harmony/build-obs.sh --skip-deps   → exit 0
$ find rundir -name "*.so" | wc -l               → 14
$ ./build-aux/harmony/check-contracts.sh         → PASS 38 / FAIL 0
```

| 产物 | 大小 | 说明 |
|---|---|---|
| `libobs.so` | 1534 KB | 核心，链接自研的 FFmpeg 7.1 / jansson / speexdsp |
| `libobs-opengl.so` | 138 KB | **新写的 GLES3/EGL 后端**（原为桌面 GL 3.3） |
| `harmony-capture.so` | 34 KB | **新增**：屏幕采集 + 窗口采集 |
| `harmony-audio.so` | 32 KB | **新增**：桌面音频内录 + 麦克风 |
| `harmony-vcodec.so` | 36 KB | **新增**：AVCodec 硬件 H.264/H.265 编码 |
| `obs-outputs.so` | 1357 KB | RTMP 推流（内置 librtmp） |
| `obs-x264.so` | 1376 KB | 软件编码兜底 |
| `harmony-camera.so` | — | **新增**：摄像头源（`harmony_camera_capture`） |
| `text-freetype2.so` | — | **已恢复**：文字源，FreeType 2.13.3 静态吸收，NEEDED 仅 `libobs.so`+`libc.so` |
| `obs-ffmpeg.so` `obs-filters.so` `obs-transitions.so` `rtmp-services.so` `image-source.so` | — | 平台无关，直接复用 |

`libobs.so` 现已链接 `libohaudio.so`——**音频监听（audio monitoring）已从 null 实现换成真实的 OHAudio 渲染后端**，`obs_audio_monitoring_available` / `obs_enum_audio_monitoring_devices` 以 `T` 导出。

前端走 **ArkUI 原生重写**路线（放弃移植 85.5 kLOC 的 Qt6 Widgets），已产出**完整 HAP**：

```
harmony/entry/build/default/outputs/default/entry-default-unsigned.hap   15.65 MB
  ├─ module.json          deviceTypes: ["2in1","phone"] · extractNativeLibs: true
  ├─ ets/modules.abc      ← 已编译的 ArkTS 字节码
  ├─ resources/rawfile/obs-plugins/*/locale/en-US.ini
  └─ libs/arm64-v8a/      ← 21 个 .so
       libobs.so 1.26M · libobs-opengl.so · libobs_bridge.so
       harmony-{capture,audio,vcodec}.so
       obs-{ffmpeg,filters,outputs,transitions,x264}.so · rtmp-services.so · image-source.so
       libav{codec,format,util,filter,device}.so.* · libsw{scale,resample}.so.*
       libc++_shared.so
```

**桥接层已真正链接 libobs**（`HAVE_LIBOBS` 生效）：

```
$ llvm-readelf -d libobs_bridge.so | grep -c libobs.so   → 1        (DT_NEEDED)
$ llvm-nm -D -u libobs_bridge.so | grep -cE " (obs_|gs_)" → 57      (真实核心符号引用)
    U obs_startup  U obs_add_module_path  U obs_data_create_from_json
    U obs_audio_encoder_create  U gs_create ...
```

打包前置检查也通过了——**全部 DT_NEEDED 均可解析**（要么打进 HAP，要么设备 sysroot 自带）：

```
$ # 逐个 .so 解析 DT_NEEDED，对照 HAP libs 目录 + 设备 sysroot
  未解析的依赖数: 0   ==> 全部 DT_NEEDED 可满足 ✓
```

**尚未完成**：真机运行验证（卡在签名与锁屏，见 §8.3）、上架发布签名。

---

## 2. 架构

```
┌─────────────────────────────────────────────────────────────┐
│  ArkTS / ArkUI   harmony/entry/src/main/ets/                 │
│  pages/Index.ets · components/{PreviewCanvas,SceneList,      │
│  SourceList,AudioMixer,TransportBar} · model/ObsModel.ets    │
└──────────────────────┬──────────────────────────────────────┘
                       │ Node-API (napi)
┌──────────────────────▼──────────────────────────────────────┐
│  libobs_bridge.so   harmony/entry/src/main/cpp/               │
│  napi_init.cpp · obs_bridge.cpp · xcomponent_surface.cpp      │
└──────────────────────┬──────────────────────────────────────┘
                       │ C ABI
┌──────────────────────▼──────────────────────────────────────┐
│  libobs.so  +  libobs-opengl.so  +  plugins/*.so              │
│                                                               │
│   XComponent(SURFACE) → OHNativeWindow → EGLSurface → GLES3   │
│   AVScreenCapture     → 屏幕/窗口采集                          │
│   OH_AudioCapturer    → 内录(桌面音频) + 麦克风                │
│   OH_VideoEncoder     → 硬件编码（input surface 模式）         │
│   librtmp(内置)       → RTMP/RTMPS 推流                        │
└───────────────────────────────────────────────────────────────┘
```

选择 ArkUI 而非移植 Qt 的理由：Qt for HarmonyOS 的 QPA 插件路线在社区实测案例（Scribus、Notepad++、RStudio）中停留在 **Qt 5.12 / 5.15**，而 OBS 32.x 硬性要求 **Qt6**（`frontend/cmake/ui-qt.cmake:1` 的 `find_package(Qt6 REQUIRED Widgets Network Svg Xml)`）。降级到 Qt5 等于重写前端，不如直接原生化。

代价：85.5 kLOC 的 Widgets 界面需要重建，且永久脱离上游 OBS 代码线。

---

## 3. 能力映射（逐条对照 SDK sysroot 验证）

| OBS 子系统 | 原实现 | HarmonyOS 对应 | 状态 |
|---|---|---|---|
| 图形后端 | `libobs-opengl`，glad 加载**桌面 GL**，shader 硬编码 `#version 330` | XComponent → NativeWindow → EGL → **GLES 3.2** | ✅ 已实现 |
| 屏幕采集 | `win-capture`(DXGI) / `mac-capture` / `linux-pipewire` | `OH_AVScreenCapture_*`（API 10+） | ✅ 已实现 |
| 窗口采集 | 同上 | AVScreenCapture 指定窗口 | ⚠️ 见 §7 限制 |
| 桌面音频 | wasapi / coreaudio / pulse | `OH_AudioStreamBuilder_SetPlaybackCaptureMode` + `RequestPlaybackCaptureStart`（**API 26 起**） | ✅ 已实现 |
| 麦克风 | 同上 | `OH_AudioCapturer` + `ohos.permission.MICROPHONE` | ✅ 已实现 |
| 硬件编码 | NVENC / QSV / VideoToolbox | `OH_VideoEncoder_*`，input-surface 模式 | ✅ 已实现 |
| 软件编码 | obs-x264 | 交叉编译 x264（**arm64 汇编启用，未降级**） | ✅ 已构建 |
| RTMP 推流 | librtmp | **已内置** `plugins/obs-outputs/librtmp`，纯 C over socket | ✅ 白捡 |
| RTMPS/TLS | mbedTLS | 交叉编译 mbedTLS 3.6.2，curl 已验证引用 71 个 `mbedtls_*` 符号 | ✅ 已构建 |
| 音频滤镜 | obs-filters | 复用 + 交叉编译 speexdsp（降噪） | ✅ 已构建 |
| 浏览器面板 | CEF | CEF for OpenHarmony 已开源，本期关闭 | ⛔ 未启用 |
| 字幕 | libcaption | 复用（修了一处 musl 兼容） | ✅ 已构建 |

---

## 4. 九个关键技术发现

这些是实际踩坑得到的，不是文档里能查到的。每一条都直接决定了实现方式。

### 4.1 `__linux__` 在鸿蒙上为真 —— ifdef 是「优先级问题」而非「缺分支」

```
$ echo | clang --target=aarch64-linux-ohos --sysroot=$SDK/sysroot -dM -E - | grep -E "__linux__|__OHOS|__GLIBC__"
#define __OHOS_FAMILY__ 1
#define __OHOS__ 1
#define __linux__ 1
#define __unix__ 1
```

`__linux__` **被定义**，`__GLIBC__` **不被定义**（musl）。后果是双面的：

- 好处：大量 `#ifdef __linux__` 的 POSIX 代码路径自动生效。
- 危险：**否定式平台判断会误伤**。`obs-ffmpeg.c` 原本写：

  ```c
  #if !defined(_WIN32) && !defined(__APPLE__)   // 意图是"Linux 有 VAAPI"
  #include "vaapi-utils.h"                      // → 拉进 <va/va.h>，鸿蒙没有
  ```

  鸿蒙两者都不是，于是错误启用 VAAPI。已改为显式排除 `__OHOS__`。

**迁移准则**：全树约 762 处平台 ifdef（扣除 vendored 的 w32-pthreads / glad 后约 300–350 处真实改动点），凡是否定式判断（`!defined(_WIN32) && !defined(__APPLE__)`）都必须复查，`__OHOS__` 分支要排在 `__linux__` 之前。

### 4.2 glad 只为桌面 GL 生成，GLES 需要 shim 而非重新生成

`deps/glad` 生成的是桌面 GL（`gladLoadGL()`、`GLAD_GL_VERSION_3_3`），而鸿蒙只有 GLES + Vulkan。

穷举比对结果：**libobs-opengl 用到 177 个 `GL_*` 符号，鸿蒙 GLES 头文件缺 11 个**。

```
GL_BGRA  GL_FRAMEBUFFER_SRGB  GL_GPU_MEMORY_INFO_DEDICATED_VIDMEM_NVX
GL_GPU_MEMORY_INFO_TOTAL_AVAILABLE_MEMORY_NVX  GL_MIRROR_CLAMP_EXT
GL_R16  GL_RG16  GL_RGBA16  GL_TEXTURE_CUBE_MAP_SEAMLESS
GL_TEXTURE_RECTANGLE  GL_TIMESTAMP
```

其中 5 个有等价扩展，用别名映射（不写魔数，避免漂移）：

```c
#define GL_BGRA     GL_BGRA_EXT                    // GL_EXT_texture_format_BGRA8888
#define GL_R16      GL_R16_EXT                     // GL_EXT_texture_norm16
#define GL_RG16     GL_RG16_EXT
#define GL_RGBA16   GL_RGBA16_EXT
#define GL_MIRROR_CLAMP_EXT GL_MIRROR_CLAMP_TO_EDGE_EXT
```

其余 6 个无等价物，定义常量保证可编译，并在调用点用 `#ifdef __OHOS__` 编译排除（cube map seamless、sRGB framebuffer）。

另有两处**函数级**缺口：

- **`glMapBuffer` 在 GLES3 中被移除**（改用需显式区间的 `glMapBufferRange`）。shim 内实现等价语义：

  ```c
  static inline void *glad_glMapBuffer(GLenum target, GLenum access) {
      GLint size = 0;
      glGetBufferParameteriv(target, GL_BUFFER_SIZE, &size);
      if (size <= 0) return NULL;
      return glMapBufferRange(target, 0, (GLsizeiptr)size, flags);
  }
  ```
- **`glGetTexImage` 在 GLES 中完全不存在** —— 这是 GLES 的根本性限制，无法从纹理直接回读。解法不是补 shim，而是复用 OBS 已有的 macOS 分支（FBO + `glReadPixels`）：把 `gl-stagesurf.c` 的 `#ifdef __APPLE__` 改成 `#if defined(__APPLE__) || defined(__OHOS__)` 即可，GLES 3.0 支持 `glReadPixels` 写入已绑定的 `GL_PIXEL_PACK_BUFFER`。

shim 放在 `libobs-opengl/harmony/glad/glad.h`，通过 include 路径优先级仅在鸿蒙构建生效，**不扰动其他平台**。

### 4.3 toolchain 注入 `--gcc-toolchain=`，遇上 `-Werror` 会全量失败

```
clang: error: argument unused during compilation: '--gcc-toolchain=...'
       [-Werror,-Wunused-command-line-argument]
```

mbedTLS 默认开 `-Werror`，结果**每一个** TU 都编译失败，而表面症状极具误导性（后续报 `file INSTALL cannot find libeverest.a`，看起来像打包问题）。

解法：全局注入 `-Qunused-arguments`。已同时写入 `build-deps.sh` 的 `CFLAGS/CXXFLAGS`（覆盖 autoconf 项目）和 OBS 的 `cmake/harmony/compilerconfig.cmake`（覆盖 OBS 自身）。

### 4.4 `config.sub` 不认识 `ohos`

```
checking host system type... Invalid configuration `aarch64-linux-ohos': OS `ohos' not recognized
```

实测 curl 8.11.1 自带的 2022 版 `config.sub` 和 Homebrew automake 1.17 的**都不认识**，升级 autotools 无解。

解法：`--host` 传 gnu 三元组（`aarch64-linux-gnu`），真实目标仍由 `CC/CXX` 的 `--target=aarch64-linux-ohos --sysroot=` 强制。特性探测依然诚实，因为 autoconf 的每个 probe 都是针对 OHOS sysroot 的编译测试。

> curl 后来改用 CMake 构建（见 4.6），顺带绕开了这个问题。

### 4.5 FFmpeg 用 mbedTLS 必须显式开 `--enable-version3`

```
mbedtls is version3 and --enable-version3 is not specified.
```

FFmpeg 把 mbedTLS 3.x 归类为 (L)GPLv3 组件。**许可影响**：这会把 FFmpeg 从 LGPLv2.1 提升到 LGPLv3。OBS Studio 是 GPL-2.0-**or-later**，"or later" 授权使组合仍然合法。

### 4.6 静态 curl 必须用 CMake 构建，否则传递依赖丢失

autoconf 构建只装 `libcurl.pc`，**不装 CMake package**。OBS 的 `find_package(CURL REQUIRED)` 因此退化为 module 模式，`CURL::libcurl` 只解析到裸的 `libcurl.a`，消费方链接时爆：

```
ld.lld: error: undefined symbol: inflateInit_     ← zlib
ld.lld: error: undefined symbol: mbedtls_des_init ← mbedTLS
```

curl 的 CMake 构建会执行 `install(EXPORT CURLTargets)`，把依赖写进 `INTERFACE_LINK_LIBRARIES`：

```cmake
INTERFACE_LINK_LIBRARIES "$<LINK_ONLY:-lpthread>;
  .../libmbedtls.a;.../libmbedx509.a;.../libmbedcrypto.a;
  $<LINK_ONLY:ZLIB::ZLIB>"
```

改用 CMake 后 OBS 侧直接生效：`-- Found CURL: .../lib/cmake/CURL/CURLConfig.cmake (found version "8.11.1")`。

### 4.7 `CMAKE_FIND_ROOT_PATH_MODE_*` 为 `ONLY`，`CMAKE_PREFIX_PATH` 单独无效

`ohos.toolchain.cmake` 设置：

```cmake
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
list(APPEND CMAKE_FIND_ROOT_PATH "${OHOS_SDK_NATIVE}")
```

`ONLY` 模式下所有 `find_path`/`find_library` 被重新根植到 `CMAKE_FIND_ROOT_PATH` 下。只传 `CMAKE_PREFIX_PATH` 时，curl 自带的 `FindMbedTLS.cmake` 只搜 sysroot，报 `Could NOT find MbedTLS`——即使 mbedTLS 明明已经 staged。

解法：把 staging prefix **也**加入 `CMAKE_FIND_ROOT_PATH`（toolchain 会把 SDK 追加在后面，sysroot 隔离性得以保留）。

### 4.8 `IMPORTED` target 必须加 `GLOBAL`

`add_library(X INTERFACE IMPORTED)` 创建的 target 只在**创建它的目录及其子目录**可见。在 `libobs/` 下创建后，`plugins/` 看不见，所有链接 `HarmonyOS::ohaudio` 的插件都报 `the target was not found`。

解法：`add_library(X INTERFACE IMPORTED GLOBAL)`。

### 4.9 HAP 要求裸 `.so` 文件名，`SOVERSION ""` 会产生致命的尾点

```cmake
set_target_properties(t PROPERTIES VERSION "" SOVERSION "")   # ✗ 产出 libobs.so.
```

后果是 `DT_NEEDED` 里写入 `libobs.so.`（带尾点），HAP 加载器无法解析，**运行时才暴露**。正确做法是根本不设 `VERSION`/`SOVERSION`。

同理不能强设 `PREFIX "lib"`：OBS 上游对 `libobs-opengl`、`obs-ffmpeg` 等 target 显式设了 `PREFIX ""`，因为图形模块是按精确名字 dlopen 的（`obs_video_info.graphics_module = "libobs-opengl"`）。强加前缀会产出 `liblibobs-opengl.so`，编译链接全过、运行时加载失败。

---

## 5. 构建系统集成

### 5.1 目标系统识别的时序陷阱

`cmake/common/osconfig.cmake` 原本只按 `CMAKE_HOST_SYSTEM_NAME` 分支。交叉编译时宿主是 Darwin，会**静默地把 OBS 配成 Metal 构建**。

但直接用 `CMAKE_SYSTEM_NAME STREQUAL "OHOS"` 也不行：`osconfig.cmake` 由 `bootstrap.cmake` 在 **`project()` 之前**加载，而 `CMAKE_SYSTEM_NAME` 要到 `project()` 的编译器探测阶段才由 toolchain 设置，此时仍为空。

解法：改用命令行即已存在的 `CMAKE_TOOLCHAIN_FILE` 判定：

```cmake
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
  set(_obs_harmony_target TRUE)
elseif(DEFINED CMAKE_TOOLCHAIN_FILE AND CMAKE_TOOLCHAIN_FILE MATCHES "(ohos|hmos)\\.toolchain\\.cmake$")
  set(_obs_harmony_target TRUE)
endif()
```

### 5.2 C 扩展必须保持开启

鸿蒙分支最初照抄 Windows/macOS 设了 `CMAKE_C_EXTENSIONS FALSE`，导致 `-std=c17` 严格模式，musl 随即隐藏 `fseeko`/`ftello` 等 POSIX 声明。Linux 分支其实**只**关 CXX 扩展；鸿蒙是 musl POSIX 目标，应对齐 Linux：

```cmake
set(CMAKE_CXX_EXTENSIONS FALSE)   # 只关 CXX，C 保持 gnu17
```

### 5.3 新增/修改的文件

```
新增
  cmake/harmony/{helpers,defaults,compilerconfig}.cmake   平台库解析、HAP 布局、编译选项
  libobs/cmake/os-harmony.cmake                           libobs 平台配置
  libobs/obs-harmony.{c,h}                                平台层（模块路径/系统信息/热键）
  libobs/harmony-compat/uuid/uuid.h                       libuuid shim（musl 无 uuid.h）
  libobs-opengl/gl-harmony-egl.{c,h}                      GLES/EGL winsys 后端
  libobs-opengl/harmony/glad/{glad,glad_egl}.h            GLES shim
  plugins/harmony-capture/  harmony-audio/  harmony-vcodec/
  build-aux/harmony/                                      依赖交叉编译流水线
  harmony/                                                ArkUI 前端工程

修改（共 11 个既有文件，改动均为最小侵入）
  CMakeLists.txt                       鸿蒙跳过 Qt frontend / test-input
  cmake/common/osconfig.cmake          OS_HARMONY 识别
  libobs/CMakeLists.txt                接入 os-harmony.cmake
  libobs/util/threading-posix.c        pthread_setname_np 条件加 __OHOS__
  libobs-opengl/CMakeLists.txt         跳过 glad、接入 GLES 后端
  libobs-opengl/gl-shaderparser.c      #version 300 es + precision 限定符
  libobs-opengl/gl-subsystem.c         cube map seamless / sRGB framebuffer 门控
  libobs-opengl/gl-stagesurf.c         复用 macOS 的 FBO 回读路径
  deps/libcaption/caption/caption.h    ssize_t 显式 include
  plugins/obs-ffmpeg/obs-ffmpeg.c      VAAPI 改为正向平台判断
  plugins/CMakeLists.txt               门控 obs-webrtc / obs-websocket / text-freetype2 / obs-libfdk / vlc-video
```

---

## 6. 依赖交叉编译

`build-aux/harmony/build-deps.sh`，全部产物为真实 arm64 ELF：

| 依赖 | 版本 | 构建方式 | 产物 | 备注 |
|---|---|---|---|---|
| SIMDe | 0.8.2 | header-only | `include/simde/` | x86 SSE 内建函数在 arm64 上的模拟层 |
| uthash | 2.3.0 | header-only | `include/uthash.h` | |
| jansson | 2.14 | CMake | `libjansson.a` 145 KB | 静态，被 libobs.so 吸收 |
| speexdsp | 1.2.0 | autoconf | `libspeexdsp.a` 113 KB | 音频重采样 + 降噪滤镜 |
| mbedTLS | 3.6.2 | CMake | 5 个静态库 | RTMPS/TLS |
| curl | 8.11.1 | **CMake** | `libcurl.a` 1.36 MB | 见 §4.6 |
| x264 | stable `b35605a` | autoconf | `libx264.a` 1.88 MB | **arm64 汇编已启用，未触发 `--disable-asm` 回退** |
| FFmpeg | 7.1 | autoconf | 7 个共享库 | 见 §4.5 |

ZLIB **不构建**——OHOS sysroot 已自带 1.3.1。

校验和全部真实计算并经独立复核（例如 mbedTLS 3.6.2 = `8b54fb9b…`，与官方 GitHub release 元数据一致）。`.deps-harmony` 总计 32 MB。

**验证方法**：`nm -D` 对静态吸收的依赖无效（FFmpeg/x264 用 `-fvisibility=hidden`，符号不进动态符号表）。改用字符串横幅：

```
$ strings -a libavcodec.so.61.19.100 | grep "x264 - core"
x264 - core %d%s - H.264/MPEG-4 AVC codec - Copy%s 2003-2025 - http://www.videolan.org/x264.html

$ strings -a libavformat.so.61.7.100 | grep -E "mbedtls_ssl|rtmp_"
mbedtls_ssl_set_hostname returned %d
rtmp_pageurl / rtmp_swfverify / rtmp_tcurl
```

一键校验：`./build-aux/harmony/verify-deps.sh --prefix .deps-harmony` → **46/46 PASS**。

---

## 7. 已知限制（SDK 层面，非实现缺陷）

以下均已核对 SDK 头文件确认不存在，不是没找到：

1. **窗口枚举 API 缺失** —— `native_avscreen_capture.h` / `_base.h` 中没有 `OH_AVScreenCapture_WindowInfo` / `GetWindowList`；`PresentPicker` 的 `OnUserSelected` 只回传采集类型与 display ID，**拿不到所选窗口的 mission ID**。因此窗口采集源只能接受手工输入的 mission ID，无法提供下拉列表。
2. **编码器 SEI 注入缺失** —— `native_avcodec_base.h` 无 SEI 相关 `OH_MD_KEY_*`，`get_sei_data` 未实现。影响：部分平台的服务端元数据（如 OBS 的 BPM）无法透传。
3. **显示分辨率查询缺失** —— 无 `native_display_manager` 头，采集分辨率只能作为用户设置项，默认 1080p。
4. ~~**系统音频内录的 PC 支持未验证**~~ —— **已在真机确认可用**，见 §8.2。官方文档写 `SystemCapability.Multimedia.Audio.PlaybackCapture` 支持 Phone/Tablet/TV，PC/2in1 需运行时探测；实测 API 26 手机上该 syscap 为 `true`。验证机 MatePad Edge 即跑在 PC/2in1 模式，内录已实测可用。桥接层已暴露 `nativeCanCaptureSystemAudio()`，UI 必须如实呈现探测结果而非假设可用。
5. **`show_hidden_windows` 无法实现** —— 唯一钩子 `SkipPrivacyMode(windowIDs,...)` 需要应用自有窗口 ID。
6. **零拷贝采集路径未启用** —— `OH_NativeImage` + `GL_TEXTURE_EXTERNAL_OES` 是正确方向，但 GLES 外部纹理需要 GLSL 里 `#extension GL_OES_EGL_image_external`，而 libobs 的 shader parser 不会输出该扩展声明。当前走 CPU 回读（`OH_NativeBuffer_MapAndGetConfig`）。

**待验证的最高风险假设**（需真机）：编码器 input-surface 模式假设 libobs 当前的 `EGLContext`/`EGLDisplay` 能用同一 `EGLConfig` 为编码器的 `OHNativeWindow` 建 surface，且 `eglSwapBuffers` 即向 AVCodec 提交一帧、`SET_UI_TIMESTAMP` 作为 PTS。

### 7.1 真机能力实测

在没有 PC 硬件的情况下，用一台 **API 26 / arm64-v8a 手机**（与目标同 ABI、同 API level）实测了 syscap。

**探测方法**（重要：`canIUse()` 是 ArkTS API，**shell 里不存在**；syscap 实际以系统参数形式暴露）：

```bash
hdc shell "param get const.SystemCapability.Multimedia.Audio.PlaybackCapture"   # → true
hdc shell "param get | grep -c const.SystemCapability"                          # → 514 条
```

实测结果，**11/11 全部为 true**：

| syscap | 结果 | 对 OBS 的意义 |
|---|---|---|
| `Graphic.Graphic2D.EGL` | ✅ | GLES 后端的地基 |
| `Graphic.Graphic2D.GLES3` | ✅ | shader `#version 300 es` 可用 |
| `Graphic.Graphic2D.NativeWindow` | ✅ | XComponent → EGLSurface 通路 |
| `Graphic.Graphic2D.NativeBuffer` | ✅ | 采集帧 CPU 映射（当前实现路径） |
| `Graphic.Graphic2D.NativeImage` | ✅ | **零拷贝路径可行**（§7.6 的后续项） |
| `Multimedia.Media.AVScreenCapture` | ✅ | 屏幕/窗口采集 |
| `Multimedia.Media.VideoEncoder` | ✅ | 硬件编码 |
| `Multimedia.Audio.Core` | ✅ | 音频采集 |
| `Multimedia.Audio.PlaybackCapture` | ✅ | **桌面音频内录（§7.4 悬案已解）** |
| `Multimedia.Camera.Core` | ✅ | 摄像头源可行（本期未实现） |
| `Window.SessionManager` | ✅ | 窗口管理 |

`Graphic.Graphic2D.NativeImage = true` 是个额外收获：意味着 §7.6 的零拷贝采集路径在设备侧是被支持的，唯一阻碍在我们这边（shader parser 不输出 `GL_OES_EGL_image_external` 扩展声明）。

### 7.1b 第二台设备复测（平板 QXS-W00）

换设备复测，结论一致：11 项 syscap **全部为 `true`**（API 26 / arm64-v8a）。

字体发现条件明显改善——`/system/fonts` 有 **260 个字体文件**，且：

```
drwxr-xr-x root root u:object_r:system_fonts_file:s0 /system/fonts
-rw-r--r-- root root 577200 DejaVuMathTeXGyre.ttf
```

目录与文件均为**全局可读**，所以 §7.4 里"沙箱能否读 /system/fonts"这一风险已从 DAC 层面排除；**唯一剩余未知量是 SELinux 域 `system_fonts_file` 是否放行 HAP 应用沙箱**，只有装上才能确认。

另注：`HarmonyOS_Sans.ttf` / `HarmonyOS_Sans_SC.ttf` 等文件确实存在，但文件名用下划线。文字源别名匹配的是字体**内部名称记录** `"HarmonyOS Sans"`，文件名不能证明该记录存在——这条假设仍待真机验证。

> 探测 `param get` 输出时注意：设备返回值带**尾随空格**（`true \n`），必须把空格一并 `tr -d` 掉，否则 `case` 比较全部失配、把一桌子 cap 误报成不支持。

### 7.2 当前阻塞真机运行的两件事

两者都是环境问题，不是代码问题：

1. **HAP 未签名** —— 真机拒绝安装：

   ```
   error: failed to install bundle. code:9568320 error: no signature file.
   ```

   已有的调试证书无法复用：`~/.ohos/config/` 里的 `.p7b` profile 绑定了 `com.qingkouwei.audiostudio` / `com.qingkouwei.easygoprobe`，bundle name 不匹配会被拒；调试 profile 由华为服务端签发并内含设备 UDID 白名单，无法本地伪造。

   **解法（约 2 分钟，需登录华为账号）**：DevEco Studio 打开 `harmony/` → File > Project Structure > Project > Signing Configs → 勾选 *Automatically generate signature* → OK。之后 hvigor 会同时产出 signed HAP。
   **替代路径**：模拟器安装**不需要签名**。

2. **设备锁屏** —— `aa start` 在开发者模式下无法自动解锁：

   ```
   Error Code:10106102  The device screen is locked during the application launch,
   unlock screen failed. The current mode is developer mode, and the screen
   cannot be unlocked automatically
   ```

   解法：验证前手动解锁并保持亮屏。

### 7.3 一键验证脚本

`build-aux/harmony/device-validate.sh` 把上述检查固化成一条命令，输出分项 PASS/FAIL：

```bash
./build-aux/harmony/device-validate.sh            # 自动挑 signed/unsigned HAP
./build-aux/harmony/device-validate.sh --skip-install --keep-open 1   # 只探设备能力
```

它按 7 个阶段跑：设备识别 → 安装 → 沙箱内 .so 是否解压（`extractNativeLibs` 的实际效果，直接关系 `os_dlopen` 能否加载插件）→ 启动并抓 hilog → 进程存活/崩溃/dlopen 失败 → 从应用日志断言各子系统 → **独立于应用**的 syscap 探测。第 7 阶段不需要安装成功，所以未签名时也能拿到设备能力结论。

---

## 8. 权限与合规

| 权限 | 等级 | 作用 | 获取难度 |
|---|---|---|---|
| `INTERNET` | normal | RTMP 推流 | 直接声明 |
| `MICROPHONE` | normal / user_grant | 麦克风采集 | 直接声明 |
| `KEEP_BACKGROUND_RUNNING` | normal | 推流期间后台长时任务 | 直接声明 |
| `CUSTOM_SCREEN_CAPTURE` | normal / user_grant | 屏幕采集（PC/2in1 自 API 14） | 直接声明 |
| `CUSTOM_SCREEN_RECORDING` | **受限开放** | 录制时**不弹系统隐私告警框**（API 22+） | 需 AGC 申请 |
| `INPUT_MONITORING` | **system_basic / 受限** | 全局快捷键、显示鼠标指针、共享桌面 | 需 AGC 审核，约 **3 个工作日** |

**没有 `CUSTOM_SCREEN_RECORDING` 的后果**：每次开始推流都会被系统隐私弹窗打断。这是 OBS 这类长时录制应用的核心体验项，应尽早提交申请，并保证未获批时功能可降级。

**全局快捷键降级路径**：当前实现不依赖 `INPUT_MONITORING`——按键状态由 ArkUI 层通过 `obs_harmony_set_key_state()` 下推，因此**应用内快捷键无条件可用**；只有跨应用全局热键需要该受限权限。

**其他合规点**：
- `Desktop Extension Kit`（状态栏 / 快捷栏 dock 接入）为 HarmonyOS 6.0.2(22)+，且**仅限中国大陆**（不含港澳台）。工程中留有带门控的 stub。
- 分发：本地调试用 HAP + `hdc install`；正式发布需在 AGC 打 `.app` 包上架。影视/直播类目通常需要《信息网络传播视听节目许可证》或全国网络视听平台备案——**OBS 作为推流工具是否触发该要求需与华为侧确认**。

---

## 9. 剩余工作与里程碑

### P1 收尾（2–3 周）
- [x] 把 libobs.so 及插件 .so 合入 HAP 的 `libs/arm64-v8a/`，打开 `HAVE_LIBOBS` 让桥接层真正调用 libobs
      —— 已完成，21 个 .so / 15.65 MB HAP，桥接层 57 个真实核心符号引用
- [x] `module.json5` 配置 `extractNativeLibs: true`（libobs 用 `os_dlopen(路径)` 加载插件，
      库不解压到沙箱就无法按路径 dlopen）
- [x] 设备能力实测：11 项 syscap 全部为 true（§7.1）
- [ ] **签名**（§7.2，约 2 分钟交互式操作）→ 安装 → 启动
- [ ] 真机验证 EGL surface 创建与首帧渲染

### P2 端到端推流（4–6 周）
- [ ] 采集 → 合成 → 编码 → RTMP 全链路打通
- [ ] 验证 §7.4 的内录 syscap，据实调整 UI
- [ ] 音视频时间戳对齐（`CLOCK_MONOTONIC` ns 与 `os_gettime_ns()` 基准是否一致）
- [ ] 场景切换、多源合成、混音器实测

### P3 体验与上架（4–8 周）
- [ ] `CUSTOM_SCREEN_RECORDING` / `INPUT_MONITORING` 权限申请
- [ ] Desktop Extension Kit 状态栏 / dock 集成
- [ ] PC 窗口行为：自由窗口、分屏、推流中关窗确认（`windowStageClose` / `windowWillClose` 已在 `EntryAbility.ets` 接线）
- [ ] 零拷贝采集路径（`OH_NativeImage`，需先让 shader parser 支持 GLSL 扩展声明）
- [ ] AGC 上架、签名、灰度

### 后续可选
- [ ] freetype + harfbuzz + fontconfig 交叉编译，恢复 `text-freetype2` 文字源（**最深的依赖链**，Scribus 迁移即卡在此处）
- [ ] CEF for OpenHarmony 接入，恢复浏览器面板
- [ ] 音频监听（audio monitoring）：当前用 null 实现，需基于 OHAudio 重写
- [ ] `obs-webrtc`（需 libdatachannel）、`obs-websocket`（需 asio + websocketpp）

---

## 10. 复现命令

### 一条命令（推荐）

```bash
./build-aux/harmony/build-obs.sh          # deps → cmake → ninja → stage → HAP
./build-aux/harmony/device-validate.sh    # 安装 → 启动 → 抓日志 → 分项断言
```

`build-obs.sh` 结束时自检桥接层是否真的链上了 libobs（统计 `libobs_bridge.so` 里未定义的 `obs_*`/`gs_*` 符号数），避免"构建成功但其实是 shell-only 模式"这种静默退化。

### 分步

```bash
SDK=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native

# 1. 交叉编译全部依赖（产物落到 .deps-harmony/，约 32 MB）
./build-aux/harmony/build-deps.sh --jobs 8
./build-aux/harmony/verify-deps.sh --prefix .deps-harmony   # → 46/46 PASS

# 2. 配置并构建 OBS native 侧
cmake -S . -B build-ohos -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$SDK/build/cmake/ohos.toolchain.cmake \
  -DOHOS_ARCH=arm64-v8a -DOHOS_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release \
  -DOBS_VERSION_OVERRIDE=32.2.2 \
  -DCMAKE_PREFIX_PATH="$PWD/.deps-harmony" \
  -DCMAKE_FIND_ROOT_PATH="$PWD/.deps-harmony"
cmake --build build-ohos                                      # → 12 个 .so

# 3. 把 native 产物 stage 成桥接层与 HAP 都需要的布局
./build-aux/harmony/stage-native.sh --build-dir build-ohos
#    → .ohos-stage/{include/obs,lib}   桥接层自动发现，据此开启 HAVE_LIBOBS
#    → harmony/entry/libs/arm64-v8a/   hvigor 打进 HAP

# 4. 构建 HAP
cd harmony
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap

# 5. 安装到设备（需先按 §7.2 完成签名）
hdc install entry/build/default/outputs/default/entry-default-signed.hap
```

> **`OBS_VERSION_OVERRIDE` 是必需的**：本仓库未拉取 git tag，`versionconfig.cmake` 的 `git describe` 会产出 `1bf1379fa-modified` 这类非法 semver，导致 `project(... VERSION)` 失败。
>
> **`OBS_HARMONY_PREFIX` 不要靠环境变量传**：hvigor 不会可靠地把父 shell 环境转发给它派生的 CMake configure，而 `entry/.cxx` 里缓存的空值会让桥接层**静默退回 shell-only 模式**。桥接层 CMakeLists 已改为按 `<repo>/.ohos-stage` 自动发现；改路径时用 `-DOBS_HARMONY_PREFIX=` 显式传入，并先删 `entry/.cxx`。

### 工具链事实

```
编译器      clang 15.0.4 (OHOS dev build)
target      --target=aarch64-linux-ohos --sysroot=$SDK/sysroot
libc        musl（toolchain 注入 -D__MUSL__）
SDK         API 26 / platformVersion 26.0.0 / 26.0.0.105
链接        ld.lld，-Wl,--no-undefined -Wl,--fatal-warnings（缺符号即硬错误）
C++ 运行时  libc++（OHOS_STL=c++_shared）
```

---

## 附：本次迁移中的工具链陷阱清单

按「踩到 → 症状 → 真因」整理，供后续同类移植参考：

| # | 症状 | 真因 | 修法 |
|---|---|---|---|
| 1 | mbedTLS 每个 TU 编译失败，报 `libeverest.a` 找不到 | toolchain 注入 `--gcc-toolchain=`，clang 报未使用参数，`-Werror` 升级为错误 | 全局 `-Qunused-arguments` |
| 2 | `config.sub: OS 'ohos' not recognized` | autotools 不认识 ohos，升级 automake 无效 | `--host` 用 gnu 三元组 |
| 3 | FFmpeg configure 中止 | mbedTLS 3.x 需显式许可开关 | `--enable-version3` |
| 4 | 消费方 `undefined symbol: inflateInit_ / mbedtls_des_init` | autoconf 构建的静态 curl 不导出 CMake package，传递依赖丢失 | curl 改用 CMake 构建 |
| 5 | `Could NOT find MbedTLS`（明明已 staged） | `CMAKE_FIND_ROOT_PATH_MODE_* = ONLY` 把查找根植到 SDK | prefix 加入 `CMAKE_FIND_ROOT_PATH` |
| 6 | 插件 `target was not found: HarmonyOS::ohaudio` | IMPORTED target 默认目录作用域 | `add_library(... IMPORTED GLOBAL)` |
| 7 | 运行期加载失败，`DT_NEEDED` 为 `libobs.so.` | `SOVERSION ""` 产生尾点 | 完全不设 VERSION/SOVERSION |
| 8 | 图形模块 dlopen 失败 | 强设 `PREFIX "lib"` 覆盖了上游的 `PREFIX ""` | 不干预 PREFIX |
| 9 | macOS 宿主上被配成 Metal 构建 | `osconfig.cmake` 在 `project()` 前运行，`CMAKE_SYSTEM_NAME` 尚为空 | 改用 `CMAKE_TOOLCHAIN_FILE` 判定 |
| 10 | `fseeko`/`ftello` 未声明 | `CMAKE_C_EXTENSIONS FALSE` → `-std=c17`，musl 隐藏 POSIX 声明 | 只关 CXX 扩展，对齐 Linux |
| 11 | `ssize_t` 未知类型 | musl 的 `<stdio.h>` 不像 glibc 那样传递引入 `<sys/types.h>` | 显式 include |
| 12 | `os_generate_uuid` 链接失败 | musl 无 libuuid，NDK 也无 UUID API | shim 实现 RFC 4122 v4（`/dev/urandom`） |
| 13 | configure 失败但脚本继续跑到 install | `if ( subshell )` 条件内 `set -e` 失效 | dep 脚本内显式 `&&` 串联 |
| 14 | `nm -D` 显示依赖符号数为 0 | FFmpeg/x264 用 `-fvisibility=hidden` | 用 `strings` 查版本横幅 |
| 15 | verifier 报所有符号 NOT found | `set -o pipefail` + `grep -q` → SIGPIPE 覆盖 grep 成功状态 | 去掉 `-q`，改重定向 |
| 16 | 续行链中插注释后行为诡异，但 `bash -n` 通过 | `\` 续行接注释行会截断整条命令 | 注释只放函数外 |
| 17 | 桥接层"构建成功"但没链上 libobs | hvigor 不转发父 shell 环境，`OBS_HARMONY_PREFIX` 环境变量丢失；且 `entry/.cxx` 缓存了空值 | 改为按 `<repo>/.ohos-stage` 自动发现；改配置后先删 `entry/.cxx` |
| 18 | 桥接层编译报 `simde/x86/sse2.h not found` | libobs 公开头文件不自包含：`graphics/vec4.h` → `util/sse-intrin.h` → SIMDe | staging 时把 deps 的 include/ 一并拷入，让 prefix 自包含 |
| 19 | `hdc shell canIUse ...` 报 command not found | `canIUse()` 是 ArkTS API，shell 里没有 | 用 `param get const.SystemCapability.<X>` |
| 20 | 真机安装失败 code 9568320 `no signature file` | 调试 profile 由华为服务端签发、绑定 bundle name + 设备 UDID，无法复用他人证书或本地伪造 | DevEco 里执行一次自动签名；或用模拟器（免签名） |
| 21 | `aa start` 报 10106102 屏幕锁定 | 开发者模式下不会自动解锁 | 验证前手动解锁并保持亮屏 |
| 22 | **`obs_reset_video()` 失败，画面全黑**（编译链接全过，运行时才暴露） | libobs 的 11 个 `.effect` shader 通过 `find_libobs_data_file()` 以**文件系统路径**加载；而 stage 到 `resources/rawfile/` 的资产在 HAP 内部**没有文件系统路径**，`access()` 永远查不到 | ArkTS 启动时把 rawfile 整棵树提取到 `filesDir/obsdata/`（`RawFileExtractor`，按 versionCode 打戳缓存），再经 `obs_harmony_set_paths(codeDir, dataDir)` 在 **`obs_startup()` 之前**注入 libobs |
| 23 | 桥接层编译报 `caption/caption.h not found` | 为拿 `obs_harmony_set_paths` 而 include 了 `obs-harmony.h`，它含 `obs-internal.h`，把 libobs 全部内部头拖进了外部消费者 | 拆出只含公开入口的 `libobs/obs-harmony-api.h`；内部头继续走 `obs-harmony.h` |
| 24 | 桥接层报 `undefined symbol: obs_harmony_set_paths` | libobs 以 `-fvisibility=hidden` 编译，函数未标 `EXPORT` 就不进动态符号表 | 公开入口一律加 `EXPORT` |
| 25 | 块注释里写路径通配符触发 `-Werror,-Wcomment` | 注释中的 `/*.effect` 被当成嵌套块注释起始 | 注释里不要写 `/*` 序列 |
| 26 | `text-freetype2` 链接失败，`load_os_font_list` 等未定义 | 插件用 `$<PLATFORM_ID:...>` 选字体后端，`OHOS` 既不匹配 `Windows,Darwin` 也不匹配 `Linux,FreeBSD,OpenBSD`，**一个后端都没编进去**。注意这里与 §4.1 相反：CMake 的 `PLATFORM_ID` 是 `OHOS`，而 C 预处理器看到的 `__linux__` 却为真——两套判定不一致 | 把 `OHOS` 加入 `find-font.c` 分支，并新增 `find-font-ohos.c` 扫描 `/system/fonts` |
| 27 | `libfreetype.a` 链上一堆找不到的 zlib 符号 | CMake 自带的 `FindFreetype` 生成的是 **UNKNOWN IMPORTED** target，不带 interface link libraries，而 sysroot 里恰好有 `libz.so`，于是 FreeType 启用了系统 zlib 却没人负责链接 | `-DFT_DISABLE_ZLIB=TRUE` 用 FreeType 自带的 zlib，让静态库自包含 |
| 28 | `hdc` 命令失败却返回退出码 0 | 无设备时 hdc 把 `[Fail]ExecuteCommand need connect-key` 打到 **stdout** 并 exit 0；`list targets` 返回带尾随 `\r` 的 `[Empty]` | 判断 hdc 结果要看**输出内容**，不能只看退出码；比较前先 `tr -d '\r'` |
| 29 | 自检脚本把所有正常项报成 FAIL | `set -o pipefail` 下 `grep -q` 提前退出，生产端收到 SIGPIPE，其非零状态覆盖 grep 的成功——**即本表第 15 条，写文档的人自己又踩了一次** | 一律用 `grep ... >/dev/null` 代替 `grep -q` |
