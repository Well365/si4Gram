# 阶段 8 · iOS 端状态（2026-09-11）

## 已完成

| 层 | 内容 | 验证 |
|---|---|---|
| 核心 `submodules/SecutgCore` | config 加载（env > 用户文件 > 内置）、E1 编解码、按天派生、密钥环 + 快照 JSON、R1/P1 生成 / 解析 / 验签 / 打开、RekeyProcessor（乱序停靠、防回滚）、SealedBlob（本地密钥环封装） | `swift test`：27 项全绿，其中 E1 / 派生 / rotate / reset / welcome / P1 直接解 Web A 生成的向量 |
| TelegramCore 钩子 | B1 `StoreMessage.init?(apiMessage:)` 解密 + 控制消息；A1 `PendingMessageManager.sendMessageContent`（文本、媒体说明、引用剥离）；A2 相册说明；A2' `StandaloneSendMessage` 两条栈（分享扩展）；A3 `RequestEditMessage`；A4 云草稿（失败发空草稿，不发明文）；`Account.init` 注册每账号运行时；`AccountManager` 注册 `SecutgTextMetaAttribute` | `cd submodules/TelegramCore && swift build` 通过（SwiftPM 路径，macOS 目标；FlatSerialization/Sources 需先用 macOS 仓库的 flatc 生成） |
| 运行时 `TelegramCore/Sources/Secutg` | `SecutgAccountRuntime`（transformIncoming / prepareOutgoing / prepareDraft / status / createMaster / importMaster / announceIdentity / buildRekey）、`SecutgHookRegistry`、`SecutgConfigHolder`、Keychain 包装的密钥环存储、实体映射 | 同上 |
| libsodium | `third-party/libsodium`：genrule 从提交的 1.0.20 tarball 编译静态库，`objc_library(module_name = "Clibsodium")` 暴露给 Swift | Bazel 全量构建通过 |
| UI `TelegramUI/Components/SecutgChatMenu` | 聊天 "…" 菜单：加密开关、密钥二维码、扫码 / 粘贴导入、登记公钥（P1）、换钥（rotate / reset / welcome）、状态；`SecutgKeyQrController`（CoreImage 生成 QR）。挂在私聊 / 群频道 / Saved Messages 三个菜单构造处 | Bazel 全量构建通过（2026-09-11） |
| 渲染 | `ChatMessageTextBubbleContentNode`：解密成功加 🔒，解不开加 🔒❗，控制消息显示为 🔑 secuTG … | Bazel 全量构建通过 |
| 配置 | `AppDelegate` 用 `SecutgConfigFiles.load()` 取 api_id / api_hash 与 crypto 参数，失败回退 BuildConfig 并记日志；`Telegram/BUILD` 把可选的 `Telegram-iOS/secutg.json` 打进包（gitignored，本机已放真实凭据） | Bazel 全量构建通过；模拟器启动时无回退日志，包内含 secutg.json |

## 未完成 / 需要真机或完整构建

- 换钥（rotate / reset / welcome）的跨端联调、Android ↔ iOS 联调待做（Android 包在手机上尚未登录）

## 联调记录（2026-09-11，模拟器 iPhone 16 Pro）

- 入口改为聊天右上角浮动锁钮（🔑 无密钥 / 🔓 有密钥未开 / 🔒 已加密），点开为操作单；资料页 More 菜单为备用入口
- 私聊里生成密钥 → 二维码页 → 复制密钥文本 → 发送 "se cu TGiOS test 1"：本机气泡带 🔒，网页端（收件人账号）未导入密钥前聊天列表预览为 `E1:c4214c3c3d1b183c.20260911:…` 密文 → **服务器侧是密文**
- 网页端 `secutg.importMaster('2071962285', payload)` + `enable` 后刷新，预览变为明文 → **iOS → Web 解密成功**
- 网页端回发 "web to iOS secuTG test 2"，iOS 气泡显示明文 + 🔒 → **Web → iOS 解密成功**

### 构建产物一律落在外置盘（2026-09-14）

内置盘空间见底，仓库与构建缓存整体迁到 `/Volumes/claudeXyz/`。iOS 这边有**两个**目录会长大，两个都要指走：

| 参数 | 作用 | 新位置 |
|---|---|---|
| `--bazelUserRoot` | bazel `--output_user_root`，**每次构建实际写入的输出根** | `/Volumes/claudeXyz/securityTG-build-files/bazel-user-root` |
| `--cacheDir` | bazel `--disk_cache`，跨构建复用的成品缓存 | `/Volumes/claudeXyz/securityTG-build-files/telegram-bazel-cache` |

漏掉 `--bazelUserRoot` 的话，输出根会退回默认的 `/private/var/tmp/_bazel_$USER`，还是吃内置盘——这正是之前一直在发生的事。

盘没挂载时构建会直接失败（路径不存在），不会悄悄退回内置盘。

## 构建记录（2026-09-11）

