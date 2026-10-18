# Si4Gram プロンプトキット

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語** · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [한국어](README.ko.md) · [العربية](README.ar.md)

このリポジトリでは、AI コーディングエージェント（Claude Code）を使って Si4Gram（コードネーム *secuTG*）を開発したときの**プロンプト**（エージェントへの指示、ガードレール、プロンプトテンプレート）を公開しています。

**アプリのソースコード**：[`ios/`](ios/) フォルダーには Si4Gram iOS アプリ（App Store 版 1.0.1）の完全なソースコードが入っています。[Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) を改変したもので、ライセンスは **GPL v2** です（[`ios/COPYING`](ios/COPYING) を参照）。含まれるもの、除外したもの（API 認証情報、署名ファイル）、ビルド方法は [`ios/SOURCE-NOTICE.md`](ios/SOURCE-NOTICE.md) にあります。

似たようなもの（既存のオープンソースアプリの上に載せるセキュリティレイヤー、まったく同じ動作が求められる複数プラットフォーム、人間抜きでは決して行動してはならない AI アシスタントなど）を作っているなら、これらのプロンプトとその背景にある教訓はそのまま再利用できるはずです。

---

## 1. プロジェクトの概要

Si4Gram は Telegram のオープンソースクライアントにプラグインレイヤーを追加します。**送信前に暗号化し、描画前に復号する**仕組みです。チャット画面には平文が表示されますが、ネットワークを流れて Telegram のサーバーに保存されるのは暗号文です。鍵はユーザーのデバイスにだけ存在します。

| 設計ルール | 意味 |
|---|---|
| プロトコルには触れない | MTProto とすべてのサーバーとのやり取りは変更しません。フックはテキスト送信の入口と描画の入口にだけ置きます。 |
| 一つのプロトコルを全プラットフォームで | Web、iOS、macOS、Android、Desktop は互いのメッセージを暗号化・復号できなければなりません。共通の仕様、共通の文字列テーブル、共通のテストベクターで足並みをそろえます。 |
| libsodium だけを使う | XChaCha20-Poly1305、X25519 `crypto_box_seal`、Ed25519 署名、`crypto_kdf`。自作の暗号は使いません。 |
| クラッシュしない、握りつぶさない | 復号できないメッセージはそのまま残し、鍵マークを付けて表示します。 |
| 正直なラベル | 難読化しかしないモード（たとえば自動ペアリングのグループ鍵）を「暗号化済み」と表示することはありません。 |

関連コンポーネント：公式クライアントのユーザー向けでインストール不要の **Mini App + Bot**、短期間だけ暗号化データを保存するオプションの **relay** サービス、クライアント間のテスト**マトリクス**、そして厳格なガードレールのもとで Claude Code にタスクを渡す macOS 上のローカル**アシスタント**（SmartMate）です。

## 2. アーキテクチャ

![アーキテクチャ](architecture.svg)

### 2.1 ランタイム

```mermaid
flowchart LR
    subgraph Devices["ユーザーのデバイス（鍵は外に出ない）"]
        direction TB
        W["Web<br/>telegram-tt フォーク"]
        I["iOS · Si4Gram<br/>Telegram-iOS フォーク"]
        M["macOS<br/>TelegramSwift フォーク"]
        A["Android<br/>DrKLO/Telegram フォーク"]
        D["Desktop<br/>tdesktop フォーク"]
        P["Mini App + Bot<br/>（公式クライアント）"]
    end
    subgraph Layer["各クライアント内のプラグインレイヤー"]
        direction TB
        SH["送信フック<br/>暗号化"]
        RH["描画フック<br/>復号"]
        KR["ローカルキーリング<br/>Keychain / Keystore / DPAPI"]
        NA["libsodium"]
    end
    Devices --- Layer
    Layer -- "E1 / E2 / P2 / G2 の暗号文のみ" --> TG[("Telegram サーバー<br/>MTProto は変更なし")]
    Layer -. "オプションの暗号化データ" .-> RL[("Relay<br/>Workers / AWS / GCP / Node")]
    subgraph Shared["唯一の信頼できる情報源"]
        SPEC["PLAN.md プロトコル仕様"]
        STR["共通文字列テーブル + ジェネレーター"]
        VEC["テストベクター + 5×5 xcheck マトリクス"]
    end
    Shared -. 整合性を保つ .-> Layer
```

