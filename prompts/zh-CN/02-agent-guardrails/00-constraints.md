# 00 · 硬约束（执行本规范期间一条都不能破）

> 本文件是给执行模型（Opus 5 或任何后续 agent）的**安全边界**。任何一条与后续文档冲突时，以本文件为准。
> 这些规则来自真实事故（2026-08-25 曾发生数据丢失）和项目性质（擦除功能本身是破坏性的）。

## A. 文件系统

| # | 规则 | 说明 |
|---|------|------|
| A1 | **绝不删除**任何机器上的任何文件或目录 | 包括 dev-mac、backup-mac、外接盘。`rm` 已被本机 hook 拦截。需要"拿开"某个东西时用 `mv` 移到同级 `_archive-<日期>/` 目录，并在报告里写明 |
| A2 | 不用 `/usr/bin/trash` | 本规范里所有"拿开"都用 `mv` 到 `_archive-*`，便于回滚 |
| A3 | backup-mac（ssh 别名 `backup-mac`，主机名 <hostname>）**只读** | 只允许 `git fetch`/`rsync` **从** backup-mac 读；不允许在 backup-mac 上写、改、删、提交 |
| A4 | 外接盘路径固定为 `<workspace>/` | 所有开发、构建、缓存都在这里；不得在 `~/Documents` 或内置盘新建工程副本 |
| A5 | 构建缓存放 `<build-cache>/` | bazel `--output_user_root` 与 DerivedData 都指过去；不把缓存放回内置盘 |

## B. Git

| # | 规则 | 说明 |
|---|------|------|
| B1 | **绝不 push 到 GitHub** | `secuTG-ios` 与 `secuTG-macos` 的唯一远端 `upstream` 是 **官方/上游公开仓库**（TelegramMessenger/Telegram-iOS、overtake/TelegramSwift）。push 上去等于公开 secuTG 代码。本规范里所有 push 只能指向本地路径或 dev-mac 内的仓库 |
| B2 | 不强制推送、不 rebase 已存在的分支、不用 filter-branch / filter-repo 改写已有分支 | 抽取历史只用 `git subtree split`（产生**新**提交，不动原分支） |
| B3 | 不 `git reset --hard`、不 `git checkout -- <file>`、不 `git clean`、不 `git stash drop` | 唯一例外：`03-runbook.md` 明确写出的回滚步骤 |
| B4 | 不带 `--recursive` 初始化子模块 | 会把 webrtc/tg_owt 等数 GB 嵌套子模块拉下来。只允许**定向** init 规范指定的路径 |
| B5 | `git commit` 所在的 shell 行**不能同时出现** `-n`、`-not`、`grep -n` | 本机 hook 会把它误判为绕过钩子的标志并拒绝整条命令。把命令拆成两行 |
| B6 | 不绕过 git 钩子 | 本机 hook 会拦截任何绕过钩子的标志（无论出现在命令还是 heredoc 文本里）。写文档时也别把那个标志的字面量放进 Bash 命令行，用 Write 工具写文件 |
| B7 | 提交信息用 `<type>(secutg): <描述>` | type ∈ feat/fix/refactor/docs/test/chore/build。不加 AI 署名行 |
| B8 | 先 `git status` 再动手；工作区有未提交改动时先按台账处置，不覆盖 | 见 `01-facts.md §G` |
| B9 | 不提交这些本地改动 | Web `vite.config.ts` 的端口；Android `TMessagesProj_AppStandalone/build.gradle` 的 abiFilters；任何 `secutg.json`、`watermark_key`、真实 api_id/api_hash |

## C. 测试与运行

| # | 规则 | 说明 |
|---|------|------|
| C1 | **禁止**用真实 Telegram 账号做端到端测试 | 擦除（3.22）会真的清空账号会话。用户用专用号码自己测 |
| C2 | 所有登录由用户操作 | 模拟器、桌面端、网页端一律不替用户登录 |
| C3 | 允许的自动验证：单元测试、编译、`swift test`、`bazel test`、静态检查 | 见各阶段 verify 段 |
| C4 | 编译前看负载 | `uptime`；负载高于核数时先等。用户在意机器变卡 |

## D. 流程

| # | 规则 | 说明 |
|---|------|------|
| D1 | 每个阶段：**preflight → 执行 → verify → 记录** | verify 任一项 FAIL 就停，把 FAIL 原文报告给用户，不自行"修一下继续" |
| D2 | 阶段之间不跳 | `03-runbook.md` 的阶段有依赖顺序 |
| D3 | 需要用户拍板的点（`02-target-topology.md §决策点`）没答复就停在该处 | 不替用户选 |
| D4 | 每完成一个阶段，把结果追加到 `CHECKLIST.md`（日期、命令、关键哈希） | 让下一个执行者能接着做 |
| D5 | 报告要写"做了什么、验证了什么、没做什么" | 不写"应该没问题" |