```bash
git submodule update --init --recursive
xcodebuild -downloadComponent MetalToolchain          # 首次需要
python3 build-system/Make/Make.py --overrideXcodeVersion \
  --bazelUserRoot /Volumes/claudeXyz/securityTG-build-files/bazel-user-root \
  --cacheDir /Volumes/claudeXyz/securityTG-build-files/telegram-bazel-cache build \
  --configurationPath build-system/secutg-development-configuration.json \
  --codesigningInformationPath=build-system/fake-codesigning --buildNumber=1 --configuration=debug_sim_arm64
```

- 配置文件 `build-system/secutg-development-configuration.json`（gitignored）：bundle_id `ph.telegra.Telegraph`、team_id `C67CF9S4VU` 与假签名一致，api_id / api_hash 填真实值
- 首次全量 5924 个动作约 25 分钟（Apple Silicon），占磁盘约 21 GiB（含 6.5 GiB `~/telegram-bazel-cache`）
- 产物：`bazel-bin/Telegram/Telegram.ipa`（517 MB debug）；模拟器安装：`xcrun simctl install <udid> <Telegram_archive-root/Payload/Telegram.app>`
- 对方不支持加密时的浮动提示条（Web 的 `SecutgPlaintextPane`）：运行时尚未上报"加密聊天收到明文"事件，UI 未做
- 设置页（Web 的 `SettingsSecutg`）未做；菜单里的"状态"项暂代
- 回复头引用（B3）：加密聊天里发送时已剥离引用文本；接收端引用若为密文原样显示
- 聊天列表预览 / 通知：B1 已解密所以正常；解不开的密文在气泡与聊天列表已改为提示行（见下方 3.17 一节），通知仍原样
- 反向向量（iOS 生成 → Web / Android 解）未生成
- 分享扩展 / NotificationService 等其它入口未加载 `secutg.json`（仍用 BuildConfig 凭据）

## 自己发出的消息也带 🔒（2026-09-12）

- 现象：iOS 上发出的加密消息气泡没有锁标；对方收到的是密文（解开后带锁），说明加密本身正常
- 原因：本地副本保留明文，`SecutgTextMetaAttribute` 只在接收解密路径（B1）附加。A1 发送钩子在发送事务里给本地副本补上该属性后，服务器确认（ack）时 `PendingMessageManager.applyAcknowledgedMessage` 用**钩子之前**抓到的 `message.attributes` 重建属性列表，把它丢掉了
- 修法：A1 在发送事务里同步 `transaction.updateMessage` 附加 meta（`SecutgAccountRuntime.localMeta`）；`applyAcknowledgedMessage` 若属性列表里没有 meta，则从 `currentMessage.secutgMeta` 补回（`// SECUTG-HOOK A1`）。自己发出的 P1 / R1 控制消息同样走 `localMeta`，气泡显示可读摘要
- 排查手段：在 TelegramCore 里临时加 `NSLog("[secutg] …")`，用 `xcrun simctl spawn <udid> log show --last 2m --predicate 'eventMessage CONTAINS "[secutg]"' --style compact` 读日志；增量 Bazel 构建约 1–3 分钟
- 验证：模拟器 build 28，发送后气泡立即显示 `badge test 28 🔒`，退出再进入聊天仍在

## 权衡记录

- 运行时放在 TelegramCore 内（`Sources/Secutg/`）而不是独立模块：钩子在 TelegramCore 里，独立模块会形成循环依赖；macOS 端因此自动获得同一份接收钩子与运行时
- 本地数据库存明文（与 Web / Android 一致）：出网请求才是密文，本机聊天记录、搜索、通知预览都正常
- 密钥环封装用 Keychain 保存 32 字节设备钥 + XChaCha20-Poly1305 封装快照文件；iOS 上文件再加 `completeFileProtectionUntilFirstUserAuthentication`

## 解不开的密文：提示行 + 事后补钥（PLAN.md 3.17，2026-09-13）

- **渲染层替换，存储仍是密文**。`SecutgUndecryptableLine`（TelegramCore）按 `SecutgTextMetaAttribute.detail` 分三种情况给出文案：`not_ready` → 正在解锁（iOS 密钥环同步加载，实际走不到，保留以对齐 Web）；`auth_failed` / `bad_plaintext` / `malformed` → 可能被改动过；其余（`unknown_key` / `invalid_key`）→ 本机没有密钥，气泡里附「加密使用指南」一行，点气泡打开指南 `member` 章。聊天列表预览用同一行、去掉可点部分。密文一个字节都不动 —— 这是补钥能成立的前提
- **补钥重跑**。`secutgRedecryptChats(postbox:accountPeerId:peerIds:)`：Postbox 没有属性索引，枚举只能按 peer 扫（`withAllMessages`），但**筛选条件是存储的属性** `kind == .undecryptable`，不是重新嗅探文本 —— 后者会把「解开后正文恰好以 E1: 开头」的消息再吃掉一次。只写回真正解开的，解不开的保留密文原样
- **四个触发点**（与 Web 一致）：导入聊天密钥、接受入群邀请、配对完成、导入搬运密钥环。前三个传 `[peerId]`，搬运密钥环传 `nil` 全量扫（导入的 master 可能解开任意聊天）
- 提示条数（`SecutgRedecrypted`）并进各自原有的那一条确认里，不再叠第二个 alert；配对完成分支已有安全码弹窗，那一处不报
