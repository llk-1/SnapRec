# SnapRec V0.1

SnapRec 是完全本地运行的 macOS 菜单栏录屏应用，使用 SwiftUI、AppKit、ScreenCaptureKit 和 AVFoundation，无第三方依赖、账号或后端。

最低系统 macOS 15.0。工程使用 Swift 6，支持 Apple Silicon 与 Intel 编译。本次环境的实际验证结果、未执行项和日志位置见 [验证记录](docs/VERIFICATION.md)。

## 打开与运行

1. 用 Xcode 16 或更新版本打开 `SnapRec.xcodeproj`。
2. 选择 **SnapRec** Scheme，运行目标选择 **My Mac**，按 `⌘R`。
3. 软件默认没有 Dock 图标或主窗口。点击屏幕顶部菜单栏的录屏圆圈图标操作；关闭设置、预览或控制窗口不会退出应用。
4. 设置入口在菜单栏 **Settings…**；退出入口是 **Quit SnapRec**。录制中退出会先停止并等待文件完成。

本地调试使用 **Sign to Run Locally**，不需要 Apple Developer 账号。若用自己的开发证书运行，可在 Signing & Capabilities 中选择自己的 Team。当前版本未公证、不包含安装器或 App Store 发布配置。

本次生成的通用 Debug 应用位于：

```text
build/Universal/Build/Products/Debug/SnapRec.app
```

可在 Finder 中打开，也可运行：

```sh
open build/Universal/Build/Products/Debug/SnapRec.app
```

若菜单栏项目较多或受刘海区域影响，可用下面的启动方式直接打开设置窗口：

```sh
open build/Universal/Build/Products/Debug/SnapRec.app --args --show-settings
```

## 录屏权限

- 全屏和区域录制首次使用时请求屏幕录制授权。系统设置 → 隐私与安全性 → 屏幕与系统音频录制，允许 SnapRec。部分系统需要退出并重新打开应用后才能生效。
- 窗口模式使用 Apple 系统内容选择器，尊重用户对所选内容的授权，不将全局录屏权限作为该模式的额外前置条件。
- 开启 **Record Microphone** 后，首次开始录制时请求麦克风权限。拒绝后可在系统设置 → 隐私与安全性 → 麦克风中修改。
- 应用配置了 `NSMicrophoneUsageDescription`、`NSAudioCaptureUsageDescription` 和 Hardened Runtime 音频输入 entitlement。不申请辅助功能或输入监控权限。
- 当前版本关闭 App Sandbox；保存目录通过原生目录选择对话框选择，保存路径持久化到 UserDefaults。不依赖沙箱外未经授权的 security-scoped 目录访问。
- 本地 ad-hoc 调试签名在重新编译或移动应用后可能需要重新授权。不要同时运行多个构建目录中的 SnapRec 副本。

## 录制方式

### 全屏

菜单栏选择 **Record Full Screen**，选择显示器，点击 **Record**。默认倒计时 3 秒。SnapRec 自身窗口及预览声音被排除，避免控制面板录进视频。

### 指定区域

选择 **Record Selected Area**，在任意可用显示器上拖出矩形。松开鼠标后进入倒计时；按 **Esc** 取消。选区至少 16 × 16 点，尺寸提示以像素显示。

每次选区限制在一块显示器内；支持不同显示器分别录制及 Retina 缩放，不支持跨显示器拼接。捕获区域使用显示器局部、左上角原点的点坐标，编码尺寸独立换算成像素。

### 指定窗口

选择 **Record Window**，在系统选择器中选择窗口。使用真正的独立窗口捕获，窗口被其他窗口遮挡时仍捕获目标窗口；关闭或最小化目标窗口可能导致系统停止更新或结束录制。

窗口模式的 **System Audio** 实际是所选窗口所属应用的声音，包括该应用的其他窗口和标签页；其他应用声音不包含在内。设置及录制控制中明确显示 **App Audio**。

### 停止与预览

