# secuTG-android · 项目宪法

本仓库是 Telegram 官方 Android 客户端（DrKLO/Telegram）的分叉，是 secuTG 的 Android 端。协议、消息格式、密钥派生、换钥流程**完全沿用** Web A 仓库 `<workspace>/secuTG/PLAN.md` 第三节及其"实现约定"注释，不允许改格式；Web A 的实现（`src/secutg/`）是行为参考，两端必须互发互解。

## 硬约束

- 不改 MTProto / tgnet 协议、不改与服务器的任何交互；只在文本消息的发送入口和渲染入口加钩子
- 所有插件代码放在 `TMessagesProj/src/main/java/org/telegram/secutg/` 下；上游文件的改动处必须加注释 `// SECUTG-HOOK`，改动面尽量小
- 密码学只用 lazysodium（libsodium 绑定）：XChaCha20-Poly1305 / X25519 `crypto_box_seal` / Ed25519 `crypto_sign` / `crypto_kdf_derive_from_key` / `crypto_generichash`，不自己实现任何密码学原语
- 密文 `E1:<key_id>:<nonce_b64url>:<ct_b64url>`，明文 JSON `{v,t,e}`，AAD = key_id；`R1` / `P1` 的签名字符串与 payload 编码按 Web A PLAN.md 3.4 / 3.5 的实现约定
- **当面配对模式**下，群密钥永远不以明文经过 Telegram，第一把钥匙和管理员公钥只能线下二维码录入。
  **自动配对模式下群密钥明文发进群**（`G2`，PLAN.md 3.35，2026-09-20 用户定）——该模式的信任根本来就是 Telegram
  的成员名单，谁能把人加进群谁就能让他读，所以它对平台不提供保密性，也不声称提供。载荷用写死的共享口令包了一层
  （`G2Obfuscation`，PLAN.md 3.35.8）：那是**混淆不是加密**，口令随安装包分发，代码里一律叫 `obfuscate`，
  界面绝不因此显示「已加密」。私聊的密钥仍然永远不走明文。
- `APP_ID` / `APP_HASH` 及插件参数只能从 `secutg.json` 读取：`assets/secutg.json` 内置默认 < `filesDir/secutg.json` 用户覆盖；在 `ApplicationLoader` 里、`ConnectionsManager` 初始化前赋给 `BuildVars.APP_ID/APP_HASH`；schema 与 Web A 一致（snake_case）
- `secutg.json` 不进 git，只提交 `secutg.example.json`
- 密钥环持久化用 Android Keystore 包一层（主钥用 Keystore 里的 AES 密钥加密后落盘）
- 每个阶段独立分支、可编译、带 JUnit 单测；`org.telegram.secutg.crypto` 不得 import 任何 `org.telegram.messenger` / `org.telegram.tgnet` 类
- 解不开的密文原样显示并加锁角标，任何情况下不崩溃、不吞消息

## 工作方式

- 改动前先列计划和影响文件清单，得到确认再改
- 不确定源码结构时先读源码再改，不凭印象猜文件名
- 每补一处渲染路径单独一次提交，提交信息写明 hook 了哪里
- 完成阶段后输出：改了哪些文件、怎么验证、已知未覆盖项
- 验证一律 `./gradlew … --rerun-tasks`（省掉会假绿）；踩到 macOS `.DS_Store` 打断构建时先读
  [docs/secutg/build-dsstore.md](docs/secutg/build-dsstore.md)，根 `build.gradle` 里已有守卫，不要再手工搬文件
- 用中文回答

## 目录

```
TMessagesProj/src/main/java/org/telegram/secutg/
├── config/    # secutg.json 加载
├── crypto/    # encrypt / decrypt / isEncrypted（纯 Java，无 Android 依赖）
├── keyring/   # 按 key_id 存取、按天派生、Keystore 持久化
├── rekey/     # R1 / P1 生成、解析、验签、顺序追赶
├── hooks/     # 发送钩子、渲染钩子接线
└── ui/        # 加密开关、换钥按钮、二维码
```
