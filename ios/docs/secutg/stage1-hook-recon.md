# 阶段 1 · Telegram-iOS 钩子侦察表

基于上游 `master`（6ad963e5，2026-09）。行号会随上游漂移，以符号名为准。

## 接收（渲染前解密）

| 编号 | 位置 | 说明 |
|---|---|---|
| **B1** | `submodules/TelegramCore/Sources/ApiUtils/StoreMessage_Telegram.swift` `extension StoreMessage { convenience init?(apiMessage:accountPeerId:peerIsForum:namespace:) }` | **唯一咽喉**。71 处调用（历史拉取、更新、搜索…）都经过这里。`messageData.message` → `messageText`，实体经 `messageTextEntitiesFromApiEntities(entities)` 变成 `TextEntitiesMessageAttribute`。在 `self.init(... text: messageText, attributes: attributes ...)` 之前替换 `messageText` / 实体属性即可 |
| B1' | `submodules/TelegramCore/Sources/State/UpdateMessageService.swift` `addUpdates` | `updateShortMessage` / `updateShortChatMessage` 先被拼成合成的 `Api.Message.message` 再走 B1，**不需要单独钩** |
| — | `ProcessSecretChatIncomingDecryptedOperations.swift` | 秘密聊天独立路径，secuTG 不处理秘密聊天 |
| B2 | `submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift` `asyncLayoutContent()` | 气泡文本：`rawText = item.message.text` → `stringWithAppliedEntities`。B1 已解密，这里只需根据 `SecutgTextMetaAttribute` 加锁角标 |
| B3 | `submodules/TelegramUI/Components/Chat/ChatMessageReplyInfoNode/Sources/ChatMessageReplyInfoNode.swift` `asyncLayout` | 回复头：`quote.text`（服务器保存的引用文本，独立字段）或 `message.text`。加密聊天里发送时去掉 quote，接收时 quote 若为密文则显示占位 |
| B4 | `ManagedSynchronizeChatInputStateOperations.swift` / 草稿回读 | 云草稿回读为密文时需解密（与 Android B4 同） |

## 发送（发送前加密）

| 编号 | 位置 | 说明 |
|---|---|---|
| **A1** | `submodules/TelegramCore/Sources/State/PendingMessageManager.swift` `sendMessageContent(...)` | 文本：`Api.functions.messages.sendMessage(... message: message.text, entities: messageEntities ...)`；带说明的媒体：`sendMedia(... message: text ...)`。在构造请求前把 `message.text` + `TextEntitiesMessageAttribute` 换成密文 |
| A2 | 同文件 相册路径 `.inputSingleMedia(... message: text, entities: ...)` → `sendMultiMedia` | 每条 caption 单独加密 |
| A2' | `PendingMessages/StandaloneSendMessage.swift` | 分享扩展的独立发送栈，同样要钩（否则分享扩展发明文） |
| A3 | `PendingMessages/RequestEditMessage.swift` | `messages.editMessage(... message: text, entities: apiEntities ...)` |
| A4 | `State/ManagedSynchronizeChatInputStateOperations.swift` `synchronizeChatInputState` | `savedMessage = inputState?.text` → `messages.saveDraft`。云草稿是明文外泄点，必须加密 |
| — | `forwardMessages` | 无文本字段，服务器复制原文，无需处理（转发密文仍是密文） |
| — | `Api.functions.messages.sendMessage` 的 `replyTo` 带 `quoteText` | 加密聊天里发送时清空引用文本（与 Web 一致） |

本地入库（`EnqueueMessage.swift` `enqueueMessages(transaction:...)`）保持明文，这样本机聊天窗口和数据库里是明文，只有出网请求是密文。发送成功后服务器回包的 `updateMessageID` / 新消息又经 B1 解密，前后一致。

## 配置

| 位置 | 说明 |
|---|---|
| `submodules/BuildConfig/BUILD` + `Sources/BuildConfig.m` | `APP_CONFIG_API_ID` / `APP_CONFIG_API_HASH` 编译期宏，来自 `build-system/*configuration.json` |
| `submodules/TelegramUI/Sources/AppDelegate.swift` | `let apiId = buildConfig.apiId` → `NetworkInitializationArguments(apiId:apiHash:...)`。**在此处改为 `SecutgConfigLoader` 解析结果**；同样的构造还在 NotificationService / SiriIntents / ShareExtensionContext / NotificationContentContext |
| `submodules/TelegramCore/Sources/Network/Network.swift` `initializedNetwork` | `apiEnvironment.apiId = arguments.apiId`，不动 |

## 菜单 / UI 挂点

| 位置 | 说明 |
|---|---|
| `submodules/TelegramUI/Sources/ChatController.swift` `moreBarButton.contextAction` | 分三路：Saved Messages → `PeerInfoScreenImpl.openSavedMessagesMoreMenu`；私聊 → `openBotForumMoreMenu`（`Chat/ChatControllerOpenPeer.swift`）；群/频道 → `ChatListControllerImpl.openMoreMenu`（`submodules/ChatListUI/Sources/ChatListController.swift`）。"加密"入口要三处都加 |
| `ChatController` 的 `titlePanel` / `chatTitleView` 附近的浮动面板（pinned、translation panel） | 明文提示条（对方不支持加密）放在这类面板上 |

## 构建

- 模块 = `submodules/<Name>/BUILD` 的 `swift_library`，`deps` 用 `//submodules/<Name>` 标签，无需中央注册；`build-system/generate_spm.py` 会从 bazel query 派生 SPM 工程
- 第三方 C 库：`third-party/opus/BUILD` 是 genrule（tarball → 各架构 `.a`）+ `cc_library` 的范本；预编译 xcframework 用 `apple_static_xcframework_import`（仅 `third-party/recaptcha` 使用）
- **仓库里没有 libsodium**（只有 BoringSSL）。secuTG 采用 `third-party/libsodium`：genrule 编译 libsodium 1.0.20 stable tarball → `cc_library(name="libsodium")` + `module.modulemap`（模块名 `Clibsodium`），`SecutgCore` 依赖它。SwiftPM 单测走 `jedisct1/swift-sodium` 的 `Clibsodium` 二进制
- 全量构建走 `python3 build-system/Make/Make.py build`（Bazel 8.4.2，需要 `~/telegram-bazel-cache` 及签名配置），本机磁盘约 20 GiB 空闲，首次全量构建可能不够
