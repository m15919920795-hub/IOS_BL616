# IOS_BL616

全新 Objective-C / UIKit iOS 客户端，对接 BouffaloSDK 的
`examples/solution/solution_bl616/image_transmission` 示例。
使用 [CocoaAsyncSocket](https://github.com/robbiehanson/CocoaAsyncSocket) 的
`GCDAsyncUdpSocket`，通过 Swift Package Manager 固定依赖版本 **7.6.5**。

## 当前功能

- 连接 UDP：绑定本地端口，设置摄像板 IPv4 地址和目标端口，开始接收。
- 断开 UDP：发送 STOP，关闭 socket、释放端口并清除接收和显示队列。
- 开启图传：发送 START，重组 HiBooster JPEG 分片，发送接收位图和完成 ACK，实时显示图像。
- 关闭图传：发送 STOP，清除画面及分片，保留 UDP 会话，支持再次开启。
- 显示本地端口、原始 UDP 收包/字节数、来源端口、首包前 64 字节、有效分片和完整帧统计；进入后台自动断开。

UDP 本身没有握手。界面“UDP 会话就绪”只说明本地 socket 已准备好；
收到完整图像才进入图传状态。STOP 没有设备应答，发送成功不能证明设备已经停止。

Wi-Fi 6 由手机、摄像板及无线网络协商，App 的 UDP 接口不能强制启用 802.11ax。
本阶段只实现 UDP 图传，不包含小汽车控制透传、OTA 或 LCD 功能。

## 使用方法

1. 在 Mac 上克隆仓库，用 **Xcode 15 或更新版本**打开 `BL616Camera.xcodeproj`。
2. 等待 SPM 下载 CocoaAsyncSocket，选择 `BL616Camera` scheme。
3. 在 Signing & Capabilities 中选择自己的 Team；需要时修改 Bundle Identifier。
4. 选择 iPhone 真机运行，最低 iOS 15.0；允许 App 访问“本地网络”。
5. 在系统 Wi-Fi 设置中连接摄像板所在网络，确保板端摄像头和 HiBooster sender 已运行。
6. 填入设备 IP、设备端口、本地端口，点击“连接 UDP”，再点击“开启图传”。
7. 点击“关闭图传”停止画面，或点击“断开 UDP”结束会话。

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
2. 点击“连接 UDP”再点击“开启图传”，观察“UDP 收包”和“字节”。这两个统计在协议解析前累计，不代表有效图像。
3. 收包为 0 时，检查网络、设备 IP、本地网络权限、监听端口和 START 是否送达。
4. 收包增长但无效分片增长时，查看“最近来源”和“首包”；截图应包含这两项，以核对是否仍为本文档的 HiBooster 分片格式。
5. 有效分片增长但完整帧为 0 时，检查分片是否齐全及 ACK 路由；当前 ACK 发往配置的设备端口。

接入已运行的摄像板时，首个有效帧序号可以大于 1，客户端不再要求从序号 1 开始。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `BL616Camera/Core/HBProtocol.c` | C 语言分片解析、边界检查、重组、ACK 编码 |
| `BL616Camera/Network/HBUDPClient.m` | 单 socket、串行状态机、启停指令和超时处理 |
| `BL616Camera/Video/JPEGRenderer.m` | 后台 ImageIO 解码，只保留最新待显示帧 |
| `BL616Camera/UI/CameraViewController.m` | IP/端口输入、四个功能按钮和实时预览 |
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
另覆盖图像来源端口与指令端口不同、首帧序号大于 1，以及畸形数据的原始收包诊断。
Xcode 工程由 `tools/generate_project.py` 生成；增删源文件后运行该脚本，提交生成结果。

这些测试使用协议夹具和回环模拟设备。与真实 BL616 的互通、帧率、延迟、弱信号表现及
Wi-Fi 6 链路仍需要真机联调；协议来自当前 SDK 库的实现核对，详见协议文档。
