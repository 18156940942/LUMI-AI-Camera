# dist/ — 预构建的未签名 ipa

这个目录里放的是**已经在云端 macOS 上真实构建出来、可以直接拿去自签安装的 ipa**，省掉你自己跑一遍 CI。

## 里面有什么

| 文件 | 说明 |
| --- | --- |
| `LUMI-unsigned-1.0.0-32.ipa` | 未签名的真机包（arm64 / `iphoneos`），需要自签后才能装到 iPhone 上 |

> **文件名里的 `32` 是构建号**，等于 CI 运行号，也写进了 `CFBundleVersion`。
>
> 这一点是踩坑之后加的：以前所有构建的 `CFBundleVersion` 都是 `1`、文件名都叫
> `LUMI-unsigned-1.0.0-32.ipa`，于是**根本分不清手上拿的是哪一版** —— 实测就发生过
> 「签完才发现签的是带缺陷的旧构建」。现在文件名自带构建号，而且装到手机之后
> `python tools/lumi_device_log.py apps --filter lumi` 能直接读出装的是哪一次。

> **本版修了三个东西**：① 应用自身日志走 `.info` 级时在设备日志流里看不到，已改为
> default 级；② 构建号写进 `CFBundleVersion`；③ 运行期 `<Fault>`：`%@` 收到的是
> Swift `String` 而不是对象（13 处，含姿态建议文案）。
> **如果你手上是更早的构建，请换用这一版。**

## 构建来源（可复核）

| 项 | 值 |
| --- | --- |
| CI 运行 | GitHub Actions run **#38232586237** |
| 运行链接 | <https://github.com/18156940942/LUMI-AI-Camera/actions/runs/38232586237> |
| 提交 | `f573340d`（本次交付源码的文件树与该提交**完全一致**） |
| Runner | `macos-15` |
| Xcode | **16.4** |
| SDK | iPhoneOS **18.5**（部署目标 iOS 17.0） |
| 编译结果 | **0 error** |
| 单元测试 | **`Executed 334 tests, with 0 failures`** → `** TEST SUCCEEDED **`（15 个套件） |
| 总耗时 | 10 分 18 秒 |
| Bundle ID | `com.lumi.aicamera`（自签后会变成 `<TeamID>.com.lumi.aicamera.<TeamID>`，免费账号的常规行为） |
| 版本 | `1.0.0` (build **32**) |

## 校验值

装之前可以对一下，确认文件没在传输中损坏：

```
SHA-256  9719c76af7e7d9a7198144c89c71f35ac7db5ac6a6fb47f9d839110d60c51dea
大小     927,982 bytes (906.2 KB)
```

校验命令：

```bash
# macOS / Linux
shasum -a 256 LUMI-unsigned-1.0.0-32.ipa

# Windows PowerShell
Get-FileHash LUMI-unsigned-1.0.0-32.ipa -Algorithm SHA256
```

## 包结构

解压出来是标准 ipa 布局（不是模拟器包）：

```
Payload/LUMI.app/
├── LUMI                   ← 可执行文件，2.06 MB（arm64）
├── Info.plist             ← CFBundleIdentifier = com.lumi.aicamera；CFBundleVersion = 32
├── Assets.car             ← 编译后的资源与 App 图标
├── pose_library.json      ← 32 条离线姿势库
├── retouch_presets.json   ← 14 条精修预设目录
└── PkgInfo
```

## ⚠️ 关于「未签名」

**这个 ipa 没有签名，直接用 Xcode / iTunes 是装不上的** —— 这是刻意的，因为免费 Apple 账号提供不了签名证书，云端也无从获取你的设备 UDID。

要装到 iPhone 上，需要走自签流程：

1. 用 **SideStore / AltStore / Sideloadly** 之一（对比见 [`../docs/02-构建与安装指南.md`](../docs/02-构建与安装指南.md)）；
2. 用你自己的免费 Apple ID 重新签名，签名时工具会读取你设备的信息；
3. 免费账号的限制：**证书 7 天过期**，需要续签；同时最多 3 个自签 App。

**注意**：7 天到期后**不需要重跑 CI**，重新签**同一个包**即可 —— 代码没变，只是证书过期了。

完整步骤、续签方法、常见报错对照表都在 [`../docs/02-构建与安装指南.md`](../docs/02-构建与安装指南.md)。

## ⚠️ 关于「验证状态」

- ✅ **编译通过、334 个单元测试通过** —— 真实跑过的结果；
- ✅ **已在真机上跑起来过**（2026-10-12，iPhone 15 Pro Max / iOS 26.0）：
  从设备日志里读到内置摄像头在 App 进程内以 **29.998 fps** 稳定出帧、累计 2099 帧，
  切后台时采集会话干净中断，无崩溃、无看门狗强杀。方法与证据见
  [`../docs/06-真机验收清单.md`](../docs/06-真机验收清单.md#实测运行记录2026-10-12-1731经-usb-日志流)；
- ❌ **「在拍摄现场好不好用」仍未验证** —— 画面观感、AI 结论是否合理、延迟、
  耗电、发热、采集卡的实际兼容性，都还需要你在现场判断。

换句话说：**它能装上、能启动、逻辑是对的，内置摄像头链路也已经证明是活的；
但「拿着它去拍照顺不顺手」这件事，只能由你回答。** 详见
[`../docs/04-功能完成度与已知限制.md`](../docs/04-功能完成度与已知限制.md)。

## 想自己重新构建一份？

推送到你自己的仓库即可，工作流会自动跑（`.github/workflows/build-ipa.yml`）。注意 `*.ipa` 在 `.gitignore` 里，所以这个目录不会被提交进 git。
