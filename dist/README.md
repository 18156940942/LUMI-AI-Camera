# dist/ — 预构建的未签名 ipa

这个目录里放的是**已经在云端 macOS 上真实构建出来、可以直接拿去自签安装的 ipa**，省掉你自己跑一遍 CI。

## 里面有什么

| 文件 | 说明 |
|---|---|
| `LUMI-unsigned-1.0.0-1.ipa` | 未签名的真机包（arm64 / `iphoneos`），需要自签后才能装到 iPhone 上 |

## 构建来源（可复核）

| 项 | 值 |
|---|---|
| CI 运行 | GitHub Actions run **#38198820127** |
| 运行链接 | https://github.com/18156940942/LUMI-AI-Camera/actions/runs/38198820127 |
| 提交 | `9644981b`（本次交付源码的文件树与该提交**完全一致**，91 个文件逐一比对过 SHA） |
| Runner | `macos-15` |
| Xcode | **16.4** |
| SDK | iPhoneOS **18.5**（部署目标 iOS 17.0） |
| 编译结果 | **0 error** |
| 单元测试 | **`Executed 252 tests, with 0 failures`** → `** TEST SUCCEEDED **` |
| 总耗时 | 11 分 17 秒 |
| Bundle ID | `com.lumi.aicamera` |
| 版本 | `1.0.0` (build 1) |

## 校验值

装之前可以对一下，确认文件没在传输中损坏：

```
SHA-256  30a0ee520490967094936aa85a00d4153c033f0925e2dec9b1eaacd87a1097c2
大小     751,379 bytes (733.8 KB)
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
├── LUMI                 ← 可执行文件，1.71 MB（arm64）
├── Info.plist           ← CFBundleIdentifier = com.lumi.aicamera
├── Assets.car           ← 编译后的资源与 App 图标
├── pose_library.json    ← 32 条离线姿势库
└── PkgInfo
```

## ⚠️ 关于「未签名」

**这个 ipa 没有签名，直接用 Xcode / iTunes 是装不上的** —— 这是刻意的，因为免费 Apple 账号提供不了签名证书，云端也无从获取你的设备 UDID。

要装到 iPhone 上，需要走自签流程：

1. 用 **SideStore / AltStore / Sideloadly** 之一（对比见 [`../docs/02-构建与安装指南.md`](../docs/02-构建与安装指南.md)）；
2. 用你自己的免费 Apple ID 重新签名，签名时工具会读取你设备的信息；
3. 免费账号的限制：**证书 7 天过期**，需要续签；同时最多 3 个自签 App。

完整步骤、续签方法、常见报错对照表都在 [`../docs/02-构建与安装指南.md`](../docs/02-构建与安装指南.md)。

## ⚠️ 关于「验证状态」

- ✅ **编译通过、252 个单元测试通过** —— 这是真的跑过的结果；
- ❌ **没有在任何真机上运行过**。延迟、耗电、发热、采集卡的实际兼容性都还是未知数。

换句话说：**它能装上、能启动、逻辑是对的，但「在拍摄现场好不好用」还没人验证过。** 详见 [`../docs/04-功能完成度与已知限制.md`](../docs/04-功能完成度与已知限制.md)。

## 想自己重新构建一份？

推送到你自己的仓库即可，工作流会自动跑（`.github/workflows/build-ipa.yml`）。注意 `*.ipa` 在 `.gitignore` 里，所以这个目录不会被提交进 git。
