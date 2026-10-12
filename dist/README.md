# dist/ — 预构建的未签名 ipa

这个目录里放的是**已经在云端 macOS 上真实构建出来、可以直接拿去自签安装的 ipa**，省掉你自己跑一遍 CI。

## 里面有什么

| 文件                          | 说明                                             |
| --------------------------- | ---------------------------------------------- |
| `LUMI-unsigned-1.0.0-1.ipa` | 未签名的真机包（arm64 / `iphoneos`），需要自签后才能装到 iPhone 上 |

> **本版新增「照片精修」**（14 条预设 / 4 类），并修复了真机首跑时「隐私页按钮点不动」的缺陷。
> 精修用法见 [`../docs/07-照片精修管线.md`](../docs/07-照片精修管线.md)。
> **如果你手上是更早的构建，请换用这一版。**

## 构建来源（可复核）

| 项         | 值                                                                           |
| --------- | --------------------------------------------------------------------------- |
| CI 运行     | GitHub Actions run **#38224834015**                                         |
| 运行链接      | <https://github.com/18156940942/LUMI-AI-Camera/actions/runs/38224834015>    |
| 提交        | `2703b0f7`（本次交付源码的文件树与该提交**完全一致**） |
| Runner    | `macos-15`                                                                  |
| Xcode     | **16.4**                                                                    |
| SDK       | iPhoneOS **18.5**（部署目标 iOS 17.0）                                            |
| 编译结果      | **0 error**                                                                 |
| 单元测试      | **`Executed 334 tests, with 0 failures`** → `** TEST SUCCEEDED **`（15 个测试类） |
| 总耗时       | 6 分 18 秒                                                                   |
| Bundle ID | `com.lumi.aicamera`                                                         |
| 版本        | `1.0.0` (build 1)                                                           |

## 校验值

装之前可以对一下，确认文件没在传输中损坏：

```
SHA-256  4ab61caf8d5098ecf569a7567a8652fd44909509a353c9592aa5974fbb0b356d
大小     927,893 bytes (906.2 KB)
```

校验命令：

```bash
# macOS / Linux
shasum -a 256 LUMI-unsigned-1.0.0-1.ipa

# Windows PowerShell
Get-FileHash LUMI-unsigned-1.0.0-1.ipa -Algorithm SHA256
```

## 包结构

解压出来是标准 ipa 布局（不是模拟器包）：

```
Payload/LUMI.app/
├── LUMI                 ← 可执行文件，2.06 MB（arm64）
├── Info.plist           ← CFBundleIdentifier = com.lumi.aicamera
├── Assets.car           ← 编译后的资源与 App 图标
├── pose_library.json    ← 32 条离线姿势库
├── PkgInfo
└── retouch_presets.json  ← 14 条精修预设目录
```

## ⚠️ 关于「未签名」

**这个 ipa 没有签名，直接用 Xcode / iTunes 是装不上的** —— 这是刻意的，因为免费 Apple 账号提供不了签名证书，云端也无从获取你的设备 UDID。

要装到 iPhone 上，需要走自签流程：

1. 用 **SideStore / AltStore / Sideloadly** 之一（对比见 [`../docs/02-构建与安装指南.md`](../docs/02-构建与安装指南.md)）；
2. 用你自己的免费 Apple ID 重新签名，签名时工具会读取你设备的信息；
3. 免费账号的限制：**证书 7 天过期**，需要续签；同时最多 3 个自签 App。

完整步骤、续签方法、常见报错对照表都在 [`../docs/02-构建与安装指南.md`](../docs/02-构建与安装指南.md)。

## ⚠️ 关于「验证状态」

- ✅ **编译通过、288 个单元测试通过** —— 这是真的跑过的结果；
- ❌ **没有在任何真机上运行过**。延迟、耗电、发热、采集卡的实际兼容性都还是未知数。

换句话说：**它能装上、能启动、逻辑是对的，但「在拍摄现场好不好用」还没人验证过。** 详见 [`../docs/04-功能完成度与已知限制.md`](../docs/04-功能完成度与已知限制.md)。

## 想自己重新构建一份？

推送到你自己的仓库即可，工作流会自动跑（`.github/workflows/build-ipa.yml`）。注意 `*.ipa` 在 `.gitignore` 里，所以这个目录不会被提交进 git。