点击浮动控制面板的停止按钮，或菜单栏 **Stop Recording**。**Finishing…** 表示仍在封装或保存，不代表已保存。只有原生完成回调、文件验证和目标目录发布全部完成后才显示成功。

SnapRec 的设置或预览窗口位于前台时，也可从 **Recording** 菜单操作，或按 `⌘.` 停止录制。该快捷键仅作用于前台 SnapRec，不是全局热键。

完成窗口提供内嵌播放器、**Open Video** 和 **Show in Finder**。录制异常时明确显示错误；能恢复的已完成视频会保留并提供 **Save Elsewhere…**。

## 声音与设置

在 **Settings… → Audio** 中选择：

| System Audio | Microphone | 输出内容 |
| --- | --- | --- |
| Off | Off | 仅画面 |
| On | Off | 画面与系统声音；窗口模式为目标应用声音 |
| Off | On | 画面与麦克风 |
| On | On | 画面、系统或应用声音与麦克风 |

麦克风支持 **System Default** 和系统枚举到的输入设备。拔掉已选设备时不会静默切换，开始录制前提示重新选择；点击 **Refresh Devices** 更新列表。使用耳机可以减少麦克风再次拾取扬声器声音造成的回声。V0.1 没有回声消除或降噪。

视频支持 Original / 1080p / 720p、30 / 60 FPS、显示光标开关。1080p 和 720p 分别在 1920 × 1080、1280 × 720 范围内等比缩小，不放大较小选区；H.264 尺寸取偶数。Original 的奇数像素尺寸会向下取偶数。部分超大原始分辨率受系统 H.264 编码器限制，可选择 1080p。

倒计时可选择 Off / 3 秒 / 5 秒，支持自定义保存目录及完成后打开文件夹。所有设置持久化；录制开始时冻结一份配置，录制中修改设置只影响下一次录制。

帧率是目标采集更新上限。静止画面可能减少帧更新，不代表录制故障。输出为 SDR H.264 MP4，使用系统编码与封装。

## 输出文件与恢复

默认目录：`~/Movies/SnapRec/`。文件名示例：`SnapRec_2026-10-12_14-30-25.mp4`；同名文件使用 `_1`、`_2` 等后缀，避免覆盖。

临时录制目录：`~/Library/Application Support/SnapRec/InProgress/`。

- 视频完成后先验证可播放性、视频轨、时长及预期音频轨，再复制到目标目录的隐藏暂存文件并发布正式文件。
- 成功发布后删除源临时文件；复制或磁盘写入失败时保留源文件，错误窗口提供另存入口。
- 启动时查找可恢复视频，在菜单栏提供 **Open Unsaved Recordings**。只自动清理超过一分钟的零字节录制残留；不将暂时无法读取的非空文件当作损坏文件删除。
- 录制前要求临时卷和保存卷至少有 64 MB 可用空间，这只是启动条件，不保证长录制所需容量。运行中的磁盘写满由录制器错误和恢复流程处理。

## 编译与测试

工程和共享 Scheme 已包含在目录中，打开 Xcode 不需要运行生成脚本。工程生成脚本仅用于以后增加源文件时同步项目引用。

当前机器默认开发目录指向 Command Line Tools，命令行构建需要指定完整 Xcode：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project SnapRec.xcodeproj -scheme SnapRec -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath build/Universal \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

xcodebuild -project SnapRec.xcodeproj -scheme SnapRec -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

常规测试不申请权限或开始录屏。真实采集测试默认跳过；仅在明确启用且测试进程已经获得授权时执行，不自动修改系统权限：

```sh
python3 scripts/generate_test_tone.py
# 用 QuickTime Player 打开自制测试音，点击播放，再运行下面的测试命令。
open -a 'QuickTime Player' build/LiveCaptures/test-tone.wav

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project SnapRec.xcodeproj -scheme SnapRec -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  SNAPREC_LIVE_CAPTURE_TESTS=1 test
```

真实测试输出保留在 `build/LiveCaptures/`。运行这些测试会录制短暂的屏幕和麦克风内容，选择合适的测试环境。不要把“跳过”当作通过。

