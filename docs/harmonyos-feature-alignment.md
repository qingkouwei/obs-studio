# OBS Studio 鸿蒙版 · 能力对齐规划（vs Windows/macOS/Linux 桌面版）

> 基线：OBS Studio 32.2.2 桌面版能力集合；现状：HarmonyOS NEXT（API 26 / arm64 / MatePad Edge PC-2in1 模式）真机验证。
> 更新：2026-10-01 深夜。三档分类：**✅ 已对齐（真机实证）/ ⚠️ 已装载未验证（注册≠可用）/ ❌ 缺失**（缺失里再分"可补齐"与"原理性不可行"）。

## ✅ 一档：已对齐且真机实证（核心直播链路）

| 能力 | 桌面版对应 | 鸿蒙实现 | 实证 |
|---|---|---|---|
| 全屏采集 | win-capture / desktop-capture | AVScreenCapture NDK（harmony-capture） | 30fps 帧进渲染树，中心像素=真实屏幕 |
| 场景合成 + 实时预览 | 通用 | libobs + EGL/GLES3 后端 + XComponent | 预览实时显示真实桌面 |
| 录制出片 | ffmpeg muxer（子进程） | **mp4_output（进程内）** + OH_VideoEncoder surface 硬编 | h264 1080p60 + aac，ffprobe+抽帧双验证 |
| RTMP 推流 | rtmp-output + rtmp-services | librtmp 进程内 + rtmp-services 本地 package | mediamtx 收流 + HLS 回拉，13544 帧零中断 |
| 系统音频内录 | wasapi_output_duplication | AVScreenCapture PlaybackCapture | loopback authorized，成片带音轨 |
| 后台持续采集编码 | 天然（桌面多任务） | 切后台 221s 成片无 ANR | 实测（长时任务规范化待补，见 ❌） |
| 插件框架 | obs_open_module 目录扫描 | 裸 soname 显式清单（12 个） | 全部加载成功 |
| 服务预设（Twitch/YouTube 等） | rtmp-services | 同插件（远程更新降级本地兜底） | 加载 ✓，本地服务可用 |

已加载插件清单：harmony-{capture,audio,camera,vcodec} + obs-{ffmpeg,filters,outputs,transitions,x264} + rtmp-services + image-source + text-freetype2。

## ⚠️ 二档：已装载但 UI 层未验证（内核就绪，缺前端入口）

| 能力 | 缺口 | 补齐成本 |
|---|---|---|
| 滤镜（色彩校正/缩放/色彩空间） | obs-filters 已加载，ArkTS 无滤镜面板 | 低（面板 + obs_source_get_filter_by_id 通路） |
| 转场（叠化/滑动） | obs-transitions 已加载，无场景切换 UI | 低 |
| 图片源 / 文字源 | image-source、text-freetype2 已加载，无 Picker 流程 | 中（文件选择 + fontconfig/字体路径） |
| 场景切换挂通道 | obs_set_output_source 单场景已通，多场景切换未做 | 低 |
| 软件编码 x264 | obs-x264 加载，未实测（移动端主用硬编，价值低） | 可跳过 |
| 音频高级能力（降噪/增益/同步偏移） | filters 内含，无 UI 与实测 | 低-中 |

## ❌ 三档：缺失

### ❌-A 可补齐（正常工程问题，按优先级）

1. **窗口采集**：AVScreenCapture 支持 OH_CAPTURE_SCREEN + window 模式（`display-capture.c` 已有 window-capture 雏形）；缺 PC/2in1 窗口选择 Picker 流程。
2. **相机源**：harmony-camera 插件在，缺 Camera Kit 会话 → libobs texture 的 UI 流程与权限。
3. **色准**：8bit sRGB canvas 双重编码（GS_BGRA 退 RGBA 的连带项）→ 线性 canvas 或 sRGB-aware 路径。
4. **HEVC/AV1 硬编**：OH_VideoEncoder 支持（HDR Vivid 文档证实 HEVC Main10 路径），harmony-vcodec 只做了 H.264。
5. ~~长时任务规范化~~ —— **已闭环（10-02）**：audioRecording continuous task 接入（LongRunningTask.ets + backgroundModes 声明），息屏录制实测 544s 成片。见 journey §5.6。
6. **设置面板/配置持久化**：profile 级设置（分辨率/码率/键率）UI 化。
7. **rtmp-services 远程更新**：mbedTLS 证书链问题（可修，非阻塞）。
8. **虚拟摄像头输出**：需调研鸿蒙侧等价机制（系统是否有虚拟视频输入 API；若无，考虑分布式/投屏形态替代叙事）。

### ❌-B 原理性不可行 / 平台模型差异（永远不"对齐"，需产品叙事转换）

| 桌面能力 | 鸿蒙现实 | 转换方案 |
|---|---|---|
| 游戏采集（Windows hook 注入） | 沙箱禁注入 DLL/hook 第三方进程 | 全屏采集覆盖大部分场景；PC/2in1 Picker 支持"共享指定窗口" |
| ffmpeg muxer 多格式封装（mov/mkv/flv/m3u8/ts） | 子进程模型被沙箱禁 | mp4_output 已覆盖主流；多格式可评估纯进程内 ffmpeg muxer 改造（禁 fork，把 avformat 全部搬进进程——工作量大） |
| 浏览器源 CEF | CEF 无鸿蒙移植 | ArkWeb 替代 → 独立"ArkWeb 源"插件（创新点，见下） |
| 全局热键（低层钩子） | 无系统级全局钩子 | 键盘事件仅在应用窗口聚焦时可达；或用系统入口（小艺/意图）替代"一句话开播" |
| V8 脚本源（obs-scripting） | 理论可行（进程内 V8 交叉编译）但生态依赖 Qt/python | 远期项 |
| 多显示器枚举 | 形态不同（外接屏走分布式协同/投屏叙事） | Cast/投屏方向重构 |

## 对齐度估算

- 按功能点粗算：核心链路 100%，全功能面 **≈40%**；
- 补完 ❌-A 前两项 + 二档全部 → 观感 **≈65-70%**；
- 剩余差距集中在"平台模型差异项"（❌-B），这部分不应追平，应转成鸿蒙特性创新（见系列文章大纲的"前沿探索篇"）。

## 建议的实施波次

- **W1（对齐补票）**：窗口 Picker + 相机源流程 + 滤镜/转场/多场景前端面板 + 色准
- **W2（规范与上架）**：长时任务 + AVSession + AGC 受限权限材料（CUSTOM_SCREEN_RECORDING）+ 隐私合规文案 → 具备上架形态
- **W3（差异化创新）**：HEVC/AV1 + HDR Vivid 录制、碰一碰开播/分享流、小艺意图一句话录制、分布式流转（手机当导播台/摄像头无线接入）、ArkWeb 浏览器源、实况窗直播状态
