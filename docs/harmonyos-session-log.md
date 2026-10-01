# OBS Studio → HarmonyOS 移植：会话记录与交接文档

> 用途：本文件是**工具无关**的交接记录。换 AI 工具、换会话、换人接手时，读这一份即可继续，不必重走任何弯路。
> 生成于：2026-09-29 会话。技术方案细节见 `harmonyos-migration.md`，本文只记**状态、决策、已验证事实、待办**。

---

## 0. 一分钟速览

**能力对齐盘点**：与桌面版 OBS 的三档差距（✅已对齐 / ⚠️已装载未验证 / ❌缺失，含"原理性不可行"清单与 W1-W3 波次规划）见 **`harmonyos-feature-alignment.md`**。当前对齐度按功能点粗算 ≈40%，核心链路 100%。

**状态（2026-10-01 深夜更新）**：**OBS 三大核心能力全部真机跑通——预览 ✓ 录制 ✓ RTMP 推流 ✓。** `obs_reset_video` rc=0，EGL/GLES 后端在 Maleoon 916B 初始化完成，12 插件加载，屏幕采集 30fps 进渲染树，预览实时显示真实桌面，录制产出可播放 mp4（h264 1080p60+aac），RTMP 推流经 mediamtx 收流+HLS 回拉验证（3.7 分钟 13544 帧零中断）。完整过程（每个 bug 的现象→排查→根因→修复→教训）见 **`harmonyos-port-journey.md`**（面向技术写作）。

```bash
./build-aux/harmony/build-obs.sh --skip-deps          # exit 0
./build-aux/harmony/check-contracts.sh                # PASS 38 / FAIL 0
./build-aux/harmony/verify-deps.sh --prefix .deps-harmony   # 60/60 PASS
```

真机首启日志（QXS-W00 / API 26）：
```
[obs] HarmonyOS EGL initialized, version 1.4
[obs] HarmonyOS graphics: Maleoon 916B (HUAWEI), GLSL OpenGL ES 3.2 B312
[obs] video settings reset: base/output 1920x1080, fps 60/1, NV12, Rec.709
[obs] NV12 texture support enabled
libobs 32.2.2 started (video rc=0)
plugin harmony-{capture,audio,camera,vcodec} loaded
plugin obs-{ffmpeg,filters,outputs,transitions,x264} loaded
plugin rtmp-services / image-source / text-freetype2 loaded   （共 12 个）
```

**真机首启过程中修掉的 5 个运行时 bug**（编译链接全过、只有真机才暴露，详见 migration.md 附录 #30–#34）：
1. libobs 的 `blog()` 默认写 stderr，不进 hilog → 桥接层 `base_set_log_handler` 转发（否则 gs_create 失败原因被吞）。
2. GLES shader：`out gl_PerVertex{...}` 重声明被拒；`textureSize` 返回 ivec 不能隐式转 vec；`textureLod` 第三参需 `float(lod)`；`65535./4095`（int 字面量）算术类型不匹配 → 全在 `gl-shaderparser.c` 的 `__OHOS__` 分支修。
3. `default_rect.effect` 用 `sampler2DRect`（GLES 保留字）→ obs.c 里 `#ifndef __OHOS__` 跳过加载与校验。
4. `format_conversion.effect` 的 `Sample(sampler, uv, 0)` 第三参是 texel offset（桌面合法、GLES 无重载）→ 删掉恒为 0 的 offset。
5. **Maleoon GLES 驱动拒绝 `GL_BGRA_EXT` 作 texImage2D 的 format（INVALID_OPERATION），也拒绝 `0x8035` 作 type（INVALID_ENUM）**，尽管 syscap 声称支持 `GL_EXT_texture_format_BGRA8888` → `convert_gs_internal_format`/`convert_gs_format` 的 `__OHOS__` 分支把 GS_BGRA 退成 `GL_RGBA8 + GL_RGBA + GL_UNSIGNED_BYTE`。
6. **插件 dlopen 失败**：SELinux 拒绝对 bundle libs 目录 `opendir()`（libobs 的 `obs_find_modules2` 目录扫描静默扫到 0 个），且 `dlopen("/data/storage/el1/bundle/.../x.so")` 绝对路径被 linker namespace 拒（`check ns accessible failed`）→ 桥接层改为**按裸 soname 显式 `obs_open_module`+`obs_init_module` 加载已知插件清单**（裸名走应用 native lib 搜索路径，可加载）。

