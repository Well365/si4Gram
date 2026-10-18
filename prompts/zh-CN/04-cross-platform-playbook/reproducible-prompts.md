# secuTG 可复现提示词

> 这份文档记的是**怎么再做一遍**：五端一致性对账与整改所用的提示词结构、各端的验证命令与陷阱、
> 以及踩过的误判。写给下一个接手的人（或下一个 agent）。
>
> 2026-09-18 整理，依据是当天完成的一次完整对账 + 四批整改（五端共 219 个提交、5×5 跨端矩阵 2300 例全过）。

---

## 0. 总则

**一句话原则**（用户定的，贯穿全部任务）：

> 尽量做到五端统一；如果某个做法在某一端确实实现不了，就在那一端做**该平台体验最好的形态**，
> 而不是少做一块功能。

配套的一条防线，必须写进每一份任务里：

> **不要把「难」说成「做不到」。** 如果判断某项确实做不到，如实说明**是什么挡住了**，
> 并给出该平台最好的替代形态。

没有这条，"平台差异"会变成偷懒的出口。

---

## 1. 硬性约束块（粘进每一份 agent 任务）

这一段一字不改地复制进去。少任何一条都出过事。

```
## 硬性约束（违反任何一条都算任务失败）
- **绝不 `git push`**。这些仓库唯一配置的 remote 都是官方公开上游
  （TelegramMessenger/Telegram-iOS、overtake/TelegramSwift、Ajaxy/telegram-tt、
  DrKLO/Telegram、telegramdesktop/tdesktop），只做本地提交。
- **绝不删除任何文件或目录**。`rm` 被本地 hook 拦截。要移走就 `mv` 到同级的 `_archive-<日期>/`。
- **绝不新增字符串**。文案的唯一来源是 `secuTG/src/secutg/i18n/secutg-strings.json`，
  各端的表都是生成产物、绝不手改。真需要新增就停下来报告，走
  `tools/gen-secutg-strings.py` 五端同步。
- `git commit` 所在的那一行 shell 命令里**不能同时出现** `-n` / `-not` / `grep -n`
  （本地 hook 会误判成 `--no-verify`）。用 `git commit -F -` 配 heredoc，且**单独一次**调用。
- **不要用 `tee`** 包住构建命令（会吞掉退出码）；重定向到文件后再 `echo "EXIT=$?"`。
- 不做任何针对真实 Telegram 账号的联调测试。擦除类功能按设计就是破坏性的；登录是用户自己的事。
```

### 各端额外的「绝不提交」名单

| 端 | 绝不提交 |
|---|---|
| Web | `vite.config.ts`（本机端口改动） |
| Android | `TMessagesProj_AppStandalone/build.gradle`（abiFilters） |
| iOS | `bazel-secuTG-ios`（符号链接）、`MODULE.bazel.lock` |
| macOS | `Package.resolved`、`Telegram-Mac/Info.plist`、`TelegramShare/Info.plist` |
| 全部 | 任何 `secutg.json` / `secutg.json.bak-*` |

### 分支

五个客户端仓库后续工作一律在 **`security-tg-branch`** 上。
例外：`secuTG-macos/submodules/telegram-ios` 是另一个仓库，保持在 **`secutg-mac`** 分支。

---

## 2. 各端的验证命令与陷阱

**每一条陷阱都真实发生过。**

### Web — `<workspace>/secuTG`

```bash
source ~/.nvm/nvm.sh && nvm use 24     # 默认 shell 的 node 是 v15，会直接失败
npx tsc --noEmit -p tsconfig.json
npx vitest run src/secutg
```

- **绝不运行 `npm run build`。**
- `src/secutg/hooks/hooks.test.ts` 会报 **4 个**来自 `src/util/schedulers.ts` 的 unhandled error，
  **这是既有的**，不是新引入的。判断时要先 stash 改动复现一次基线。
- 想看渲染效果：`npm run dev:mocked` 直接进已登录状态（`IS_MOCKED_CLIENT`），
  **不需要也不要碰真实账号**。`.env` 里配了自签证书会让浏览器拒连，用
  `HTTPS_CERT_PATH= HTTPS_KEY_PATH=` 覆盖成 http（**不要改 `.env`**）。

### Android — `<workspace>/secuTG-android`

```bash
./gradlew :secutg-core:test --rerun-tasks          # --rerun-tasks 不能省
./gradlew :TMessagesProj:compileDebugJavaWithJavac
```

- **`--rerun-tasks` 省掉会出现假绿。** 这是本项目最容易上当的一条。
- 判断「是不是真编译」不能只看 `BUILD SUCCESSFUL`：要看任务行**有没有 `UP-TO-DATE` 后缀**，
  并**比对 class 文件 mtime**。