Xcode 测试宿主与直接启动的应用可能具有不同的屏幕授权状态。本机测试宿主没有授权，真实 XCTest 项因此跳过；直接启动的 Debug 应用已经获得授权，实际采集使用下面的应用进程检查完成：

```sh
# 先退出已有 SnapRec 副本，并确认 QuickTime 中的测试音正在播放。
build/Universal/Build/Products/Debug/SnapRec.app/Contents/MacOS/SnapRec \
  --capture-smoke-test "$PWD/build/SmokeCaptures" \
  --ui-smoke-test --smoke-report "$PWD/build/ui-smoke.json"
```

此 Debug 专用入口连续执行 6 次约 2 秒录制，使用生产录制协调器、引擎和保存服务；验证音频解码、Retina 区域尺寸、被遮挡窗口及完成预览。已有授权不足时跳过，不自动授予权限。结果写入 `build/native-smoke.json`，视频保存在 `build/SmokeCaptures/`；复跑会更新 JSON，视频仍按重名规则保留。应用检查结束后继续运行，可正常退出。

测试音应由独立应用播放。全屏/区域录制排除 SnapRec 自身音频；某些调试启动方式下，与 SnapRec 共用负责进程的 `afplay` 也可能被排除。

测试包含状态及会话隔离、重复开始/停止、取消倒计时、权限拒绝、开始过程中的停止与取消、异常断流、配置冻结、真实 H.264 文件验证、缺失音轨提示、重名防覆盖、保存失败恢复、设置持久化及原生预览渲染。最终常规 XCTest 为 24 项通过、6 项真实采集测试跳过、0 失败；应用进程的 7 项检查另行全部通过。音频非零采样不等于人声或双路来源试听通过，详见验证记录。

## 常见问题

- **菜单栏有图标但没有主窗口**：正常；这是菜单栏应用。通过图标打开设置和录制操作。
- **授权后仍无法录制**：退出并重新打开同一个应用副本，检查系统设置中的授权；重新编译后可能需要重新授权。
- **Original 启动失败**：尝试 1080p；超大画面、系统编码能力、显示器断开或权限变化都可能导致失败。
- **系统声音为空**：确认 System Audio 已开启、应用确实在播放声音。窗口模式只包含目标应用声音。DRM 和隐私保护内容可能黑屏或静音，SnapRec 不绕过保护。
- **麦克风为空**：检查麦克风授权、输入设备和硬件静音，重新选择 System Default 或连接的设备。
- **Save Elsewhere 后视频没有原本期待的声音**：恢复入口优先保留可播放画面；缺失音轨的录制会明确提示，另存无法补回未采集的声音。
- **目标目录不可用或磁盘已满**：选择可写目录并释放空间；保留的视频可在恢复目录中找到。
- **录制窗口被最小化或关闭**：窗口画面可能暂停更新或由系统结束录制。异常结束会标注中断，并尝试保存已完成内容。
- **在受限执行沙箱中 Swift 宏编译失败**：Observation 宏插件可能无法启动；在正常本地终端或允许 Xcode 编译服务运行的环境中构建。

## 当前边界与后续方向

暂不包含暂停/恢复、摄像头、视频编辑、GIF、点击动画、智能缩放、云存储或账号功能。跨显示器拼接、长时间压力测试、macOS 15 与 Intel 实机验证、声音试听和原生选择器交互验收见验证记录。

录制引擎、状态协调、文件服务与 UI 已分离，后续特效或编辑应在现有职责边界上扩展，不影响当前原生录制链路。

API 依据：[ScreenCaptureKit 录制与麦克风](https://developer.apple.com/videos/play/wwdc2024/10088/)、[独立窗口与音频过滤](https://developer.apple.com/videos/play/wwdc2022/10155/)、[系统内容选择器](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker)。所有生产录制调用以 macOS 15 API 为基线，不调用 macOS 27 的显式混音配置。
