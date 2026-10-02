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
| ~~滤镜（色彩校正/缩放/色彩空间）~~ | **已闭环（10-02）**：FilterPanel 真机跑通（私有源创建 + defaults 修复） | — |
| ~~转场（叠化/滑动）~~ | **代码闭环（10-03 凌晨）**：私有 fade_transition 壳持有 channel 0（obs_transition_* 拒绝非转场源，与 Qt 前端/slideshow 同款做法）；设置面板"场景切换"档位 切/300/600/1000ms 持久化；进包验证完成，真机叠化观感待设备回线复验 | 验证 |
| ~~图片源 / 文字源~~ | **已闭环（10-02 深夜）**：图片走 DocumentViewPicker→沙箱拷贝→`file` 设置（预览渲染洋红测试图实证）；文字走 bindSheet 输入→`text` 设置（find-font-ohos.c 的 Sans Serif 别名解析默认字体，画布顶部渲染实证） | — |
| ~~场景切换挂通道~~ | **已闭环（10-02）**：多场景切换真机验证 | — |
| ~~软件编码 x264~~ | 维持"可跳过"判断（硬编 H.264/HEVC 双路已闭环） | — |
| ~~音频高级能力（降噪/增益/同步偏移）~~ | **代码闭环（10-03 凌晨）**：增益/噪声阈值/降噪/同步偏移四个音频滤镜进入候选清单（create_private 探针降级保护），面板 label i18n；libobs 音频滤镜按源处理、无桥接层改动。真机听感复验待设备回线 | 验证 |

## ❌ 三档：缺失

### ❌-A 可补齐（正常工程问题，按优先级）