- **`.DS_Store` 打断构建：2026-09-18 已在 `build.gradle` 里根治**（`gradle.taskGraph.beforeTask` 守卫），
  原理与实测见 `secuTG-android/docs/secutg/build-dsstore.md`。三条容易想当然的事：
  - **不是 `exclude` / `ignoreAssetsPattern` 能治的。** AGP 资源合并器本来就过滤 `.DS_Store`；
    真正的文件是 macOS 在合并任务**跑完之后**直接写进 AGP 产物目录的，那里没有 `Copy` 任务管得着。
  - **逐个文件搬走也赢不了。** 触发重建的正是 Gradle 自己的递归删除——每删空一个子目录，
    macOS 立刻补一个回来。实测搬走 205 个之后 Gradle 一开始删又回来 4 个，构建照炸。
    有效做法是把被污染的任务输出目录**整体 `rename` 搬走**（单次原子改名，插不进来）。
  - 钩子必须挂 `beforeTask`，**不能挂 `doFirst`**——`doFirst` 排在 Gradle 清理旧输出之后，已经太晚。
  - 守卫只搬不删，落在 `build/tmp/dsstore-quarantine/`；在反复污染的机器上每次构建约留 150 MB。
- 撞到任何 `.DS_Store` 残留都 `mv` 到 `_archive-dsstore-<日期>/`，**绝不 `rm`**。
- 字符串引用形式是 `R.string.<key>`，**不带引号**——用 `git grep '"<key>"'` 查引用会得到 0，误判成零引用。

### Windows — `<workspace>/secuTG-desktop`

```bash
cd Telegram/SourceFiles/secutg/tests
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8 && ./build/secutg_tests
```

- **Qt 主目标在 macOS 上编不了。** 上面那个独立目标**不含任何 Qt 代码**，
  而且其中几项是对**源码文本**做字符串/顺序扫描，不是编译。
  **它的通过数不能读成「能编过」。**
- 所以 Qt/UI 改动必须额外做：括号配平检查 + 逐个 API 对照仓库内现有调用点（把对照过哪些列出来），
  并**明确声明未经真实编译**。
- 增量构建在外接盘上会被同秒时间戳骗过（`make` 以为 `main.cpp` 是最新的而跳过编译）。
  测基线读到不一致的数字时先怀疑这个。
- 已有两道闸，别撞上：`snapshot()` 不能出现在密钥环之外；每个 `Tr("…")` 字面量必须在表里。

### iOS — `<workspace>/secuTG-ios`

```bash
USE_BAZEL_VERSION=8.1.0 bazel build --define=secutgBuild=local \
  --cpu=ios_sim_arm64 --platforms=@build_bazel_apple_support//platforms:ios_sim_arm64 \
  --ios_minimum_os=13.0 //submodules/TelegramUI:TelegramUI
swift test --package-path submodules/SecutgCore
```

- **版本必须是 8.1.0**：默认 bazelisk 解析到 9.x 会在 `third-party/libsodium/BUILD` 失败
  （9 移除了原生 `cc_library`）；7.4.1 会在 `AsyncDisplayKit/BUILD` 失败（`objc_library cxxopts` 需要 8+）。
- 进度可读 `/private/var/tmp/_bazel_<user>/<hash>/command.log`。
- 偶发 `input file was modified during the build`，重试即可。

### macOS — `<workspace>/secuTG-macos`

```bash
xcodebuild -workspace Telegram-Mac.xcworkspace -scheme Telegram -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -skipPackagePluginValidation -skipMacroValidation build
```

- 三个 Firebase framework 的 `Validate` 报错（`GoogleAppMeasurement` / `FirebaseAnalytics` /
  `GoogleAppMeasurementIdentitySupport` 的 Info.plist 位置）是**已知且不可避免**的，
  `VALIDATE_PRODUCT=NO` 也修不掉。判断标准是「除这三条外零 Swift error」。
- 动到子模块 `submodules/telegram-ios` 必须：子模块内提交 → 父仓库 `git add submodules/telegram-ios`
  + **单独的指针提交** → 父仓库功能提交。用 `git submodule status` 确认开头是**空格**（不是 `+`）。

### 跨端矩阵 — `<workspace>/xcheck`

```bash
source ~/.nvm/nvm.sh && nvm use 24     # 必须在调用 python 之前，子进程要继承 PATH
python3 xcheck.py                       # 全量 5×5
python3 xcheck.py --suite k1 --clients web,android
```

- `--suite` 只过滤**生产**，消费端仍按全套找文件，会报一堆 `no vector file` ——
  那是跑法造成的，不是失败。**要判断真结果就跑全量。**
