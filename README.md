# IOS_BL616

全新 Objective-C / UIKit iOS 客户端，对接 BouffaloSDK 的
`examples/solution/solution_bl616/image_transmission` 示例。
使用 [CocoaAsyncSocket](https://github.com/robbiehanson/CocoaAsyncSocket) 的
`GCDAsyncUdpSocket`，通过 Swift Package Manager 固定依赖版本 **7.6.5**。

## 当前功能

- 仅支持左右横屏，视频按原始比例全屏显示，隐藏系统状态栏。
- 默认隐藏设置和状态面板；轻点画面或右上角控制按钮展开，点关闭按钮或面板外画面收起。
- 开始出图后自动收起面板；图传超时或连接失败时自动展开，显示原因并保留启停操作。
- 控制面板提供连接 UDP、断开 UDP、开启图传、关闭图传和发送串口测试。
- 状态区显示连接、播放和失败原因。App 进入后台会断开 UDP。

UDP 本身没有握手。界面“UDP 已就绪”只说明本地 socket 已准备好；
收到并解码完整图像后进入图传状态。STOP 没有设备应答，发送成功不能证明设备已经停止。

Wi-Fi 6 由手机、摄像板及无线网络协商，App 的 UDP 接口不能强制启用 802.11ax。
连接 B 固件并开始出图后，可以在控制面板点击「发送串口测试（B 固件）」。
再次点击停止附带中立数据，画面继续播放。串口输出由板端完成，包格式见
[控制测试说明](docs/HIBOOSTER.md#b-固件-tx-中立测试)。

## 使用方法

1. 在 Mac 上克隆仓库，用 **Xcode 15 或更新版本**打开 `BL616Camera.xcodeproj`。
2. 等待 SPM 下载 CocoaAsyncSocket，选择 `BL616Camera` scheme。
3. 在 Signing & Capabilities 中选择自己的 Team；需要时修改 Bundle Identifier。
4. 选择 iPhone 真机运行，最低 iOS 15.0；允许 App 访问“本地网络”。
5. 在系统 Wi-Fi 设置中连接摄像板所在网络，确保板端摄像头和 HiBooster sender 已运行。
6. App 自动横屏，点击右上角控制按钮，填入设备 IP、设备端口、本地端口，点击“连接 UDP”，再点击“开启图传”。
7. 出图后面板自动收起；需要操作时轻点画面或右上角按钮，点击“关闭图传”停止画面，或点击“断开 UDP”结束会话。

| 设置 | 初始值 | 说明 |
| --- | --- | --- |
| 设备 IP | `192.168.169.1` | 仅适用于板端已开启 SDK 默认 AP；STA 模式应填写串口日志中的实际地址 |
| 设备端口 | `8801` | 当前测试摄像板接收 START、STOP 和 ACK 的端口 |
| 本地端口 | `1235` | 手机监听图像的端口；START、STOP、ACK 也从此端口发送 |

当前默认值用于改端口摄像板测试，START 仍为四字节十六进制 `EF 00 04 00`。
更新安装后，已保存的旧设备端口 `8800` 和本地端口 `9000` 会各自迁移一次为 `8801` 和 `1235`；
其他自定义值保留，端口仍可在界面修改，本地端口填 `0` 可自动分配。
原 SDK 示例使用设备端口 `8800`，测试原板时可手动改回。
客户端绑定手机 `1235` 接收数据，只校验来源设备 IP，允许板端图像使用不同的发送源端口。
START、STOP、ACK 均从同一个手机 socket 发送到所填设备端口（当前默认 `8801`）。

SDK 示例不会自动创建 AP 或连接路由器，须先在板端完成网络配置。
手机发送 START 的源 IP 和源端口就是摄像板的图像发送目标，不能另开一个接收 socket。
如果本地网络权限曾被拒绝，请在 iOS 设置中允许后重新连接。

### UDP 助手有数据、App 没有画面时

1. 先关闭 UDP 助手的监听，避免占用手机 `1235`；确认手机仍连接摄像板 Wi-Fi，并单独允许本 App 访问本地网络。
2. 点击“连接 UDP”再点击“开启图传”，根据超时提示检查设备地址、分片格式和 ACK 路由。

接入已运行的摄像板时，首个有效帧序号可以大于 1。

## 接入接口

五个操作声明在 [HBUDPClient.h](BL616Camera/Network/HBUDPClient.h)，实现见 [HBUDPClient.m](BL616Camera/Network/HBUDPClient.m)。

| 操作 | Objective-C 接口 | 用法 |
| --- | --- | --- |
| 连接 UDP | `connectToHost:remotePort:localPort:` | 设置板端 IPv4 和端口，绑定本地端口。收到 `HBClientReady` 后可开启图传。 |
| 断开 UDP | `disconnect` | 请求停止图传，关闭 socket 并释放端口。 |
| 开启图传 | `startVideo` | 请求板端推图并开始接收。 |
| 关闭图传 | `stopVideo` | 请求停止推图，可用同一 UDP 会话再次开启。 |
| 发送串口数据 | `setTXControlData:` | 播放时传入 1–62 字节，通过后续 B 格式 ACK 携带。传 `nil` 停止携带。 |

设置客户端的 `delegate` 后，在主线程的 `client:didReceiveImage:generation:`
接收已拼接、解码的 `UIImage`。可以直接把它交给显示层。状态回调中的
`generation` 变化时，显示层可以清除上一轮画面。

```objc
- (void)client:(HBUDPClient *)client didReceiveImage:(UIImage *)image generation:(uint64_t)generation {
    self.imageView.image = image;
}
```

发送串口数据的调用示例见 [B 固件控制测试](docs/HIBOOSTER.md#b-固件-tx-中立测试)。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `BL616Camera/Core/HBProtocol.c` | C 语言分片解析、边界检查、重组、ACK 编码 |
| `BL616Camera/Network/HBUDPClient.m` | UDP 会话、启停指令、串口控制、后台解码调度和主线程回调 |
| `BL616Camera/Video/JPEGRenderer.m` | 用 ImageIO 将完整 JPEG 解码为 UIImage |
| `BL616Camera/UI/CameraViewController.m` | 按钮调用示例、状态反馈及 UIImage 显示示例 |
| `docs/HIBOOSTER.md` | 当前 SDK 库对应的线上协议与兼容性边界 |
| `tests/test_protocol.c` | 可在 Linux/macOS 运行的协议测试 |
| `BL616CameraTests/UDPClientTests.m` | 模拟器 UDP 回环及 JPEG 解码测试 |

## 验证

Linux / WSL / macOS（需要 C 编译器和 Python 3）：

```bash
bash tools/test_core.sh
```

覆盖 START/STOP 和 ACK 字节、分片乱序和重复、完成后的重复 ACK、超时、
缓存上限、最大帧、错误长度和畸形数据，启用 AddressSanitizer / UndefinedBehaviorSanitizer。

Mac 上检查无签名编译：

```bash
bash tools/check_macos.sh
```

GitHub Actions 会运行协议检查和 iOS 模拟器 XCTest，包括连接、START、JPEG 接收、
完成 ACK、STOP、断开后的端口释放以及取消未发出的 START。
另覆盖图像来源端口与指令端口不同、首帧序号大于 1，畸形数据的开启超时，以及 UIImage 主线程回调和控制数据更新。
Xcode 工程由 `tools/generate_project.py` 生成；增删源文件后运行该脚本，提交生成结果。

AppIcon 使用黑白 Power Craze 车标，已配置 iPhone、iPad 和 App Store 所需尺寸。
资源位于 `BL616Camera/Resources/Assets.xcassets/AppIcon.appiconset`，由工程资源阶段编译。
更换图标时，安装 Pillow 后运行 `python3 tools/generate_app_icons.py /path/to/square-icon.png`，
并提交生成的 PNG 和 Contents.json；`python3 tools/generate_app_icons.py --check` 可校验尺寸与不透明格式。

这些测试使用协议夹具和回环模拟设备。与真实 BL616 的互通、帧率、延迟、弱信号表现及
Wi-Fi 6 链路仍需要真机联调；协议来自当前 SDK 库的实现核对，详见协议文档。
