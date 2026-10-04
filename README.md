# tinyddc

一个小型、按需运行的 macOS 命令行工具：列出外接显示器，用 DDC/CI 的 VCP `0x60` 切换输入源，然后退出。原生 Objective-C 实现，直接使用 Apple Silicon 的 IOAVService 接口；无需 BetterDisplay、m1ddc、后台服务或第三方运行时。

## 构建

需要 Apple Silicon Mac、macOS 12 或更高版本，以及 Apple Command Line Tools 中的 `clang` 和 `make`：

```sh
xcode-select --install  # 已安装 Command Line Tools 时跳过
make
./tinyddc --help
```

构建只链接系统 Foundation、CoreGraphics、IOKit 框架；无下载依赖。输出为单个 arm64 可执行文件。可直接在当前目录运行，或按需安装：

```sh
make install PREFIX="$HOME/.local"
```

安装到其他目录可设置 `PREFIX`。卸载只需删除对应的 `bin/tinyddc` 文件。项目不会创建任何登录项、配置文件、监听进程或快捷键。

## 使用

先列出当前在线的外接显示器（内置屏幕被排除）：

```sh
./tinyddc list
./tinyddc list --json
```

输出包括名称、当前列表编号、macOS 显示器 UUID 和传输状态。`list` 只读取 CoreGraphics 和 I/O Registry，不发送 DDC 命令。`available (DDC response untested)` 表示找到了唯一的外接 DCP 传输和所需 API，并不证明扩展坞或显示器接受 DDC。

每次控制都必须明确选择目标。脚本推荐使用 `list` 输出的 UUID：

```sh
./tinyddc input dp --display <UUID> --dry-run
./tinyddc input dp --display <UUID>
./tinyddc input hdmi1 --display <UUID>
```

`<UUID>` 是占位符，需要替换成实际 UUID；不要原样输入尖括号。也可用列表编号选择：

```sh
./tinyddc input dp --index 1 --dry-run
./tinyddc input 15 --index 1
./tinyddc input 0x11 --index 1
```

`--dry-run` 会展示目标与 DDC 报文字节，随后退出，不打开 IOAVService、不发送任何 DDC 命令。正式 `input` 命令会立即发送 Set VCP，可能导致屏幕离开当前 Mac 的输入。没有默认显示器；无匹配、重复 UUID、错误参数或不唯一的传输都会失败。编号只对当前一次 `list` 有效，拔插或拓扑变化后可能改变。

支持以下输入别名，也允许十进制或 `0x` 十六进制的 `1..65535` 数值：

| 别名 | 数值 | 常见含义 |
| --- | ---: | --- |
| `dp` | 15 | DisplayPort 1 |
| `dp2` | 16 | DisplayPort 2 |
| `hdmi1` | 17 | HDMI 1 |
| `hdmi2` | 18 | HDMI 2 |
| `usbc` | 27 | USB-C |

显示器可能使用不同的输入编号，需以对应型号的实际行为为准。对于使用上述常规映射的 JQ24F260L，目标 DP 和 HDMI1 分别是 `15`、`17`。

可选的当前输入查询：

```sh
./tinyddc get-input --display <UUID>
```

`get-input` 会发送 Get VCP 查询（写入查询报文，再读取应答），不会发送 Set VCP 或改变输入。它校验应答长度、帧头、结果码、VCP 与 XOR 校验和。某些显示器支持切换却不支持查询，查询失败不等于切换不可用。

退出码：`0` 成功；`1` 显示器、传输或 DDC 错误；`2` 命令参数错误。输入切换的成功仅代表底层接受了传输，不代表显示器已完成切换。为兼容 IOAVService，写入重复两次；首次写入可能已切走输入，导致第二次报错，此时工具会明确提示这种可能性。不要据此在自动化中无限重试。

## 限制

- 仅支持原生 Apple Silicon，Intel Mac 和 Rosetta 构建不支持。
- IOAVService 和 CoreDisplay 是 Apple 私有 API；macOS 更新可能改变接口或 I/O Registry 布局。工具在运行时查找符号，缺失时报告错误。
- 采用 m1ddc / AppleSiliconDDC 的 framebuffer → DCPAVServiceProxy 枚举模式，以 CoreDisplay 的 IODisplayLocation 精确匹配 framebuffer registry ID；对应段必须只有一个外接 proxy。无法明确映射的多屏、虚拟显示器或新拓扑会拒绝控制。
- 默认使用 IOAVService DDC 地址 `0x37`；检测到 `AppleDCPMCDP29XX` provider 时使用上游实现中的 `0xB7` 路由。MCDP 路由没有在本项目中完成硬件验证；这并不保证所有 Mac 内置 HDMI 或所有转接器可用。
- USB-C → HDMI、扩展坞、KVM、线材和显示器必须共同透传 DDC/CI；显示器菜单中也需开启 DDC/CI。能显示画面或读到 EDID，不能证明可以发送 DDC。
- 只列出 macOS 当前在线的外接显示器。切到另一台电脑后，Mac 可能看不到该显示器或无法继续发送 DDC；这种情况下，从 Mac 切回并无保证。
- UUID 比当前列表编号更适合自动化，但改接端口、转接器或 macOS 显示器身份变化后仍可能改变，需重新 `list`。重复标识被拒绝。
- 运行在无法访问 WindowServer 的沙箱或远程会话中时，CoreGraphics 可能返回空列表；请在本机已登录的桌面终端运行。
- 不实现亮度、音量、厂商专用 VCP、网络远程控制或 Deskflow 联动。外部脚本可以按需调用本工具。

## 验证与来源

```sh
make test
```

测试检查 DP/HDMI 报文、16 位字节顺序、零校验字节、查询报文、错误应答与参数拒绝路径；不会访问显示器或发送 DDC。开发时已在 M3 MacBook Air 的 macOS 15.1.1 上编译，并通过只读 `list` 确认经 USB-C 扩展坞 HDMI 连接的 JQ24F260L 可映射到 DCP 传输。`--dry-run` 已验证选择目标和 DP 报文。初版在显示 Mac 画面时，`get-input` 未获得合法 VCP 应答，而 BetterDisplay 对照查询返回 HDMI1 值 `17`，因此初版查询存在实际兼容问题。当前版本已修正 Get VCP 校验和与 IOAVService 读偏移，通过构建和报文测试；**修正版尚待显示 Mac 画面时复验，也尚未执行实际输入切换。** 显示另一台电脑画面时收到的 null reply 或残留尾部数值均不作为有效输入源。

底层 API 签名、注册表键、传输地址、等待/重复写入模式和 DDC 报文约定参考并改编自以下 MIT 项目；命令解析、目标选择、运行时 API 加载与项目结构为本项目实现：

- [waydabber/m1ddc](https://github.com/waydabber/m1ddc)，尤其是 `headers/ioregistry.h`、`headers/i2c.h`、`sources/ioregistry.m`、`sources/i2c.m`。
- [waydabber/AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC)，尤其是 `AppleSiliconDDC.swift` 和 `Bridging-Header.h`。
- [MonitorControl](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift) 的当前 `Arm64DDC.swift`，用于核对 IOAVService 读取的 `offset=0` 语义。

Get VCP 请求的 XOR 校验覆盖目的地址 `0x6E`、主机源地址 `0x51` 和报文内容。`0x60` 查询因此发送 `82 01 60 DC`（源字节由 IOAVService 单独传入）；读应答使用 `offset=0`，并继续严格拒绝 null reply、错误帧头和错误校验和。

这些项目均不是运行或编译依赖，本工具不会启动它们。归属与 MIT 许可全文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；本项目采用 [MIT 许可](LICENSE)。
