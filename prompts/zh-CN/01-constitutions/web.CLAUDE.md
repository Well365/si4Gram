# secuTG · 项目宪法

本项目是 Telegram 开源客户端（起步端：telegram-tt / Web A）的分叉。目标：在客户端内加"发送前加密、显示前解密"的插件层，聊天窗口全是明文，线上全是密文。详细计划见 `PLAN.md`，协议与数据格式以 `PLAN.md` 第三节为准，不得擅自更改格式。

## 硬约束

- 不改 MTProto 协议、不改与服务器的任何交互；只在文本消息的发送入口和渲染入口加钩子
- 所有插件代码放在 `src/secutg/` 下；上游文件的改动处必须加注释 `// SECUTG-HOOK`，改动面尽量小
- 密码学只用 libsodium（web: `libsodium-wrappers`）：XChaCha20-Poly1305 / X25519 `crypto_box_seal` / Ed25519 `crypto_sign` / `crypto_kdf_derive_from_key`，不自己实现任何密码学原语
- 密文格式 `E1:<key_id>:<nonce_b64url>:<ct_b64url>`，明文 JSON `{v, t, e}`，AAD = key_id
- 换钥消息 `R1:<type>:<new_key_id>:<payload>:<sig>`，公钥登记 `P1:...`，见 `PLAN.md` 3.4 / 3.5
- **当面配对模式**下，群密钥（master_key）永远不以明文经过 Telegram，第一把钥匙和管理员公钥只能线下二维码录入。
  **自动配对模式下群密钥明文发进群**（`G2`，PLAN.md 3.35，2026-09-20 用户定）——该模式的信任根本来就是 Telegram
  的成员名单，谁能把人加进群谁就能让他读，所以它对平台不提供保密性，也不声称提供。私聊的密钥仍然永远不走明文。
- `api_id` / `api_hash` 及所有插件参数只能从 `secutg.json` 读取，禁止硬编码；加载顺序：环境变量 > 用户覆盖文件 > 打包内置默认；各端 schema 必须一致
- `secutg.json` 不进 git，只提交 `secutg.example.json`
- 每个阶段独立分支、可编译、带单元测试（vitest）；`src/secutg/crypto/` 不得 import 任何 telegram-tt 内部模块
- 解不开的密文原样显示并加锁角标，任何情况下不崩溃、不吞消息

## 工作方式

- 改动前先列计划和影响文件清单，得到确认再改
- 不确定 telegram-tt 源码结构时先读源码再改，不凭印象猜文件名
- 每补一处渲染路径单独一次提交，提交信息写明 hook 了哪里
- 完成阶段后输出：改了哪些文件、怎么验证、已知未覆盖项
- 用中文回答

## 常用命令

```bash
npm install
npm run dev          # 本地开发
npm run test         # vitest
git fetch upstream && git merge upstream/master   # 同步上游
```

## 目录

```
src/secutg/
├── config/    # secutg.json 加载
├── crypto/    # encrypt / decrypt / isEncrypted（纯函数）
├── keyring/   # 按 key_id 存取、按天派生、IndexedDB 持久化
├── rekey/     # R1 / P1 生成、解析、验签、顺序追赶
├── hooks/     # 发送钩子、渲染钩子接线
└── ui/        # 加密开关、换钥按钮、二维码
```

## 上游代码风格

上游 telegram-tt 的代码风格、Teact/SCSS 约定和 API 生成流程见 `AGENTS.md`，与本文件冲突时以本文件为准。