1. **窗口采集** —— **代码侧完备，卡在 ACL（10-02）**：window-capture 已对齐 display-capture 帧路径，mission-0（用户选窗）模式跑通 Init/Start；三条官方 Picker 机制（SetSelectionCallback / StrategyForPickerPopUp / PresentPicker）全部接入后仍不弹，PresentPicker 返回 OPERATE_NOT_PERMIT（官方释义=缺权限）。剩余依赖：CUSTOM_SCREEN_RECORDING 受限权限 AGC 审批 + 签名配置（申请材料见 harmonyos-agc-permission-application.md），审批后复测。
2. ~~相机源~~ —— **已闭环（10-02）**：三层叠加 bug 全修（MapPlanes 对 ImageReceiver buffer 报 stride=1 垃圾值→改用 Image Kit 权威 GetRowStride；NV12 单组件半平面布局；Maleoon GLES 拒绝 libobs 的 GL_R8+GL_RG16 多平面上传→CPU NV12→RGBA 转换）。预览+滤镜叠加+录制成片三重真机验证。
3. ~~色准~~ —— **已闭环（10-02 晚）**：真机色卡测量实锤"解码一次不编码"根因（八个非端点灰阶精确落在 sRGB EOTF 曲线上：128→54、224→188；饱和原色因端点不动而幸免）。修复 = GS_BGRA 渲染目标恢复 GL_SRGB8_ALPHA8（§3.4 被 Maleoon 拒的只是 BGRA_EXT 三元组，RGBA/UNSIGNED_BYTE 组合是 ES3.0-core 被接受；可采样源纹理保持线性，其解码在 shader 里显式做）。修复后录制色值与恒等截图 Δ≤4。测量与实验全记录：harmonyos-color-measurement.md。
4. **HEVC 硬编** —— **录制链路已闭环（10-02 深夜）**：`harmony_hevc` 编码器（OH_VideoEncoder，插件早已注册、ENABLE_HEVC=ON）现接入设置面板"编码器(录制)"下拉 → SettingsStore 持久化 → 录制 config `videoCodec` → 桥接层 `CreateVideoEncoder` 按 codec 选 id 链（HEVC 请求下 `harmony_hevc→harmony_h264→obs_x264` 逐级退让；H.264 请求永不静默升级）。真机实证：切 HEVC→保存→杀应用→重启（持久层恢复）→录制，日志 `HEVC encoder started 1920x1080@30`，成片 ffprobe `codec_name=hevc`。推流仍固定 H.264（legacy RTMP/FLV 无标准 HEVC tag，与桌面一致需 SRT/QUIC 才能上 HEVC）。**剩余 AV1 / HDR Vivid**（Main10 路径 OH_VideoEncoder 支持，属 W3 差异化项，未接 UI）。
5. ~~长时任务规范化~~ —— **已闭环（10-02）**：audioRecording continuous task 接入（LongRunningTask.ets + backgroundModes 声明），息屏录制实测 544s 成片。见 journey §5.6。
6. ~~设置面板/配置持久化~~ —— **已闭环（10-02 晚）**：bindSheet 设置面板（分辨率 720p–4K / fps 30·60 / 录制与推流码率 / RTMP 服务器密钥）+ preferences JSON 持久化（字段级合并）+ nativeResetVideo 画布热切换（输出活跃时禁用，同桌面纪律）；重启自动恢复。**成片实证**：设 30fps 后录 461s，ffprobe `r_frame_rate=30/1`、13822 帧。
7. ~~rtmp-services 远程更新~~ —— **已闭环（10-03 凌晨）**：两层缺陷叠加在同一句"Remote update failed"后面——① libcurl(OHOS) 用 mbedTLS 后端且构建期无 CURL_CA_BUNDLE 默认，鸿蒙沙箱内又没有可读的系统 CA 文件，任何 HTTPS 都死在"certificate is not correctly signed by the trusted CA"；修复=curl.org CA bundle 打进 rawfile（certs/cacert.pem，随素材提取到 dataDir/certs/），nativeInit 设 CURL_CA_BUNDLE 环境变量，file-updater 尊重该变量（CURLOPT_CAINFO）。② 首查时挂 300 秒才报错：更新器不设连接超时，本网络到 obsproject.com 的 IPv6 路由"ICMPv6 通但 TCP/443 黑洞"，curl 线程解析器 AAAA 优先、每个地址烧满 SYN 重传表（wget v4 优先 1 秒即通）；修复=CONNECTTIMEOUT=10 / TIMEOUT=60。真机实证：模块加载 1.2 秒后 "Successfully updated file 'services.json' (version 293)"，缓存目录落盘。
8. ~~虚拟摄像头输出~~ —— **改判 ❌-B（10-03，调研闭环）**：Camera Kit 输入侧是封闭枚举（内置/USB外接/远程三型），无任何第三方注入虚拟 CameraDevice 的 API；文档里的"虚拟相机"是 DevEco 模拟器调试功能。桌面等价物（DirectShow/CMI 插件/v4l2loopback）全部依赖驱动级安装，沙箱模型下原理性禁止。叙事转换：窗口 Picker（ACL 后）让消费应用"捕获 OBS 预览窗口"= 带系统级用户授权的穷人版虚拟摄像头，安全姿态优于桌面；反方向（手机相机喂 PC 应用）是鸿蒙原生优势且 OBS 已可消费。详见 docs/harmonyos-virtual-camera-research.md。

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

- 按功能点粗算：核心链路 100%，全功能面 **≈65%**（❌-A 八项全部闭环或改判：1 窗口(代码侧,待ACL) / 2 相机 / 3 色准 / 4 HEVC录制(AV1 经真机探测=本机无硬件，VP9 亦无，归 W3 其他机型) / 5 长时任务 / 6 设置面板 / 7 rtmp-services 远程更新 / 8 虚拟摄像头→改判 ❌-B）；
- 剩余差距 = 二档转场 UI + 音频高级能力 + ❌-B 平台模型差异项；
- 剩余差距集中在"平台模型差异项"（❌-B），这部分不应追平，应转成鸿蒙特性创新（见系列文章大纲的"前沿探索篇"）。

## 建议的实施波次

- **W1（对齐补票）**：窗口 Picker + 相机源流程 + 滤镜/转场/多场景前端面板 + 色准
- **W2（规范与上架）**：长时任务 ✅ + AVSession（判定为采集类豁免，依据与口径见 harmonyos-store-compliance.md ✅）+ AGC 受限权限材料 ✅（待提交审批）+ 隐私合规文案 ✅（条目骨架已成，待挂链）→ 工程侧已具备上架形态
- **W3（差异化创新）**：HEVC/AV1 + HDR Vivid 录制、碰一碰开播/分享流、小艺意图一句话录制、分布式流转（手机当导播台/摄像头无线接入）、ArkWeb 浏览器源、实况窗直播状态