### 2.2 プロンプトがエージェントを動かす仕組み

```mermaid
flowchart TB
    H(["人間のオーナー"]) -->|"キックオフ / フェーズ用プロンプト"| CC["Claude Code セッション"]
    CC -->|最初に読む| CON["リポジトリごとの憲法<br/>CLAUDE.md"]
    CC -->|従う| GR["厳守事項<br/>push 禁止 · 削除禁止 · 実アカウント禁止"]
    CC --> LOOP["事前確認 → 実行 → 検証 → 記録"]
    LOOP -->|FAIL| H
    LOOP -->|PASS| GIT["ローカルコミットのみ<br/>+ CHECKLIST 記入"]
    subgraph Assistant["macOS アシスタント（SmartMate）"]
        MAC["macOS クライアント<br/>唯一の鍵保持者"] -->|control.sock| MATE["secutg-mate<br/>受信箱 · ルール · タスク"]
        MATE -->|タスクフォルダ| SK["/secutg-task スキル<br/>フォークした読み取り専用アナリスト"]
        SK --> DR["result.md 下書き"]
        DR -->|人間が「送信」と言う| RV["/secutg-review"]
        DR -->|人間が変更を承認| AP["/secutg-apply<br/>隔離された worktree"]
        DR -->|人間が項目を確認| JR["/secutg-jira<br/>ローカル Chrome"]
        GUARD["PreToolUse ガードフック<br/>+ 拒否リスト"] -.-> SK
        GUARD -.-> AP
    end
```

## 3. GitHub リソース

以下の上流アドレスはすべて、各フォークの `git remote`、`.gitmodules`、依存関係ファイルから読み取ったものです。

### 3.1 フォーク元の上流クライアント