- 改动 `TransferSummary` / 状态机这类**跨端契约**时，五端的 suite 实现必须同时更新，
  否则在过渡期会**双向红**。这是预期的、自愈的——别读成回归。

---

## 3. 提示词模板

### 3.1 对账（审计）

要点：**一份所有端共用的编号清单** + **强制证据** + **预埋已知不一致项**。

```
你在做 secuTG 的五端一致性对账，负责 <端>：仓库 <路径>
对照基准是 Web（<workspace>/secuTG，源码在 src/secutg/）。

## ⚠️ 只读任务
绝对不要修改、创建或删除任何文件，不要 git add/commit/stash/checkout，不要跑构建。

## 方法
用 `git grep -n`（快）而不是 `grep -r`。以**代码实际行为**为准；PLAN.md 只在代码与规范
冲突时做对照。**找不到就写「未找到」，不要根据规范推测代码做了什么。**
这份报告的价值全在于它是否可信。

## 输出格式（严格遵守，要拿五端报告做横向 diff）
`| 编号 | 状态 | 证据 file:line | 说明 |`
状态只用四个：✅一致 / ⚠️有差异 / ❌缺失 / N/A平台不适用
- ⚠️ 和 ❌ 必须写清**实际是什么**（贴实际文案或行为）以及**和基准差在哪**
- 末尾另起一节「额外发现」

## 核对清单
<45 条编号项，每条点名具体的字符串 key 和预期行为>
```

**关键技巧**：清单里**故意放几条已知不一致的**（例如「抢输时该弹的对话框」只有 Windows 有）。
如果某端的报告把这些全标成「一致」，那份报告就不能用。这是唯一能低成本验证报告可信度的办法。

### 3.2 整改

```
secuTG 第 N 批，你负责 <端>：仓库 <路径>
规范：PLAN.md 的 <节号>（先完整读那一节，它记录了为什么这样定）

**总原则**：<§0 的一句话原则>

## 背景
<为什么这是个问题，而不只是不一致。说清"漏掉会怎样">

## 基准实现（已完成，只读参考）
<Web 的提交哈希 + 关键代码片段 + 每个判断的理由>

## 你要做的
<具体项>

## ⚠️ <本端特有的陷阱或反直觉点>
<例如："这次的『设备』和上一次相反"：上次用本机身份，这次要用持有配对的那台>

## 验证
<该端的命令 + 陷阱>

<硬性约束块>

**如果某项在本端确实做不到**（而不是难做），如实说明是什么挡住了，并给出该平台
最好的替代形态——但不要把"难"说成"做不到"。
```

**三条实测有效的写法**：

1. **把其它端已经踩过的坑当前提传下去**，不要让每端各撞一遍。
   例："Android 发现线下密钥是绑定到某个聊天的，所以从没有聊天上下文的地方跳过去没有目的地——
   先确认你这端的实际情况再动手。"
2. **对可疑的既有代码，要求先问"为什么"再改**。
   例："你要动的很可能是那个『把全部 entity 过滤掉』的地方，但**改它之前先弄清当初为什么要过滤**。"
   —— 那次的答案是：它是一道防御，去掉会让对方能伪造指向任意网址的系统行。
3. **明确区分"编译过了"和"验证过了"**，并要求如实标注未验证部分。

### 3.3 跨端协调（共享文件）

iOS 与 macOS 共享 `SecutgRuntime.swift` / `SecutgCore`，但住在**两个不同的 clone** 里
（macOS 的在子模块，URL 指向 `secuTG-ios`），**同一改动在两边哈希不同**。

```
**iOS 是基准，你逐字照抄。**
- 先看子模块里现在是什么状态：改动已经过来了就核对着用，**不要另写一版**
- 没过来就用 `git format-patch` 从对方 checkout 取出原样 apply，然后**逐文件 diff 确认逐字一致**
- 报告里**贴出改动的 hunk 原文**，供另一端对齐
```

同时在两端派 agent 时，**明确禁止其中一端碰共享文件**，需要新 API 就停下来报告。

---

## 4. 踩过的误判

**这一节比模板更有用。** 每一条都真实发生，且都曾以"看起来完成了"的形态存在过。

