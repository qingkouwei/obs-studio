# OBS 鸿蒙版 · 虚拟摄像头可行性调研（❌-A8）

> 桌面 OBS 的"虚拟摄像头输出"（obs-virtualcam）= 把合成画面注册成一个系统摄像头设备，供会议软件等任意应用当作 Camera 输入消费。本调研回答：HarmonyOS 上有没有第三方应用可用的等价机制。
> 依据：官方 Camera Kit 文档（开发者知识库检索，2026-10-03），出处随文标注。

## 一、结论：**平台无第三方虚拟摄像头注册 API（原理性不可行，转产品叙事）**

### 官方事实链

1. **Camera Kit 的输入侧是封闭枚举**。`getSupportedCameras()` 返回的 `CameraDevice` 列表来自系统相机服务，`ConnectionType` 只有三种：内置（BUILT_IN）/ USB 外接 / 远程（REMOTE，分布式协同场景）。**没有任何 API 允许应用向该列表注入一个虚拟设备**——相机输入流的唯一入口是 `createCameraInput(device)`，device 必须来自系统枚举。
2. **"虚拟相机"仅存在于 DevEco 模拟器**，是开发调试工具（加载预置图片模拟无摄像头环境），不是设备端应用可注册的能力。
3. **消费侧同样封闭**：Web/ArkWeb 的 `getUserMedia` 授权后拿到的仍是系统相机流；媒体录制服务的视频源只有 `surface_yuv`（输入 surface 由调用方自己持有，不能广播给别的 app）。
4. 系统对"相机数据通路"的管控意图明确：相机帧从 HDI 底层直通 Surface，中间没有给第三方留"伪造源"的挂载点（防摄像头劫持，属安全基线）。

对照桌面：Windows（DirectShow/MF 虚拟设备驱动）、macOS（CoreMediaIO 插件，需安装特权 helper）、Linux（v4l2loopback 内核模块）——三者都要求**驱动/特权组件**安装权限，鸿蒙沙箱模型下本就不允许 sideload 内核级组件，与"沙箱禁注入"是同一族 ❌-B 结论。

### 产品叙事转换（写进文章/PR RFC 的口径）

| 桌面虚拟摄像头用途 | 鸿蒙替代路径 |
|---|---|
| 会议软件把 OBS 画面当摄像头 | **RTMP/SRT 推流 → 另一设备/云端混流再入会**；或 OBS 窗口本身被"捕获窗口"选中（窗口 Picker 审批后即可：A 应用把 OBS 预览窗当采集源，等效 v4l2loopback 的"窗口级回环"） |
| 本机录屏软件互采 | 全屏采集 + 窗口 Picker 已覆盖（应用间画面共享走系统 Picker 显式授权，安全模型更强） |
| 手机当 PC 摄像头（分布式） | 鸿蒙**反向**支持：系统跨设备摄像头可把手机相机给 PC 应用用（OBS 已可消费为 CameraDevice）——这是鸿蒙独有优势项，写进差异化叙事 |

> 关键洞察：窗口 Picker（CUSTOM_SCREEN_RECORDING ACL 获批后）恰好构成"穷人版虚拟摄像头"——目标应用捕获 OBS 的预览窗口即可拿到合成画面，且每次共享都有系统级用户授权，比桌面虚拟摄像头驱动的安全姿态更好。虚拟摄像头一项应从 ❌-A（可补齐）改判 ❌-B（平台模型差异）。

## 二、若未来出现官方能力，接入成本预估

harmony-vcodec 的 GPU 编码通路（EGL surface 输入）已就绪，届时只需新增一个 output 插件把编码前帧写入系统要求的 sink，预计 1~2 天。持续关注 API 26+ 的 Camera Kit 变更日志即可（`camera` 相关 release notes）。