**P2 端到端进展（同日续）**：屏幕采集链路已端到端跑通，仅剩预览呈现黑屏。
- 采集验证：`OH_AVScreenCapture_Init` 成功 → `capture started 1920x1080@30` → 点"开始共享"后 buffer 回调持续触发（frame #1→#10000+，约 30fps）→ 首帧诊断 `attr.size=8294400`、`OH_AVBuffer_GetAddr` 地址有效、**中心像素 36,38,43 正是 OBS 深色窗口背景** → 真实屏幕像素已进 libobs source。
- 又修 3 个采集坑：① config 音频 sampleRate/channels 非 0 却配 `OH_SOURCE_INVALID` → Init 报 OPERATE_NOT_PERMIT，改两者为 0（display+window 两处）；② `OH_NativeBuffer_MapAndGetConfig` 对 GPU-usage buffer 返回全零视图 → 改官方样例的 `OH_AVBuffer_GetAddr`；③ 强制 alpha=0xFF（采集 buffer alpha 未定义，预乘混合下 alpha=0 全透明）。
- **PC/2in1 关键行为**：本平板跑 PC 模式（窗口标题"HarmonyOS PC·2in1"），`OH_CAPTURE_SPECIFIED_SCREEN` 启动后弹"选择共享内容"Picker，必须点"开始共享"才出帧。
- 渲染管线打通：`NativeCreateScene` 漏 `obs_set_output_source(0, source)` → canvas 恒空 → 源永不 activate。补上后 activate 在图形线程正确触发。
- **预览黑屏根因（已解决）**：glad shim 把 `GL_TEXTURE_RECTANGLE` 误定义为 `0x0DE1`（=GL_TEXTURE_2D 本身）→ `gs_texture_is_rect()` 对所有 2D 纹理恒真 → `gs_draw_quadf` 走 rect 分支生成像素坐标 UV → 普通采样器 CLAMP 恒采角点。改真值 `0x84F5` 即愈。定位手法（红帧/渐变合成实验 + attrbuf dump）见 journey §3.15。
- **录制/推流闭环（同日打通）**：mp4_output 替换 ffmpeg_muxer（沙箱禁 fork）；编码线程共享 EGL context + VBO + NV12→RGB shader；`obs_output_set_service` 不加引用的生命周期坑。详见 journey §4–§5 与本文 §2 已验证事实。
- 教训：多次"THREAD_BLOCK/白屏"是平板自动熄屏假象，验证前先 `power-shell wakeup` 并确认屏幕亮着。

---

## 1. 决策记录（勿在未读理由的情况下推翻）

### 1.1 前端走 ArkUI 原生重写，不移植 Qt

由用户明确选定。理由链：

- OBS 32.x 硬性要求 Qt6（`frontend/cmake/ui-qt.cmake:1` `find_package(Qt6 REQUIRED Widgets Network Svg Xml)`），85.5k LOC、836 文件、**纯 Widgets 零 QML**
- Qt for HarmonyOS 官方 QPA 路线虽已宣布，但公开的第三方软件迁移实测案例（Scribus / Notepad++ / RStudio）停留在 **Qt 5.12.12 / 5.15**；Qt6 需自行源码编译，成熟度未验证
- 降级到 Qt5 等于重写前端，不如直接原生化

**代价（已知并接受）**：UI 全部重建；永久脱离上游 OBS 代码线，后续同步上游需人工移植。

### 1.2 音频内录用 `OH_AudioCapturer` 而非 `AVScreenCapture`

`AVScreenCapture` 也能带系统音频，但把画面和音频耦合成一个会话。改用 API 26 的 `OH_AudioStreamBuilder_SetPlaybackCaptureMode` + `RequestPlaybackCaptureStart`，与麦克风走同一套 `AudioCapturer` 抽象，两个源可独立增删。

**关键约束**：内录启动是**异步**的，启动接口返回成功只代表"请求已提交"，真实授权结果（含用户是否点了拒绝）只在回调里给。

### 1.3 图形后端走 GLES3/EGL，用 shim 而非重生成 glad

`deps/glad` 只为桌面 GL 生成。重生成会扰动所有平台。改为在 `libobs-opengl/harmony/glad/glad.h` 放一个 shim 头，靠 include 路径优先级只在鸿蒙生效。

实测缺口很小：libobs-opengl 用 177 个 `GL_*` 符号，鸿蒙 GLES 头缺 11 个，其中 5 个有等价扩展可别名映射。

### 1.4 采集暂用 CPU 回读，零拷贝路径留作后续