| 误判 | 真相 | 怎么避免 |
|---|---|---|
| 「只有 Web 有明文提示条」 | Web 那份是**死代码**——判据问「没有 secuTG 标记」，而系统恰恰给这些明文打了标记，条件永远为假。**五端其实一个都没有** | 审计能查「代码在不在」，查不出「它会不会被触发」。对**从未见人用过**的功能，要额外问一句"什么情况下它会出现" |
| 「Android 用持久事件队列，三种里最稳」 | 是纯内存 static 列表，上限 64，进程被杀就没了 | 形容词（"持久"、"最稳"）必须有代码支撑，不能从注释或命名推断 |
| 「晚接受该弹的框只做了系统行」（说成五端通病） | 那是 Web 的情况，**Windows 真的实现了** | 只看一端就下"五端"结论，是本次最容易犯的错 |
| 「两个擦除开关关掉都该确认」 | 规范只要求一个；另一个本来就没要求。而且 iOS/macOS 都做了 | 引用规范前先读原文，别凭印象 |
| 「PLAN 3.28 的 🆘 按钮五端已实现」 | 只有三端。iOS/macOS 上 `🆘` 只出现在 emoji 数据文件里 | 会话早期的记录也可能是错的；收尾时重新 grep 一遍 |
| 生成器 bug 的诊断「转义引号打断解析」 | 实际是**英文文案里的分号**——`readStrings.ts` 先按 `;` 切记录 | 开任务卡时的猜测要标成猜测；查实后如果错了，**撤掉卡**而不是留着误导 |
| 「那条 `E1`「🔒 加密已开启」由接受方 B 发出」 | **由发起方 A 发出**（A 收到 B 的 `P1` 完成绑定时）。Web 代码里那行注释原文就是 `the inviter sends the confirmation` | 时序图里谁发哪条消息，必须去看**发送点**的代码，不能从"谁先完成绑定"推。这条错了整整六个版本 |
| 「出局设备上有**两个**还能点的〔接受〕」（写进了规范和三份任务书） | 控制行那条在**点击时**会复查活的 keyring，按钮根本不画。真正开着的只有**邀请对话框**（弹出时查、点击时不查） | 来源那份核验给这条标的是「**推断**」，我当成实测用了。**标着推断的结论不能进规范、不能进任务书**——要么去实测，要么在下游继续标着推断 |
| 「iOS 与 macOS 的 SecutgCore 逐字节相同」 | `Rekey/*`、`Transfer/*`、`Crypto/*` 相同；`Keyring/KeyRing.swift`、`SnapshotCodec.swift`、`Config/*`、`Guide/*` 不同，另有 14 个文件只在一侧存在 | 「共享代码」是个会随时间漂的说法。派移植前先 `diff -rq`，让 agent 把结果报回来 |

### 两条方法论

**① 让 agent 反驳你。** 几次最有价值的产出都来自 agent 纠正简报里的前提：
Android 指出「控制行文本是落库的，不是渲染的」（用 entity 会把按钮文字永久烘进存储）；
Windows 指出 `isAdmin` 的真实含义让缺陷范围比描述的更大；
复审 agent 拒绝了另一个 agent"东西已提交、看那个范围"的说法，自己去核实后才接受。
**所以简报里要写「请自行复核，不要直接采信」。**

**② 不要用"等待"作为一个回合的结尾。** subagent 如果以「（等构建）」结束回合，
那个构建就没人收尾了——它要么白跑，要么随回合停掉。本次会话发生过两次。
任务里要写明：要么在同一回合里跑完，要么重跑。

---

## 5. 一次完整复现的顺序

1. **对账**：五端并行，只读，同一份编号清单，预埋已知不一致项验证报告可信度
2. **横向 diff**：把五份报告对成一张矩阵，按「用户会不会因此丢数据或被误导」排severity
3. **分类**：Web 该改的 / 其它端该补的 / 平台惯例不该统一的 / 五端一起改的 / 需要拍板的
4. **把「需要拍板的」写进规范**（PLAN 3.30 就是这么来的）——**理由比结论重要**，
   下一个看到不一致的人需要知道当初是不是想过
5. **分批整改**：小而高价值的先做；跨端契约类的最后做，因为要五端同时落地
6. **收尾验证**：各端单测 + **全量 5×5 跨端矩阵**。后者是唯一能证明五端在说同一种语言的证据

---

## 附：关键路径速查

| 东西 | 位置 |
|---|---|
| 规范（唯一权威） | `secuTG/PLAN.md` |
| 文案唯一来源 | `secuTG/src/secutg/i18n/secutg-strings.json` |
| 文案生成器 | `secuTG/tools/gen-secutg-strings.py`（`--web --android <root> --swift <path> --cpp <path>`；**不带参数只校验、不写文件**） |
| 跨端矩阵 | `xcheck/`（`xcheck.py`、`inputs.json`、`tools/gen-inputs.mjs`） |
| 仓库重组规范 | `secutg-repo-spec/` |
| 构建产物 | `dist/` |
| 本文档 | `secuTG-docs/` |
