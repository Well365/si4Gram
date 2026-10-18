# 分阶段提示词（指派某一阶段时粘对应一段）

> 前提：该会话已经用过 `00-kickoff.md`，模型已经读过规范。
> 如果是新会话，先粘 `00-kickoff.md`，再粘这里的某一段。

---

## 阶段 0 · 安全归档与预检

```
执行 03-runbook.md 的阶段 0。

这个阶段只增不减、无风险：建三个回滚标签、把 secuTG-macos 工作区已有的改动单独提交或另存、报告子模块里那个 stash、把 backup-mac 救援补丁逐文件分类。

四件事要特别注意：
1. 那个 stash 只报告，不要 pop 也不要 drop。它的内容已经全部在 HEAD 和 master 里，是过时的。
2. 两个 Info.plist 的构建号改动必须单独处置，不能留在工作区，否则后面的 git add 会把它卷进同步提交。
3. backup-mac 补丁的分类要用 git apply --check 逐文件跑正向和反向，不要只 grep 核心路径。已知 spm.bzl 和 PeerInfoScreenPerformButtonAction.swift 是 dev-mac 没有的，把完整清单列给我，不要自行应用。
4. 标签只创建，永不删除。

做完把 verify 的三条命令输出原样贴给我，然后停。
```

---

## 阶段 1 · 修悬空 gitlink，收拾 iOS 工作树

```
执行 03-runbook.md 的阶段 1。

这个阶段修的是一个现在就存在的故障：从 secuTG-macos 新克隆装不起来。我已经实测过，两个原因叠加，一个是 git 默认禁止子模块走本地路径，一个是 iOS 仓库里根本没有 gitlink 指向的那个提交。这一阶段修第二个。

顺序别乱：先把 iOS 里那个过期的 secutg-mac 分支改名成 archive，再把 mac 子模块的真实 secutg-mac 推进去。反过来会撞名。

1c 那 31 行水印向量要提交到 master，不是提交到 3.22 分支上——它属于 3.21。
1d 的 .gitignore 模式必须带前导斜杠写成 /bazel-secuTG-ios，写成 bazel-* 会连带忽略 build-system/bazel-rules/ 目录。
1e 只有在我对决策单 Q4 答了 A 的情况下才做。

本阶段的真正验收是那个新克隆实测，一定要跑，把输出贴给我。测完用 mv 把临时目录移进 scratchpad 的 _archive-*，不要 rm。
```

---

## 阶段 2 · 在 master 上把共享层补齐

```
执行 03-runbook.md 的阶段 2。

开始之前先确认：我对决策单 Q1 到 Q5 的答复是什么？没有答复就停在这里问我，不要用默认值往下走。

这个阶段的目标是让 master 的三个镜像路径成为两条线能力的并集，这样镜像过去不会让 mac 丢东西。

2b 是最容易漏的一条，它是对抗审查发现的：mac 的 TextUtils.pullText 是聊天列表、回复预览、通知、搜索共用的漏斗，源码注释明确写了它拿不到 account，所以它用的是 mac 独有的免账号读取 API。那个 API 在镜像路径里会被覆盖掉，而 master 唯一的读侧 API 要求传 accountPeerId。mac 有 7 个调用点靠它。不先把免账号入口上送 master，阶段 4 必然卡死。

2c① 不要用 cherry-pick，那个提交还改了 mac 侧三个文件，必然冲突并留下 sequencer 状态。用手册里给的 git diff 管道接 git apply --index 的写法，已经验证过是干净的。

2c④ 搬 SecutgGuideData 的同时必须改 Web 仓库里生成器的输出路径，否则下次重新生成会在旧路径再产出一个同名类型，同时 import 两个模块的文件会拿到歧义符号。

每一项一个提交，每项之后跑一次 swift test。做完把用例数和阶段 1 的基线对比给我看。
```

---

## 阶段 3 · 装脚本和护栏