`OH_NativeImage` + `GL_TEXTURE_EXTERNAL_OES` 是正确方向，且设备侧 `Graphic.Graphic2D.NativeImage = true` 已确认可用。但 GLES 外部纹理需要 GLSL 里 `#extension GL_OES_EGL_image_external`，而 libobs 的 shader parser 不输出扩展声明。属于可解但非平凡的改动，故未在本阶段做。

### 1.5 文字源不引入 harfbuzz / fontconfig

查证 `plugins/text-freetype2/` 内 `harfbuzz`/`hb_` 命中 **0 次**（逐字形栅格化，不调 shaping），故只交叉编译 FreeType 一个库。

字体发现新增 `find-font-ohos.c` 直接扫描 `/system/fonts`。

---

## 2. 已验证事实（重新发现的代价很高）

### 2.1 工具链

| 项 | 值 |
|---|---|
| 编译器 | clang 15.0.4（OHOS dev build） |
| target | `--target=aarch64-linux-ohos --sysroot=$SDK/native/sysroot` |
| libc | **musl**（`__GLIBC__` 未定义，toolchain 注入 `-D__MUSL__`） |
| `__linux__` | **定义为真**（与 `__OHOS__` 并存） |
| `PLATFORM_ID`（CMake） | `OHOS` —— 与 `__linux__` 为真**不一致**，是个陷阱 |
| SDK | API 26 / platformVersion 26.0.0 / 26.0.0.105 |
| 链接 | `ld.lld`，`-Wl,--no-undefined -Wl,--fatal-warnings` |
| 警告 | `-Werror` 全局开启 |
| SDK 路径 | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native` |

`-DCMAKE_FIND_ROOT_PATH_MODE_{LIBRARY,INCLUDE,PACKAGE}=ONLY`，故 `CMAKE_PREFIX_PATH` 单独不够，须同时给 `CMAKE_FIND_ROOT_PATH`。

### 2.2 真机探测结果（两台设备交叉复测）

| 设备 | 类型 | API | ABI |
|---|---|---|---|
| ALN-AL80 | phone | 26 | arm64-v8a |
| QXS-W00 | tablet | 26 | arm64-v8a |

**11 项 syscap 在两台设备上全部为 `true`**：

```
Graphic.Graphic2D.{EGL,GLES3,NativeWindow,NativeBuffer,NativeImage}
Multimedia.Media.{AVScreenCapture,VideoEncoder}
Multimedia.Audio.{Core,PlaybackCapture}
Multimedia.Camera.Core
Window.SessionManager
```

`Multimedia.Audio.PlaybackCapture = true` 关闭了原先最大的架构问号（桌面音频内录是否可用）。

`/system/fonts`：260 个字体文件，`drwxr-xr-x root root` + 文件 `-rw-r--r--` → DAC 全局可读；唯一未知量是 SELinux 域 `system_fonts_file` 对 HAP 沙箱是否放行。

**探测陷阱**：`hdc shell param get X` 输出带**尾随空格**（`true␠\n`），必须 `tr -d '\r\n '`。漏掉空格会让全部比较失配。且 hdc **无设备时返回退出码 0** 并把 `[Fail]ExecuteCommand need connect-key` 打到 stdout——不能只看退出码。

### 2.3 运行时路径契约

```
HAP 安装后 native 库（extractNativeLibs:true 才会解压）:
  /data/app/el1/bundle/public/com.obsproject.studio.harmony/libs/arm64-v8a/
ArkTS: context.bundleCodeDir + "/libs/arm64-v8a"     ← libobs 的插件搜索路径
ArkTS: context.filesDir                              ← OBS 配置目录
ArkTS: context.filesDir + "/obsdata"                 ← rawfile 提取目标，即 libobs 数据根
```

`resources/rawfile` 在 HAP 内**没有文件系统路径**，而 libobs 用 `access()` 找数据文件，所以必须提取。`obs_reset_video()` 要 11 个 `.effect`，缺失即全黑屏。

### 2.4 库命名契约（改错就运行期失败）

- 图形模块文件名必须是**精确**的 `libobs-opengl.so` —— `ovi.graphics_module` 按此名 dlopen
- HAP 的 `libs/{abi}/` 要裸 `.so` 名。`SOVERSION ""` 会产出 `libobs.so.`（带尾点），`DT_NEEDED` 无法解析
- 不能强设 `PREFIX "lib"`，否则 `libobs-opengl` → `liblibobs-opengl.so`
- 依赖静态吸收的库（FFmpeg / FreeType）在 `-fvisibility=hidden` 下不进动态符号表，**`nm -D` 查不到不等于没链上**，要用 `strings -a | grep <版本横幅>` 验证

### 2.5 已确认正确的跨层 ID（全部与源码注册名逐一比对过）

```
源:  harmony_display_capture  harmony_window_capture  harmony_camera_capture
     harmony_mic_capture      harmony_desktop_audio   image_source
