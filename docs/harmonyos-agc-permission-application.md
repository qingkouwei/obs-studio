# OBS Studio 鸿蒙版 · AGC 受限权限申请材料

> 用途：AppGallery Connect 受限开放权限申请 + 上架合规说明。
> 应用：com.obsproject.studio.harmony（OBS Studio HarmonyOS 版）
> 目标形态：PC/2in1（含平板电脑模式），API 26 / HarmonyOS 7.0.0+
> 权限事实全部经官方文档核实（开发者知识库检索，2026-10-02），出处标注在各节。

## 一、权限总览与分级

| 权限 | 级别 | 授权方式 | 是否需 ACL 申请 | 用途一句话 |
|---|---|---|---|---|
| ohos.permission.CUSTOM_SCREEN_CAPTURE | normal | user_grant | 否，声明+弹窗即可 | 屏幕采集为视频源（API 14+，21+ 起支持手机） |
| **ohos.permission.CUSTOM_SCREEN_RECORDING** | system_basic | 受限开放 | **是（AGC 申请，约 3 个工作日）** | PC/2in1 录屏时不再弹系统隐私告警窗（API 22+） |
| **ohos.permission.INPUT_MONITORING** | system_basic | 受限开放 | **是（AGC 申请）** | 录屏/共享桌面时显示按键与指针效果（API 26.0.0 起全设备可申请） |
| ohos.permission.TIMEOUT_SCREENOFF_DISABLE_LOCK | normal | system_grant | 否，声明即可（API 21+） | 超时息屏不锁屏，保障"息屏继续录" |
| ohos.permission.CAMERA | normal | user_grant | 否 | 摄像头源 |
| ohos.permission.MICROPHONE | normal | user_grant | 否 | 麦克风源 |
| ohos.permission.KEEP_BACKGROUND_RUNNING | normal | system_grant | 否 | 长时任务：切后台持续录制/推流 |
| ohos.permission.INTERNET | normal | system_grant | 否 | RTMP 推流、服务列表更新 |

需 ACL 审批的只有两项：**CUSTOM_SCREEN_RECORDING** 与 **INPUT_MONITORING**。以下分节给出申请场景描述（可直接粘贴 AGC 表单）与依据。

## 二、CUSTOM_SCREEN_RECORDING 申请

**权限语义（官方）**：从 API 22 开始，在 PC/2in1 设备上对应用进行录屏时，可通过申请本权限实现在录制屏幕时**不再弹出系统隐私告警弹窗**。（出处：AVScreenCapture 开发指导 / C 基础流程）

**申请场景描述（表单文案）**：

> 本应用为开源直播/录屏软件 OBS Studio 的 HarmonyOS 版（PC/2in1 形态），核心功能是把本机屏幕作为持续视频源进行本地录制与 RTMP 直播推流。用户已在本应用内主动点击"开始录制/开始直播"并经由系统"选择共享内容"Picker 完成显式授权；系统级隐私告警弹窗与用户动作重复，且直播场景下弹窗会打断推流会话并遮挡共享画面。申请本权限用于消除重复弹窗，保障直播/录制会话连续性。应用首次采集仍会触发系统共享确认 Picker（user_grant 语义保留），不申请静默采集。

**合规要点**：
- 采集启动路径保留系统 Picker 确认（PC/2in1 形态 `OH_CAPTURE_SPECIFIED_SCREEN` 自带"选择共享内容"确认，实测存在且不可绕过）；
- 采集内容仅进入用户主动发起的录制文件/推流会话，无后台静默采集逻辑；
- 隐私政策中明示采集范围、存储位置（应用沙箱 files 目录）、推流目标由用户配置。

## 三、INPUT_MONITORING 申请

**权限语义（官方）**：允许应用监听输入事件。可申请的特殊场景包括：**应用需要录屏，且录屏过程中有显示键盘按键事件，或是显示鼠标指针效果/触摸效果的功能；应用需要共享桌面**。（出处：受限开放权限清单）API 26.0.0 起支持全设备申请。

**申请场景描述（表单文案）**：

> 本应用为直播/录屏软件（OBS Studio HarmonyOS 版），PC/2in1 形态下将桌面共享给直播观众是核心场景。为使观众能看到主播的鼠标指针轨迹与点击反馈（教程、演示、游戏直播的通用需求），需要在录制/推流画面中叠加指针效果层，符合本权限"录屏过程中显示鼠标指针效果/触摸效果"的开放场景。监听数据仅用于在应用内渲染指针/按键可视化叠加层，不落盘、不外传输入内容，不读取文本输入框内容。

**合规要点**：
- 用途限定为可视化叠加（指针轨迹/点击高亮），非输入捕获；
- 不记录键盘文本内容（区别于录键器，需在隐私政策中明确声明）；
- 若首版不做指针叠加，可暂缓申请，降低审核面——**建议随功能申请，不预先囤权限**。

## 四、TIMEOUT_SCREENOFF_DISABLE_LOCK（无需 ACL，直接声明）

**权限语义（官方）**：允许应用使能超时息屏不锁屏功能。设备超时息屏后默认锁屏，获取该权限后应用超时息屏不进入锁屏界面。（normal 级，system_grant，起始版本 21）

**价值**：官方录屏文档明确"支持在熄屏但不锁屏的情况下保持录制"依赖此权限——**这正好解决本项目遗留问题"息屏继续录"**（此前实测仅验证了"切后台亮屏继续录"221s 无 ANR）。接入计划见工程文档。

## 五、申请操作路径备忘

1. **调试阶段**：DevEco Studio 自动签名会代为向 AGC 申请受限权限（6.0.2 Beta1 起支持 CUSTOM_SCREEN_RECORDING 等）；命令行路线用 `devecocli signature generate` 时，profile 的 allowed-acls 需包含已批准的 ACL（本项目调试 profile 已含 CUSTOM_SCREEN_RECORDING + INPUT_MONITORING，真机验证通过）。
2. **发布阶段**：申请发布证书 → 申请发布 Profile 时**手动提交受限权限申请**（附场景描述）→ 审核约 3 个工作日 → 下载含 ACL 的发布 profile → 配置签名。API 26.0.0 Beta1 起发布流程已简化，但受限 ACL 仍需显式申请。
3. **module.json5**：两项受限权限与 reason 字符串已声明（reason_screen_recording / reason_input_monitoring，中文已译）。

## 六、审核风险自查（对照常见驳回原因）

| 常见驳回 | 本项目状态 |
|---|---|
| 场景描述与权限开放场景不匹配 | ✅ 逐字对齐官方开放场景文案（"录屏+指针效果""共享桌面"） |
| 无对应功能即囤权限 | ⚠️ INPUT_MONITORING 若首版无指针叠加，建议随功能提交 |
| 缺少用户授权交互（静默采集） | ✅ 保留系统 Picker + user_grant 弹窗双确认 |
| 隐私政策未说明采集范围 | ⚠️ 上架前需补隐私政策页（含屏幕内容、音频内录、输入可视化三项说明） |
| 长时任务类型与业务不符 | ✅ KEEP_BACKGROUND_RUNNING 配合录屏类长时任务声明（W2 规范化项） |

## 七、真机验证记录（调试 profile）

- 2026-10-01：调试 profile allowed-acls 含 CUSTOM_SCREEN_RECORDING + INPUT_MONITORING，`OH_AVScreenCapture_Init/Start` 真机通过，Picker 确认后 30fps 帧流正常，录制成片 h264+aac、RTMP 推流 13544 帧零中断——**两项受限权限的功能路径已验证可用**；发布 profile 的 ACL 申请为纯流程工作。
