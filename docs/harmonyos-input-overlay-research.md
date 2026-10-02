# OBS 鸿蒙版 · 键鼠可视化叠加层调研（INPUT_MONITORING 消费路径）

> 背景：调试 profile 的 allowed-acls 已含 `ohos.permission.INPUT_MONITORING`，直觉上"键鼠可视化"（录教程神器）解锁了。本调研回答：第三方应用到底能不能消费这个权限。
> 依据：SDK API 声明文件逐字节检索 + 官方文档（开发者知识库，2026-10-03），出处随文标注。

## 结论：**第三方无全局输入消费 API，该特性经系统路径不可行；自研路径半可行（降级方案见后）**

### 证据链

1. **权限文档语义是"系统渲染"**：官方《受限开放权限》对 INPUT_MONITORING 的可申请场景描述为"应用需要录屏，且**录屏过程中有显示**键盘按键事件/鼠标指针效果/触摸效果"、"应用需要共享桌面"——描述的是**系统录屏/共享管线**具备该能力，权限是入场券；但**没有任何公开的第三方 API 把"已获授权的全局输入事件"交给应用**。
2. **SDK 全量检索为空**：`ohos.permission.INPUT_MONITORING` 在 openharmony/hms 两套 SDK 的 `.d.ts`/头文件中仅出现在 `permissions.d.ts` 的权限名枚举里，**零个 API 声明引用它**（grep 全量验证）。
3. **AVScreenCapture NDK 无特效注入**：接口全集 46 个函数（native_avscreen_capture.h）逐个核对——有 `ShowCursor`（光标是否入画，我们已用）、`SetCaptureAreaHighlight`（捕获区域高亮）、`SkipPrivacyMode` 等，**没有任何按键/点击特效开关**。
4. **ArkTS 录屏配置无特效字段**：ScreenRecord 配置结构中无 showKey/特效项。
5. **`addLocalInputEventMonitor`（API 26）不是它**：SDK 原文明确 "Local … only valid within the current UIContext"——只监听**本应用自己窗口**的事件、无需权限，与"全局输入监控"无关。

### 为什么平台这么做（推断，与整体安全模型自洽）

全局键鼠监听 = 录键器能力。鸿蒙把 INPUT_MONITORING 的渲染闭环留在系统进程内（应用声明场景→系统录屏管线自己画特效），不给第三方原始事件流，和"禁注入、禁全局钩子"（❌-B 表既有条目）是同一安全姿态。

### 可行的降级方案（自研，成本从低到高）

| 方案 | 原理 | 覆盖 | 局限 |
|---|---|---|---|
| A. 光标轨迹已有 | `OH_AVScreenCapture_ShowCursor(true)` 已实现，光标天然入画 | 鼠标位置 | 无点击特效 |
| B. 应用内自绘 | 预览/捕获窗口获焦时用 `addLocalInputEventMonitor` 收本窗事件，画特效层进场景 | 用户在 OBS 窗口内操作时 | 录其他应用时失效（事件不到达） |
| C. 系统录屏互补 | 引导用户用系统录屏（其自带键鼠特效，正是该权限的官方场景）做"演示层"，OBS 做"合成层" | — | 产品叙事，非代码 |

**建议**：按 ❌-B 归档（平台模型差异），叙事引用"系统录屏自带键鼠特效（INPUT_MONITORING 官方场景）+ OBS 负责合成/推流"的组合；方案 B 作为彩蛋级特性排期，不做也不亏。
