# secuTG-ios · 项目宪法

本仓库是 Telegram 官方 iOS 客户端（TelegramMessenger/Telegram-iOS）的分叉，是 secuTG 的 iOS 端；`submodules/TelegramCore` 同时被 macOS 端（`<workspace>/secuTG-macos`，overtake/TelegramSwift 分叉）作为子模块复用，所以**接收钩子和协议核心只在这里实现一次**。协议、消息格式、密钥派生、换钥流程**完全沿用** Web A 仓库 `<workspace>/secuTG/PLAN.md` 第三节及其"实现约定"注释，不允许改格式；Web A（`src/secutg/`）与 Android（`<workspace>/secuTG-android/secutg-core`）是行为参考，所有端必须互发互解。

## 硬约束

- 不改 MTProto / MtProtoKit、不改与服务器的任何交互；只在文本消息的发送入口和渲染入口加钩子
- 协议核心放在 `submodules/SecutgCore/`（纯 Swift + libsodium C API，不 import TelegramCore / Postbox / UIKit），可用 `swift test` 独立测试；接线代码放在 `submodules/SecutgRuntime/`（依赖 TelegramCore / Postbox）；UI 放在 `submodules/TelegramUI/Components/Secutg*/`
- 上游文件的改动处必须加注释 `// SECUTG-HOOK`，改动面尽量小
- 密码学只用 libsodium（`Clibsodium`）：XChaCha20-Poly1305 / X25519 `crypto_box_seal` / Ed25519 `crypto_sign` / `crypto_kdf_derive_from_key` / `crypto_generichash`，不自己实现任何密码学原语，不用 BoringSSL 替代
- 密文 `E1:<key_id>:<nonce_b64url>:<ct_b64url>`，明文 JSON `{v,t,e}`，AAD = key_id；`R1` / `P1` 的签名字符串与 payload 编码按 Web A PLAN.md 3.4 / 3.5 的实现约定
- **当面配对模式**下，群密钥永远不以明文经过 Telegram，第一把钥匙和管理员公钥只能线下二维码录入。
  **自动配对模式下群密钥明文发进群**（`G2`，PLAN.md 3.35，2026-09-20 用户定）——该模式的信任根本来就是 Telegram
  的成员名单，谁能把人加进群谁就能让他读，所以它对平台不提供保密性，也不声称提供。载荷用写死的共享口令包了一层
  （`G2Obfuscation`，PLAN.md 3.35.8）：那是**混淆不是加密**，口令随安装包分发，代码里一律叫 `obfuscate`，
  界面绝不因此显示「已加密」。私聊的密钥仍然永远不走明文。
- `api_id` / `api_hash` 及插件参数只能从 `secutg.json` 读取：打包资源 `secutg.json` 内置默认 < `Application Support/secutg.json` 用户覆盖 < 环境变量 / 启动参数；在 `NetworkInitializationArguments` 构造前解析；schema 与其他端一致（snake_case）
- `secutg.json` 不进 git，只提交 `secutg.example.json`
- 密钥环持久化：JSON 快照用 Keychain 里的随机 32 字节密钥做 XChaCha20-Poly1305 加密后落盘（`Application Support/secutg/keyring.bin`）
- 每个阶段独立分支、可编译、带单测（`SecutgCore` 用 XCTest 对 Web A 生成的向量）；解不开的密文原样显示并加锁角标，任何情况下不崩溃、不吞消息

## 工作方式

- 改动前先列计划和影响文件清单，得到确认再改
- 不确定源码结构时先读源码再改，不凭印象猜文件名；钩子位置以 `docs/secutg/stage1-hook-recon.md` 为准
- 每补一处渲染路径单独一次提交，提交信息写明 hook 了哪里
- 完成阶段后输出：改了哪些文件、怎么验证、已知未覆盖项
- 用中文回答
- 上游的构建说明（Bazel / Make.py / 模拟器安装）见 `docs/UPSTREAM-CLAUDE.md`

## 目录

```
submodules/SecutgCore/            # 协议核心：config / crypto / keyring / rekey（纯 Swift，swift test）
submodules/SecutgRuntime/         # 每账号运行时：密钥环存储、发送/接收钩子入口、控制消息处理
submodules/TelegramUI/Components/Secutg*/   # 加密开关、换钥、二维码、锁角标、明文提示条
third-party/libsodium/            # libsodium 静态库（Bazel genrule + cc_library，模块名 Clibsodium）
docs/secutg/                      # 侦察表、阶段状态
```