```
执行 03-runbook.md 的阶段 3。

把 secutg-repo-spec/scripts/secutg-sync-from-ios.sh 装进 secuTG-macos/scripts/，装 pre-commit 钩子，开两个 git 配置。

脚本我已经在真实仓库上跑过 --check，输出与测绘吻合（32 文件 +1434/-1516，8 个文件会被删，SECUTG-HOOK 差集三个已知文件）。你装完再跑一次确认一致。

pre-commit 钩子的验收要真的试一次：在子模块里造一个文件、git add、尝试提交，确认被拒绝。然后 git reset 并把文件 mv 进 scratchpad，不要 rm。

钩子不入库，这一点要写进 CLAUDE.md，新克隆需要重装。
```

---

## 阶段 4 · 首次镜像加一次性移植

```
执行 03-runbook.md 的阶段 4。这是唯一有实质工作量的阶段，预算 1 到 2 个工作日。

先跑 --check，把 DELETED 清单贴给我确认，我确认之后你再 --apply --stage-only。

中途 mac 编不过是正常的，不要因此回滚。首次镜像必须 --stage-only，和胶水改动一起合成一个提交。中途如果你在 master 上又改了共享代码，直接重跑 --apply --stage-only 即可回灌，脚本的前置检查只看镜像路径，不要求整个子模块干净。

4c 的清单里这两条是对抗审查发现的，别漏：
- ChatMessageItem.swift 第 293 行的 switch 有 4 个 case、没有 default，镜像后 Kind 多一个 sealed 值就变成非穷尽，主 target 和 TelegramShare 两个 target 都编译失败。必须加分支。
- TextUtils.swift 第 73 行的条件漏掉 sealed，这个不报错但运行期出错，封存消息在聊天列表和通知里显示不出来。

SecutgGuideWindow 和 SecutgPhoneView 是约 250 行重写，不是改十几处，工时按这个估。

编译前先看 uptime，负载高于核数就等一等。每轮把 error 计数记进 stage9-mirror.md。

4d 的 git add 要逐文件列，不要 add Telegram-Mac 整个目录。

做完跑 verify 的四条命令，其中 90-drift-check.sh 要带 --phase 4，这时层 1 应该零差异。记得把 drift-allowlist.txt 里"阶段 4 合并设计前的临时登记"那一段删掉。
```

---

## 阶段 5 · 字符串表统一

```
执行 06-strings-canonicalization.md。这一阶段独立于仓库重组，随时可做。

现状是三套键名并存：Web 和 Android 用生成器产出的规范名，iOS 和 Windows 的生成文件都被手改过。iOS 那 34 个手写键目前没有任何 UI 代码引用，所以直接重新生成就行。Windows 有 15 个自创名且 glue.cpp 里有 12 处引用，要改调用点。

改 Windows 调用点时逐处改，不要用 sed 全局替换——SecutgWipeListens 是 SecutgWipeListensOn 的前缀，全局替换会改坏。

先往规范源 JSON 加那 8 个缺的键（文案直接从 iOS 和 Windows 现有表里抄，文档里列了对照），验证 JSON 能解析，再跑生成器。

Windows 端在 dev-mac 上编不了 Qt，改完由我在别处编译确认。验证那两段命令都要跑，把输出贴给我。
```

---

## 阶段 6 · 验证与文档

```
执行 03-runbook.md 的阶段 6。

运行验证那一部分是我的活，你不要碰真实账号。你把验证清单整理好给我，我自己跑完把结果告诉你，你记进 stage9-mirror.md。

文档部分是你的活：新建 stage9-mirror.md，改 stage8-macos-status.md 的顶部和那两处失实记载，两个仓库的 CLAUDE.md 各加一段纪律说明，更新两个记忆文件。

CLAUDE.md 那段必须包含：镜像路径禁止手改、共享目录只用白名单 API、新检出要带 protocol.file.allow 且绝不带 --recursive、.gitmodules 保持绝对路径换机器用本机 config 覆盖、pre-commit 钩子不入库要重装、guide 生成器输出路径已改。
```