编码器: harmony_h264  harmony_hevc  obs_x264  ffmpeg_aac
输出: rtmp_output     mp4_output（录制用；ffmpeg_muxer 需 fork 子进程，沙箱禁用不了）
```

曾发现 UI 请求 `harmony_screen_capture`（不存在），已修。`check-contracts.sh` 第 1 项专防此类问题。

---

## 3. 产物清单

### 3.1 修改的既有文件（13 个，均为最小侵入）

```
.gitignore                                    放行 harmony/，忽略其构建产物
CMakeLists.txt                                鸿蒙跳过 Qt frontend / test-input
cmake/common/osconfig.cmake                   OS_HARMONY 识别（靠 CMAKE_TOOLCHAIN_FILE 而非 CMAKE_SYSTEM_NAME）
deps/libcaption/caption/caption.h             ssize_t 显式 include <sys/types.h>
libobs/CMakeLists.txt                         接入 os-harmony.cmake + stage .effect
libobs-opengl/CMakeLists.txt                  跳过 glad，接入 GLES 后端
libobs-opengl/gl-shaderparser.c               #version 300 es + precision 限定符
libobs-opengl/gl-stagesurf.c                  复用 macOS 的 FBO 回读路径（GLES 无 glGetTexImage）
libobs-opengl/gl-subsystem.c                  cube map seamless / sRGB framebuffer 门控
libobs/util/threading-posix.c                 pthread_setname_np 条件加 __OHOS__
plugins/CMakeLists.txt                          门控 webrtc/websocket/libfdk/vlc-video；注册 harmony-*
plugins/obs-ffmpeg/obs-ffmpeg.c                VAAPI 改正向平台判断（否定式判断误伤鸿蒙）
plugins/text-freetype2/CMakeLists.txt           接入 OHOS 字体后端
```

### 3.2 新增

```
cmake/harmony/{helpers,defaults,compilerconfig}.cmake
libobs/cmake/os-harmony.cmake
libobs/obs-harmony.{c,h}  libobs/obs-harmony-api.h
libobs/harmony-compat/uuid/uuid.h                libuuid shim（musl 无 uuid.h）
libobs/audio-monitoring/harmony/                 OHAudio 渲染后端（替换 null 实现）
libobs-opengl/gl-harmony-egl.{c,h}               GLES/EGL winsys
libobs-opengl/harmony/glad/{glad,glad_egl}.h     GLES 兼容 shim
plugins/{harmony-capture,harmony-audio,harmony-camera,harmony-vcodec}/
plugins/text-freetype2/find-font-ohos.c
build-aux/harmony/                               依赖交叉编译 + 构建 + 校验
harmony/                                         ArkUI 前端工程（34 源文件）
docs/harmonyos-migration.md (609 行)  docs/harmonyos-session-log.md (本文件)
```

### 3.3 构建产物（已 gitignore，勿提交）

`.deps-harmony/`（32M） `.deps-harmony-src/` `.deps-harmony-build-*/`（343M）
`build-ohos/` `.ohos-stage/` `harmony/entry/{build,.cxx,libs}/` `harmony/.hvigor/`

### 3.4 能力现状

| 子系统 | 状态 |
|---|---|
| libobs 核心 / GLES 图形后端 | ✅ 编译链接通过 |
| 屏幕 / 窗口 / 摄像头 / 麦克风 / 桌面音频 采集 | ✅ 已实现并打包 |
| 硬件 H.264/H.265 + x264 软编兜底 | ✅ 已实现，硬件优先 |
| RTMP 推流（内置 librtmp） | ✅ 已编译进 `obs-outputs.so` |
| 录制（ffmpeg_muxer） | ✅ |
| 音频监听 | ✅ 真实 OHAudio 后端（原为 null） |
| 文字源 | ✅ FreeType 静态吸收，NEEDED 仅 libobs+libc |
| 浏览器面板 / 脚本 / obs-websocket / obs-webrtc | ⛔ 门控（CEF / libdatachannel / asio 未移植） |
| **真机运行** | ❌ **未验证**（卡在签名） |

---

## 4. 待办

### 4.1 立即（人工，1 步）

签名 → 然后：

```bash
./build-aux/harmony/build-obs.sh --skip-deps    # 重打签名包 + 38 项契约自检
./build-aux/harmony/device-validate.sh          # 7 阶段验证
```

`device-validate.sh` 覆盖：设备识别（类型/API/ABI）、安装、沙箱内 `.so` 是否真解压、启动并抓 hilog、进程存活/faultlog/dlopen 失败、从日志断言各子系统、独立于应用的 syscap 与字体目录探测。

### 4.2 真机首启后的验证顺序（按风险，不是按功能）

1. `obs_startup` → `obs_reset_video` 是否成功（沙箱路径解析 + EGL context 首次真实创建）
2. 画面是否渲染出来（`PreviewCanvas` 的 XComponent → NativeWindow → EGLSurface）
3. 内录是否弹系统授权框、拒绝路径是否干净降级
4. 摄像头是否绿屏（`OH_ImageNative_GetByteBuffer` 只包 Y 平面即为此症状）
5. 音频监听是否起声（需累积约 25ms 才启动，安静源可能永不触发）
6. 文字源是否空白（SELinux 域是否放行 `/system/fonts`）
7. 推流 / 录制端到端

### 4.3 未验假设清单（代码看不出，只能真机）

| # | 假设 | 若为假的后果 | 出处 |
|---|---|---|---|
| 1 | `OH_ImageNative_GetByteBuffer` 返回整个 NV12 | 摄像头画面全绿 | 摄像头实现 |
| 2 | 纯视频会话（无 PreviewOutput）能 `CommitConfig` | 摄像头打不开 | 摄像头实现 |
| 3 | `OH_AudioRenderer_Stop/Release` 同步保证无后续回调 | teardown 时 use-after-free 崩溃 | 音频监听 |
| 4 | 监听需 ~25ms 音频才启动 | 安静源"没声音且不报错" | 音频监听 |
| 5 | 输出侧增强路由 API 可用 | 监听静默回落到默认设备 | 音频监听 |
| 6 | 编码器 input-surface 可复用 libobs 的 EGLContext | 硬件编码不可用 | 编码器 |
| 7 | 主字体内部名为 `"HarmonyOS Sans"` | 回落到 `readdir` 顺序首个，可能选到位图/emoji 字体 | 文字源 |
| 8 | SELinux 放行 HAP 沙箱读 `system_fonts_file` | 文字全空白 | 文字源 |
| 9 | `AVScreenCapture` 帧时间戳与 `os_gettime_ns()` 同基准 | 音画不同步 | 采集 |

### 4.4 后续工程项

零拷贝采集（需先让 shader parser 支持 GLSL 扩展声明）· CEF 浏览器面板 · libfdk-aac · libdatachannel · `CUSTOM_SCREEN_RECORDING` / `INPUT_MONITORING` 的 AGC 受限权限申请（审核约 3 工作日）· Desktop Extension Kit 状态栏/dock（仅中国大陆）

---

## 5. 踩坑清单

**29 条完整记录在 `harmonyos-migration.md` 附录**，按"症状 → 真因 → 修法"组织。接手前至少读这 5 条，它们最容易反复踩：

| # | 一句话 |
|---|---|
| 4.3 | toolchain 注入 `--gcc-toolchain=`，clang 报未使用参数，遇 `-Werror` 则**每个 TU 都失败**，而表面症状误导人。解药 `-Qunused-arguments` |
| 4.4 | `config.sub` 不认识 `ohos`（curl 自带 2022 版和 automake 1.17 都不行），`--host` 须用 gnu 三元组 |
| 4.7 | `add_library(... IMPORTED)` 不加 `GLOBAL` 则只在创建目录可见，插件全报 target not found |
| 4.1 | `__linux__` 为真导致**否定式**平台判断误伤鸿蒙（VAAPI 就是这么被错误启用的） |
| 29 | `set -o pipefail` 下 `grep -q` 触发 SIGPIPE，把成功判成失败——**本会话踩了两次**，包括写校验脚本的人自己 |

---

## 6. 接手阅读顺序

1. 本文件 §0–§1（状态与决策，避免推翻已定的方向）
2. `harmonyos-migration.md` §4（关键技术发现）+ §5（构建系统集成）
3. `build-aux/harmony/README.md`（依赖构建排错表）
4. `harmony/README.md`（ArkUI 工程结构与 stub 清单）
5. 动手前先跑 `build-obs.sh --skip-deps`，以 `check-contracts.sh` 的 38 项作为基线

**不要提交构建产物**（§3.3 那些目录已被 `.gitignore` 覆盖，但 `harmony/` 曾被 `/*` 白名单规则整体忽略过，已修）。
