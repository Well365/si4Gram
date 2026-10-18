# secuTG-macos · 项目宪法

本仓库是 Telegram 官方 macOS 客户端（overtake/TelegramSwift）的分叉，是 secuTG 的 macOS 端。它通过子模块 `submodules/telegram-ios` 复用 Telegram-iOS 的 `TelegramCore` / `Postbox`；secuTG 把该子模块指向 iOS 端分叉 `<workspace>/secuTG-ios`，因此**接收钩子、协议核心（`SecutgCore`）和运行时（`SecutgRuntime`）都来自 iOS 分叉，本仓库只做发送钩子、渲染钩子和 macOS UI**。协议、消息格式、密钥派生、换钥流程完全沿用 Web A 仓库 `<workspace>/secuTG/PLAN.md` 第三节，不允许改格式。

## 硬约束

- 不改 MTProto、不改与服务器的任何交互；只在文本消息的发送入口和渲染入口加钩子
- 本仓库的插件代码放在 `Telegram-Mac/Secutg/`；上游文件的改动处必须加注释 `// SECUTG-HOOK`，改动面尽量小
- 密码学只用 libsodium（经 `SecutgCore` 的 `Clibsodium`），不自己实现任何密码学原语
- `api_id` / `api_hash` 及插件参数只能从 `secutg.json` 读取：打包资源内置默认 < `~/Library/Application Support/secutg.json` 用户覆盖 < 环境变量；`packages/ApiCredentials` 的硬编码值改为从 `SecutgCore.SecutgConfigLoader` 读取；`secutg.json` 不进 git，只提交 `secutg.example.json`
- 密钥环用 `SecutgRuntime` 的 Keychain 包装持久化，与 iOS 相同格式
- 每个阶段独立分支、可编译；任何情况下不崩溃、不吞消息
- 解不开的密文**存储层原样保留**（这是 PLAN.md 3.17 第 2 条：密文一个字节都不动，拿到密钥后才能补解），渲染层不显示那串 base64，改显示一行说明（没密钥 / 有密钥但打不开 / 密钥环未就绪）
- **已开启加密的聊天，落盘的一律是 `E1:` 密文，明文只在内存里**（PLAN.md 3.19，开关默认开）：入库的两个口子都换——收消息的 `transformIncoming` 和发消息的 `enqueueMessages`；读回来时在渲染出口（`ChatMessageItem` / `TextUtils.pullText`）解开，会话内缓存在 `LocalCiphertext.PlaintextCache`。代价是这些聊天的数据库搜索失效，这是明确接受的。普通聊天完全不变。该开关只影响此后入库的消息，已存下的明文不做批量重写

## 工作方式

- 改动前先列计划和影响文件清单，得到确认再改
- 不确定源码结构时先读源码再改；钩子位置以 `docs/secutg/stage1-hook-recon.md` 为准
- 每补一处渲染路径单独一次提交，提交信息写明 hook 了哪里
- 完成阶段后输出：改了哪些文件、怎么验证、已知未覆盖项
- 用中文回答

## 目录

```
Telegram-Mac/Secutg/              # 发送钩子接线、渲染钩子接线、菜单、换钥面板、二维码、明文提示条
submodules/telegram-ios/          # → secuTG-ios 分叉（SecutgCore / SecutgRuntime / TelegramCore 接收钩子）
docs/secutg/                      # 侦察表、阶段状态
```
