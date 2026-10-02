# OBS Studio 鸿蒙版 · 上架合规自查（AVSession 判定 + 隐私政策要点）

> 用途：W2"上架形态"的合规收口文档，与 `harmonyos-agc-permission-application.md`（受限权限申请）配套。
> 依据：HarmonyOS 官方文档（开发者知识库检索，2026-10-02），关键出处随文标注。
> 应用：com.obsproject.studio.harmony · PC/2in1 形态 · API 26

## 一、AVSession 接入判定：**不接入（有依据的豁免，非遗漏）**

### 官方约束范围（出处：AVSession Kit「后台播放」「应用接入 AVSession 场景介绍」）

- **必须接入**：后台播放媒体类业务——播放流类型为 `STREAM_USAGE_MUSIC / MOVIE / AUDIOBOOK / GAME` 的应用（音频应用、听书类、长视频、VoIP）。未接入而被检测到退后台播放时，系统**静音并冻结**该音频流。
- **可选接入**：游戏、直播等场景，"取决于应用是否有后台播放的使用诉求"。
- 约束的语义是**播放（playback）**，不是采集（capture）。采集类后台业务的管控通道是**长时任务（BackgroundTasks Kit）**。

### OBS 鸿蒙版的实际形态

| 行为 | 实现 | 是否属"播放" |
|---|---|---|
| 屏幕/窗口/相机采集 | AVScreenCapture / ImageReceiver（只读输入） | 否 |
| 麦克风 + 系统声音内录 | AudioCapturer / PlaybackCapture（采集侧） | 否 |
| 编码/推流/录制成片 | OH_VideoEncoder + librtmp / mp4 写文件 | 否 |
| 应用自身出声 | **无**——libobs 未启用音频回放后端（无 AudioRenderer 输出路径），预览面板无声画 | 不存在播放业务 |
| 录制完成后回看成片 | 属系统媒体库/播放器的行为，与本应用的采集会话无关 | 否 |

结论：**本应用没有任何"后台播放"语义的音频流**，AVSession 的强制接入条件不成立；可选项（播控中心展示"正在录制"卡片）留作 W3 差异化体验（实况窗方向），不阻塞上架。

后台存续能力全部走官方为采集类业务准备的通道：
- `audioRecording` 长时任务（`backgroundModes` 已在 module.json5 声明，`KEEP_BACKGROUND_RUNNING` 已声明）——真机实证息屏连续录制 544s（journey §5.6）。
- `TIMEOUT_SCREENOFF_DISABLE_LOCK`（normal/system_grant，声明即用）。

### 上架审核若问询，答复口径

"应用为采集端（录屏/推流工具），无媒体回放功能，不产生 STREAM_USAGE_MUSIC/MOVIE/AUDIOBOOK/GAME 播放流；按官方规范无需接入 AVSession。后台持续性通过 audioRecording 长时任务实现，任务仅在用户显式点击开始录制/直播时启动，停止即释放，期间系统展示常驻通知，用户可感知。"

## 二、隐私政策必备条目（上架前补齐隐私政策页）

以下每一项都对应应用的一个真实数据流，需在隐私政策中逐条披露：

1. **屏幕内容采集**（CUSTOM_SCREEN_CAPTURE，user_grant）
   - 采集范围：用户经系统共享 Picker 显式授权后的屏幕画面（全屏或指定窗口）。
   - 用途：本地录制 / RTMP 推流；推流目标服务器由用户自行配置，应用不内置任何上传端点。
   - 触发时机：仅在用户点击"开始录制/开始直播"之后；停止即释放采集会话。
2. **音频内录 + 麦克风**（MICROPHONE，user_grant）
   - 内录范围：系统播放声音（PlaybackCapture）；麦克风仅在用户添加"麦克风"源后采集。
   - 不上传、不落盘以外用途；混入录制/推流音轨。
3. **摄像头**（CAMERA，user_grant）
   - 仅在用户添加"相机"源时打开；帧数据只进应用内存渲染管线，不单独存储。
4. **本地存储**
   - 成片写入应用沙箱 `files/` 目录；用户可在设置面板改路径；卸载即清除。
   - 配置（分辨率/码率/推流地址）存应用 preferences，不出机。
5. **网络**（INTERNET，system_grant）
   - 出网仅两处：用户配置的 RTMP 推流地址；rtmp-services 服务列表远程更新（当前降级为本地内置包，实际不发远程请求）。
6. **键鼠可视化（INPUT_MONITORING，若获批 ACL）**
   - 仅生成按键/指针的叠加特效画面，不记录键值内容、不形成输入日志——**必须在隐私政策中明确声明与录键器的区别**。

## 三、权限声明自查表（module.json5 ↔ 实际用途一一对应）

| 已声明权限 | 用途 | 授权方式 | 状态 |
|---|---|---|---|
| CUSTOM_SCREEN_CAPTURE | 屏幕源 | user_grant（系统 Picker） | ✓ 已实现 |
| CUSTOM_SCREEN_RECORDING | 免重复隐私弹窗（PC/2in1） | 受限 ACL | 材料已备，待审批 |
| INPUT_MONITORING | 键鼠特效 | 受限 ACL | 材料已备，待审批 |
| CAMERA / MICROPHONE | 相机源 / 麦克风源 | user_grant | ✓ 已实现 |
| KEEP_BACKGROUND_RUNNING | 录制/推流长时任务 | system_grant | ✓ 已实现 |
| INTERNET | RTMP 推流 | system_grant | ✓ 已实现 |
| TIMEOUT_SCREENOFF_DISABLE_LOCK | 息屏继续录 | system_grant | ✓ 已实现 |

无冗余声明（申请列表与功能一一对应，符合"最小化"审核要求）。

## 四、其余上架项清单

- [x] 后台任务规范化（audioRecording 长时任务 + 引用计数）
- [x] 长时任务仅用户显式动作触发、常驻通知可感知（合规要点）
- [ ] 隐私政策页挂链（AGC 上架表单需 URL）——文案骨架见本文第二节
- [ ] 应用详情"能力说明"（录屏工具类目的描述规范）
- [x] CUSTOM_SCREEN_RECORDING / INPUT_MONITORING 申请文案（agc-permission-application.md）
- [ ] 版本隐私标签（AGC 表单按上文数据流逐项勾选）
