# secuTG-desktop · 项目宪法

本仓库是 Telegram Desktop（telegramdesktop/tdesktop，C++/Qt）的分叉，是 secuTG 的 Windows 端，同一份代码也产出 Linux 与 macOS 桌面版。协议、消息格式、密钥派生、换钥流程**完全沿用** Web A 仓库 `<workspace>/secuTG/PLAN.md` 第三节及其"实现约定"注释，不允许改格式；Web A（`src/secutg/`）、Android（`secutg-core`）、iOS/macOS（`SecutgCore`）是行为参考，所有端必须互发互解，向量文件 `Telegram/SourceFiles/secutg/tests/vectors/*.json` 与其它端相同。

## 硬约束

- 不改 MTProto / `Telegram/SourceFiles/mtproto`，不改与服务器的任何交互；只在文本消息的发送入口和渲染入口加钩子
- 插件代码放在 `Telegram/SourceFiles/secutg/`（`config/ crypto/ keyring/ rekey/ hooks/ ui/`），`crypto/` 只依赖 libsodium 与标准库，不 include 任何 `history/`、`data/`、`mtproto/` 头文件；上游文件的改动处必须加注释 `// SECUTG-HOOK`，改动面尽量小
- 密码学只用 libsodium（`third_party/libsodium`，Windows 用官方 MSVC 预编译静态库，Linux/macOS 用系统或源码构建）：XChaCha20-Poly1305 / X25519 `crypto_box_seal` / Ed25519 `crypto_sign` / `crypto_kdf_derive_from_key` / `crypto_generichash`，不自己实现任何原语
- 密文 `E1:<key_id>:<nonce_b64url>:<ct_b64url>`，明文 JSON `{v,t,e}`，AAD = key_id；`R1` / `P1` 按 PLAN.md 3.4 / 3.5 的实现约定
- **当面配对模式**下，群密钥永远不以明文经过 Telegram，第一把钥匙和管理员公钥只能线下二维码 / 粘贴录入。
  **自动配对模式下群密钥明文发进群**（`G2`，PLAN.md 3.35，2026-09-20 用户定）——该模式的信任根本来就是 Telegram
  的成员名单，谁能把人加进群谁就能让他读，所以它对平台不提供保密性，也不声称提供。载荷用写死的共享口令包了一层
  （`G2Obfuscation`，PLAN.md 3.35.8）：那是**混淆不是加密**，口令随安装包分发，代码里一律叫 `obfuscate`，
  界面绝不因此显示「已加密」。私聊的密钥仍然永远不走明文。
- `api_id` / `api_hash` 及插件参数只能从 `secutg.json` 读取：可执行文件同目录或工作目录的 `secutg.json` 内置默认 < 用户数据目录（`tdata` 旁）的 `secutg.json` 覆盖 < 环境变量；在 MTP 实例创建前解析；编译期的 `TDESKTOP_API_ID/HASH` 只作最后回退；schema 与其它端一致（snake_case）
- `secutg.json` 不进 git，只提交 `secutg.example.json`
- 密钥环持久化：JSON 快照用本机密钥封装（Windows DPAPI / macOS Keychain / Linux libsecret，退化为文件权限 600）后写入用户数据目录 `secutg/keyring.bin`
- 每个阶段独立分支、可编译、带单测（Catch2 或 tdesktop 自带测试框架，对共享向量）；解不开的密文原样显示并加锁角标，任何情况下不崩溃、不吞消息

## 工作方式

- 改动前先列计划和影响文件清单，得到确认再改
- 不确定源码结构时先读源码再改；钩子位置以 `docs/secutg/stage1-hook-recon.md` 为准
- 每补一处渲染路径单独一次提交，提交信息写明 hook 了哪里
- 完成阶段后输出：改了哪些文件、怎么验证、已知未覆盖项
- 用中文回答
- Windows 构建在远程机器上进行（见 `docs/secutg/build-windows.md`）；本机只做侦察与编码

## 目录

```
Telegram/SourceFiles/secutg/
├── config/    # secutg.json 加载
├── crypto/    # E1 编解码（纯 C++ + libsodium）
├── keyring/   # 派生、密钥环、本机封装持久化
├── rekey/     # R1 / P1 生成、解析、验签、顺序追赶
├── hooks/     # 发送钩子、渲染钩子接线
└── ui/        # 浮动锁钮、菜单、二维码
docs/secutg/   # 侦察表、构建说明、阶段状态
```
