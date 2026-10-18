# secuTG-miniapp · 项目宪法

这是 secuTG 的"零安装"入口：一个运行在**官方 Telegram 客户端**里的小程序（Mini App）加一个只做转发的 Bot。给没有安装 secuTG 分叉客户端的人用：手动把文字加密后通过内联模式发出，收到密文后粘贴解密。协议、消息格式、密钥派生、换钥流程**完全沿用** Web A 仓库 `<workspace>/secuTG/PLAN.md` 第三节，`web/src/secutg/` 是从 Web A `src/secutg/` 原样复制的纯模块（crypto / keyring / rekey / config），不允许改格式；升级时整目录重新复制。

## 硬约束

- 明文只存在于用户设备的 WebView 里；Bot 只接收并回显已经是密文（E1 / R1 / P1）的内联查询，任何时候不得把明文发给 Bot 或任何服务器
- 密钥环存 WebView 的 IndexedDB（`secutg-miniapp` 库），**禁止**用 Telegram CloudStorage 或任何云端同步主钥
- 密码学只用 libsodium（`libsodium-wrappers`），不自己实现任何原语
- 小程序没有聊天上下文，密钥按用户自定标签管理；解密按 key_id 在所有已知主钥里查找，与标签无关
- `BOT_TOKEN`、`WEBAPP_URL` 只从环境变量读取，只提交 `.env.example`
- `web/src/secutg/` 的测试与向量（`web/tests/vectors`）必须保持通过，这是与其它端互通的证据

## 目录

```
web/            # Vite + TypeScript 小程序（index.html, src/main.ts, src/app/*, src/secutg/* 复制自 Web A）
bot/            # Node 20+ 长轮询 Bot（index.mjs），无框架、无数据库
docs/           # 部署与使用说明
```

## 常用命令

```bash
cd web && npm install && npm test && npm run build     # 产物在 web/dist，任意静态 HTTPS 托管
cd bot && BOT_TOKEN=… WEBAPP_URL=… node index.mjs
```