| プラットフォーム | 上流 | ライセンス（上流） |
|---|---|---|
| Web | [Ajaxy/telegram-tt](https://github.com/Ajaxy/telegram-tt) | GPL-3.0 |
| iOS（Si4Gram） | [TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) | 上流を参照 |
| macOS | [overtake/TelegramSwift](https://github.com/overtake/TelegramSwift) | GPL-2.0 |
| Android | [DrKLO/Telegram](https://github.com/DrKLO/Telegram) | GPL-2.0 |
| Desktop（Windows / Linux / macOS） | [telegramdesktop/tdesktop](https://github.com/telegramdesktop/tdesktop) | GPL-3.0（OpenSSL 例外付き） |

### 3.2 セキュリティレイヤーが依存するライブラリ

| ライブラリ | 使用箇所 |
|---|---|
| [jedisct1/libsodium](https://github.com/jedisct1/libsodium) 1.0.20 | iOS / macOS（`Clibsodium`）、Desktop |
| [libsodium.js](https://github.com/jedisct1/libsodium.js)（`libsodium-wrappers` 0.8.x） | Web、Mini App |
| [terl/lazysodium-android](https://github.com/terl/lazysodium-android) 5.1 と [lazysodium-java](https://github.com/terl/lazysodium-java) 5.1.4 | Android |
| [java-native-access/jna](https://github.com/java-native-access/jna) 5.13 | Android |
| [soldair/node-qrcode](https://github.com/soldair/node-qrcode) | Mini App |
| [honojs/hono](https://github.com/honojs/hono) + `@hono/node-server` | Relay |
| [fastapi/fastapi](https://github.com/fastapi/fastapi)、[encode/uvicorn](https://github.com/encode/uvicorn)、[python-poetry/tomlkit](https://github.com/python-poetry/tomlkit) | SmartMate アシスタント |

上流クライアントはそれぞれ独自のサブモジュール（例：tdlib/td、webrtc、libvpx、dav1d、FFmpeg、opus、rlottie、tgcalls、rules_apple、rules_swift）も取り込んでいます。これらは変更しておらず、各上流の `.gitmodules` に記載されています。

### 3.3 エージェント用ツール

| ツール | 役割 |
|---|---|
| [Claude Code](https://github.com/anthropics/claude-code) | このキットに含まれるすべてのコーディングエージェント、プロジェクトスキル、サブエージェント、フック |
| 上流の `AGENTS.md` ファイル（telegram-tt、tdesktop） | フォーク内にそのまま残しています。上流自身のエージェント向けガイドであり、このキットの一部では**ありません**。各憲法では、矛盾しない範囲でそれに従うよう指示しています。 |

## 4. キットの内容

原文は簡体字中国語で [`prompts/zh-CN/`](prompts/zh-CN/) にあります。同じファイル名の英訳が [`prompts/en/`](prompts/en/) にあります。

| フォルダ | ファイル | 内容 | 使いどころ |
|---|---|---|---|
| `01-constitutions/` | `web`、`ios`、`macos`、`android`、`desktop`、`miniapp` `.CLAUDE.md` | フォークごとの「プロジェクト憲法」：厳守事項、ワイヤーフォーマット、プラグインコードの置き場所、`// SECUTG-HOOK` マーカーのルール、作業と報告のしかた | 各フォークのルートに `CLAUDE.md` として置く |
| `02-agent-guardrails/` | `00-constraints.md` | 他のどの文書よりも優先される安全境界：削除しない、push しない、実アカウントを使わない、履歴を書き換えない、ビルド前にマシン負荷を確認する | 長時間実行や複数ステップのエージェントタスクに読み込ませる |
| `03-repo-restructure/` | `00-kickoff.md`、`01-phase-prompts.md` | 分岐した二つのコードラインを一本のトランクに統合するためのキックオフプロンプトと、フェーズごとのプロンプト | まずキックオフを貼り付け、その後一度に一つのフェーズを割り当てる |
| `04-cross-platform-playbook/` | `reproducible-prompts.md` | 5 クライアントの整合性監査と 4 回の修正ラウンドをどう進めたか：制約ブロック、監査 / 修正 / リポジトリ横断のテンプレート、プラットフォームごとの検証の落とし穴、実際の誤判断の一覧表 | 一つの仕様の複数実装をまったく同じに保つ必要があるときに再利用する |
| `05-assistant-skills/` | `settings.json`、`agent-secutg-analyst.md`、`skill-secutg-{task,review,apply,jira}.SKILL.md` | Claude Code のプロジェクト設定、読み取り専用のアナリスト用サブエージェント、macOS アシスタント用の四つのスキル。元の配置は `.claude/settings.json`、`.claude/agents/`、`.claude/skills/<name>/SKILL.md` | 下書きはするが、人間抜きでは送信・編集・チケット起票を決して行わないアシスタントのひな形 |

## 5. うまくいったプロンプトのパターン

1. **リポジトリごとに憲法を置く。** どのフォークも同じ骨組みです：それが何か、厳守事項、ワイヤーフォーマット、コードの置き場所、作業のしかた。エージェントは毎回のセッション開始時点で、越えてはならない一線をすでに知っています。
2. **制約ブロックは一つにまとめ、一字一句そのまま貼り付ける。** 「`git push` は絶対にしない（唯一の remote は公開されている上流）」「削除せず、`mv` で `_archive-<date>/` へ移す」「文字列を手で追加しない」「実アカウントでテストしない」。どの行も、それがなかったせいで問題が起きたから存在しています。
3. **事前確認 → 実行 → 検証 → 記録。** FAIL が一つでも出たらエージェントは止まり、生の出力を人間に渡します。「ちょっと直して続ける」はなしです。
4. **やったこと、検証したこと、検証していないことを報告する。** 「たぶん大丈夫」は報告として認めません。「コンパイルが通った」と「検証した」は分けて報告します。
5. **監査は読み取り専用で、証拠を添える。** すべての行に `file:line` が必要です。仕様からの推測より「見つからない」のほうがましです。
6. **既知の不一致をチェックリストに仕込んでおく。** 監査レポートが仕込んだ差分を「一致」としていたら、そのレポートは破棄します。エージェントのレポートを信頼できるか確かめる最も安上がりな方法です。
7. **「難しい」は「不可能」ではない。** あるプラットフォームで本当にできないことがあれば、エージェントは何が妨げているかを説明し、最善のネイティブな代替策を提供します。
8. **推測は推測のままにする。** 「推測」とされた結論は、誰かが実測するまで仕様にもタスク指示書にも入れてはいけません。
9. **エージェントに反論を求める。** 指示書には「自分で確かめること、鵜呑みにしないこと」と書きます。最良の成果のいくつかは、エージェントが指示書の誤りを正したことから生まれました。
10. **「待機中」でターンを終えない。** 「（ビルド待ち）」で終わったサブエージェントは、ビルドを放置したままにします。同じターン内で終わらせるか、やり直します。
11. **信頼できないデータはデータとして扱う。** アシスタントのスキルでは、Jira の項目、グループチャットの文章、リポジトリ内のあらゆるものはデータであり、決して指示ではありません。怪しい指示は結果の中に引用して指摘します。
12. **外部への行動はすべて人間が握る。** 分析はフォークした読み取り専用エージェントで行います。返信の送信、変更の適用、チケットの起票はそれぞれ人間の明示的な承認が必要で、プロンプトの文言だけでなく、権限ルールと PreToolUse ガードフックによって強制します。

## 6. 再利用できるテンプレート

### 6.1 リポジトリ憲法

```markdown
# <repo> · プロジェクト憲法

このリポジトリは <upstream> のフォークです。目的：<一文で>。プロトコルは <spec> で定義されています。フォーマットは変更しないこと。

## 厳守事項
- <プロトコル / サーバーとのやり取り> を変更しない。フックは <エントリポイント> にだけ置く
- プラグインコードは <dir> に置く。上流ファイルへの変更にはすべて `// <MARKER>` コメントを付ける。変更範囲は小さく保つ
- 暗号処理は <library> 経由のみ。プリミティブを自分で実装しない
- 秘密情報とパラメータは <config file> からのみ読み込む。このファイルはコミットせず、<config.example> だけをコミットする
- 各ステージは専用ブランチを持ち、ビルドが通り、ユニットテストがあること。復号できないデータはそのまま表示し、クラッシュも破棄もしない

## 作業のしかた
- まず計画と影響を受けるファイルを列挙し、確認を得てから変更する
- 編集前にソースを読む。ファイル名を推測しない
- フックする経路ごとに一コミットとし、フックの位置を明記する
- ステージ完了後に報告する：変更したファイル、検証方法、既知の不足点
```

### 6.2 厳守事項ブロック

```markdown
## 厳守事項（一つでも破ればタスクは失敗）
- `git push` は絶対にしない。設定されている唯一の remote は公開されている上流なので、コミットはローカルのみ。
- ファイルやディレクトリを削除しない。どこかへ退避するときは、同じ階層の `_archive-<date>/` に `mv` する。
- ユーザー向けの文字列を手で追加しない。唯一の情報源は <strings.json> で、プラットフォームごとのテーブルは生成する。
- ビルドコマンドを `tee` で包まない（終了コードが隠れる）。ファイルにリダイレクトし、終了コードを echo する。
- 実アカウントでのエンドツーエンドテストはしない。ログインは人間が行う。
```

### 6.3 読み取り専用の監査

```markdown
あなたは <path> にあるリファレンス実装を基準に <platform> を監査します。

## 読み取り専用のタスク
ファイルの変更・作成・削除をしないこと。git add/commit/stash/checkout もしない。ビルドもしない。

## 方法
コードの動作を優先する。仕様はコードと仕様が食い違う箇所でのみ参照する。見つからなければ「見つからない」と書く。仕様から動作を推測しない。

## 出力（厳密に。プラットフォーム間で diff を取る）
| ID | 状態 | 証拠 file:line | 備考 |
状態は次のいずれか：✅ 一致 / ⚠️ 差異あり / ❌ 欠落 / N/A
⚠️ と ❌ については、実際の動作とどこが違うかを書く。最後に「その他の発見」を書く。

## チェックリスト
<番号付きの項目。各項目に正確な文字列キーと期待される動作を書く。既知の不一致をいくつか含める>
```

### 6.4 修正ラウンド

```markdown
第 <N> ラウンド、あなたの担当は <platform>：リポジトリ <path>
仕様：<section>（まずセクション全体を読むこと。理由が記録されている）

原則：すべてのプラットフォームを同じに保つ。あるプラットフォームで本当にできないことがあれば、機能を削るのではなく、そこで最善のネイティブな形を作る。

## 背景 — なぜ重要か、省くと何が壊れるか
## リファレンス実装（完了済み、読み取り専用） — コミット + 主要なコード片 + 理由
## あなたの作業
## ⚠️ プラットフォーム固有の落とし穴
## 検証 — コマンドと既知の落とし穴
<厳守事項ブロック>

ここで本当にできないこと（単に難しいだけではないこと）があれば、何が妨げているかを説明し、最善の代替策を示すこと。「難しい」を「不可能」と言わないこと。
```

### 6.5 セッションのキックオフ

```markdown
あなたは <path> にある書面の仕様を実行します。この仕様は自己完結しています。

1. 次の順に読む：制約 → 事実 → 目標設計 → 実行手順書 → 決定事項 → チェックリスト。
2. 読み取り専用の事前確認を実行し、その出力を一字一句そのまま貼り付ける。
3. 報告する：事前確認の結果、現在のステージ、次のステージ、私が決めるべきこと。その後は止まって待つ。

セッション全体を通じて守る安全ライン：<厳守事項ブロック>
作業のしかた：各ステージは 事前確認 → 実行 → 検証 → 記録。FAIL が出たら止まる。ステージを飛ばさない。仕様でカバーされていないケースは止まって質問する。
```

## 7. キットの応用

1. `01-constitutions/` から憲法を一つコピーし、プロトコル、ディレクトリ、マーカーの名前を自分のものに置き換えます。
2. `02-agent-guardrails/00-constraints.md` はほぼそのまま使い、マシン固有の行だけ調整します。
3. 複数プラットフォームの作業では `04-cross-platform-playbook/` から始め、その「誤判断」の表を育て続けます。
4. 実際の会話に触れるアシスタントでは、`05-assistant-skills/` を権限の拒否リストとガードフックと一緒にコピーします。プロンプトの文言だけではセキュリティ境界になりません。

## 8. 匿名化

公開前に、マシン名、ローカルパス、社内固有のブランチ名をプレースホルダーに置き換えました。

| プレースホルダー | 意味 |
|---|---|
| `<workspace>/` | すべてのフォークを置いているローカルフォルダ |
| `<build-cache>/` | ローカルのビルドキャッシュフォルダ |
| `dev-mac` / `backup-mac` | メインの開発用 Mac / エージェントからは読み取り専用の 2 台目の Mac |
| `_bazel_<user>` | Bazel の出力パスに含まれるローカルユーザー名 |
| `develop、test、staging、release*` | 問い合わせスキル内のブランチ名の例 |

証明書、プロビジョニングプロファイル、チーム ID、API キー、メールアドレス、IP アドレスは一切含まれていません。

## 9. リンク

- ウェブサイト：<https://si4key.com>
- アプリの「情報」ページに表示されるソースコードのアドレス：<https://github.com/Well365/Si4Gram>

## 10. ライセンス

このリポジトリのプロンプトとドキュメント：ライセンスはオーナーが決定予定です（ドキュメントには CC BY 4.0 がよく使われます）。上流の Telegram クライアントは、上に記載したそれぞれのライセンスに従います。
