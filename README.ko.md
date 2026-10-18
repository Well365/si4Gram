# Si4Gram Prompt Kit

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · **한국어** · [العربية](README.ar.md)

이 저장소는 AI 코딩 에이전트(Claude Code)로 Si4Gram(코드명 *secuTG*)을 만들 때 사용한 **프롬프트**를 공개합니다. 앱 소스 코드는 들어 있지 않습니다. 앱은 대형 업스트림 Telegram 클라이언트 여러 개를 포크해 로컬에서 많이 수정한 것이라, 여기서는 에이전트 지침, 가드레일, 프롬프트 템플릿만 공개합니다.

비슷한 것을 만들고 있다면(기존 오픈소스 앱 위에 올리는 보안 레이어, 똑같이 동작해야 하는 여러 플랫폼, 또는 사람 없이는 절대 행동해서는 안 되는 AI 어시스턴트) 이 프롬프트와 그 뒤에 있는 교훈을 그대로 가져다 쓸 수 있을 것입니다.

---

## 1. 프로젝트가 하는 일

Si4Gram은 Telegram 오픈소스 클라이언트에 플러그인 레이어를 더합니다. **보내기 전에 암호화하고, 화면에 그리기 전에 복호화합니다.** 채팅 창에는 평문이 보이지만, 네트워크를 오가고 Telegram 서버에 저장되는 것은 암호문입니다. 키는 사용자의 기기에만 있습니다.

| 설계 원칙 | 의미 |
|---|---|
| 프로토콜은 건드리지 않는다 | MTProto와 모든 서버 상호작용은 그대로 둡니다. 훅은 텍스트 전송 진입점과 렌더링 진입점에만 둡니다. |
| 하나의 프로토콜, 모든 플랫폼 | Web, iOS, macOS, Android, Desktop은 서로의 메시지를 암호화하고 복호화할 수 있어야 합니다. 공유 명세, 공유 문자열 테이블, 공유 테스트 벡터로 서로를 맞춥니다. |
| libsodium만 사용한다 | XChaCha20-Poly1305, X25519 `crypto_box_seal`, Ed25519 서명, `crypto_kdf`. 직접 만든 암호는 쓰지 않습니다. |
| 절대 죽지 않고, 절대 삼키지 않는다 | 복호화할 수 없는 메시지는 그대로 보존하고 자물쇠 배지와 함께 표시합니다. |
| 정직한 표시 | 난독화만 하는 모드(예: 자동 페어링 그룹 키)는 절대 "암호화됨"으로 표시하지 않습니다. |

함께 쓰는 구성 요소: 공식 클라이언트 사용자를 위한 설치 없는 **Mini App + Bot**, 수명이 짧은 암호화 blob을 저장하는 선택형 **relay** 서비스, 클라이언트 간 테스트 **매트릭스**, 그리고 엄격한 가드레일 아래 Claude Code에 작업을 넘기는 macOS용 로컬 **어시스턴트**(SmartMate).

## 2. 아키텍처

![아키텍처](architecture.svg)

### 2.1 런타임

```mermaid
flowchart LR
    subgraph Devices["사용자 기기 (키는 밖으로 나가지 않음)"]
        direction TB
        W["Web<br/>telegram-tt 포크"]
        I["iOS · Si4Gram<br/>Telegram-iOS 포크"]
        M["macOS<br/>TelegramSwift 포크"]
        A["Android<br/>DrKLO/Telegram 포크"]
        D["Desktop<br/>tdesktop 포크"]
        P["Mini App + Bot<br/>(공식 클라이언트)"]
    end
    subgraph Layer["모든 클라이언트의 플러그인 레이어"]
        direction TB
        SH["전송 훅<br/>암호화"]
        RH["렌더링 훅<br/>복호화"]
        KR["로컬 키링<br/>Keychain / Keystore / DPAPI"]
        NA["libsodium"]
    end
    Devices --- Layer
    Layer -- "E1 / E2 / P2 / G2 암호문만" --> TG[("Telegram 서버<br/>MTProto 변경 없음")]
    Layer -. "선택형 암호화 blob" .-> RL[("Relay<br/>Workers / AWS / GCP / Node")]
    subgraph Shared["단일 진실 공급원"]
        SPEC["PLAN.md 프로토콜 명세"]
        STR["공유 문자열 테이블 + 생성기"]
        VEC["테스트 벡터 + 5×5 xcheck 매트릭스"]
    end
    Shared -. 정렬 유지 .-> Layer
```

### 2.2 프롬프트가 에이전트를 움직이는 방식

```mermaid
flowchart TB
    H(["사람 책임자"]) -->|"킥오프 / 단계별 프롬프트"| CC["Claude Code 세션"]
    CC -->|먼저 읽음| CON["저장소별 헌법<br/>CLAUDE.md"]
    CC -->|따름| GR["강제 제약<br/>push 금지 · 삭제 금지 · 실계정 금지"]
    CC --> LOOP["사전 점검 → 실행 → 검증 → 기록"]
    LOOP -->|FAIL| H
    LOOP -->|PASS| GIT["로컬 커밋만<br/>+ CHECKLIST 항목"]
    subgraph Assistant["macOS 어시스턴트 (SmartMate)"]
        MAC["macOS 클라이언트<br/>유일한 키 보유자"] -->|control.sock| MATE["secutg-mate<br/>받은편지함 · 규칙 · 작업"]
        MATE -->|작업 폴더| SK["/secutg-task 스킬<br/>포크된 읽기 전용 분석가"]
        SK --> DR["result.md 초안"]
        DR -->|사람이 “보내”라고 함| RV["/secutg-review"]
        DR -->|사람이 변경 승인| AP["/secutg-apply<br/>격리된 worktree"]
        DR -->|사람이 필드 확인| JR["/secutg-jira<br/>로컬 Chrome"]
        GUARD["PreToolUse 가드 훅<br/>+ 거부 목록"] -.-> SK
        GUARD -.-> AP
    end
```

## 3. GitHub 리소스

아래의 모든 업스트림 주소는 각 포크의 `git remote`, `.gitmodules`, 의존성 파일에서 읽어 온 것입니다.

### 3.1 포크한 업스트림 클라이언트

| 플랫폼 | 업스트림 | 라이선스 (업스트림) |
|---|---|---|
| Web | [Ajaxy/telegram-tt](https://github.com/Ajaxy/telegram-tt) | GPL-3.0 |
| iOS (Si4Gram) | [TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) | 업스트림 참조 |
| macOS | [overtake/TelegramSwift](https://github.com/overtake/TelegramSwift) | GPL-2.0 |
| Android | [DrKLO/Telegram](https://github.com/DrKLO/Telegram) | GPL-2.0 |
| Desktop (Windows / Linux / macOS) | [telegramdesktop/tdesktop](https://github.com/telegramdesktop/tdesktop) | GPL-3.0 (OpenSSL 예외 포함) |

### 3.2 보안 레이어가 의존하는 라이브러리

| 라이브러리 | 사용처 |
|---|---|
| [jedisct1/libsodium](https://github.com/jedisct1/libsodium) 1.0.20 | iOS / macOS (`Clibsodium`), Desktop |
| [libsodium.js](https://github.com/jedisct1/libsodium.js) (`libsodium-wrappers` 0.8.x) | Web, Mini App |
| [terl/lazysodium-android](https://github.com/terl/lazysodium-android) 5.1 및 [lazysodium-java](https://github.com/terl/lazysodium-java) 5.1.4 | Android |
| [java-native-access/jna](https://github.com/java-native-access/jna) 5.13 | Android |
| [soldair/node-qrcode](https://github.com/soldair/node-qrcode) | Mini App |
| [honojs/hono](https://github.com/honojs/hono) + `@hono/node-server` | Relay |
| [fastapi/fastapi](https://github.com/fastapi/fastapi), [encode/uvicorn](https://github.com/encode/uvicorn), [python-poetry/tomlkit](https://github.com/python-poetry/tomlkit) | SmartMate 어시스턴트 |

업스트림 클라이언트는 자체 서브모듈도 가져옵니다(예: tdlib/td, webrtc, libvpx, dav1d, FFmpeg, opus, rlottie, tgcalls, rules_apple, rules_swift). 이들은 수정하지 않았으며 각 업스트림의 `.gitmodules`에 나와 있습니다.

### 3.3 에이전트 도구

| 도구 | 역할 |
|---|---|
| [Claude Code](https://github.com/anthropics/claude-code) | 이 키트의 모든 코딩 에이전트, 프로젝트 스킬, 서브에이전트, 훅 |
| 업스트림 `AGENTS.md` 파일 (telegram-tt, tdesktop) | 포크에 그대로 남겨 두었습니다. 업스트림이 직접 만든 에이전트 가이드이며 이 키트에는 **포함되지 않습니다**. 각 헌법은 충돌하지 않는 범위에서 이를 따르라고 명시합니다. |

## 4. 키트 구성

원본은 [`prompts/zh-CN/`](prompts/zh-CN/)에 중국어 간체로 있고, 같은 파일 이름의 영어 번역이 [`prompts/en/`](prompts/en/)에 있습니다.

| 폴더 | 파일 | 내용 | 사용 시점 |
|---|---|---|---|
| `01-constitutions/` | `web`, `ios`, `macos`, `android`, `desktop`, `miniapp` `.CLAUDE.md` | 포크마다 하나씩 있는 "프로젝트 헌법": 강제 제약, 와이어 포맷, 플러그인 코드 위치, `// SECUTG-HOOK` 마커 규칙, 작업 및 보고 방식 | 각 포크의 루트에 `CLAUDE.md`로 둡니다 |
| `02-agent-guardrails/` | `00-constraints.md` | 다른 모든 문서보다 우선하는 안전 경계: 삭제 금지, push 금지, 실계정 사용 금지, 히스토리 재작성 금지, 빌드 전 머신 부하 확인 | 오래 걸리거나 여러 단계로 이뤄진 에이전트 작업에 불러옵니다 |
| `03-repo-restructure/` | `00-kickoff.md`, `01-phase-prompts.md` | 갈라진 두 코드 라인을 하나의 트렁크로 합치기 위한 킥오프 프롬프트와 단계별 프롬프트 | 킥오프를 먼저 붙여 넣고, 그다음 한 번에 한 단계씩 맡깁니다 |
| `04-cross-platform-playbook/` | `reproducible-prompts.md` | 다섯 클라이언트의 일관성 감사와 네 차례의 수정을 어떻게 진행했는지: 제약 블록, 감사 / 수정 / 저장소 간 템플릿, 플랫폼별 검증 함정, 실제 오판 사례 표 | 하나의 명세를 여러 구현이 똑같이 유지해야 할 때 재사용합니다 |
| `05-assistant-skills/` | `settings.json`, `agent-secutg-analyst.md`, `skill-secutg-{task,review,apply,jira}.SKILL.md` | Claude Code 프로젝트 설정, 읽기 전용 분석가 서브에이전트, macOS 어시스턴트용 스킬 네 개. 원래 위치는 `.claude/settings.json`, `.claude/agents/`, `.claude/skills/<name>/SKILL.md` | 초안은 쓰지만 사람 없이는 절대 보내거나 수정하거나 티켓을 등록하지 않는 어시스턴트의 패턴 |

## 5. 효과가 있었던 프롬프트 패턴

1. **저장소마다 헌법 하나.** 모든 포크가 같은 뼈대를 갖습니다: 무엇인지, 강제 제약, 와이어 포맷, 코드 위치, 작업 방식. 에이전트는 매 세션을 레드라인을 이미 아는 상태로 시작합니다.
2. **제약 블록 하나를 글자 그대로 붙여 넣기.** "절대 `git push` 하지 않는다(유일한 remote는 공개 업스트림이다)", "절대 삭제하지 말고 `_archive-<date>/`로 `mv` 한다", "문자열을 손으로 추가하지 않는다", "실계정으로 테스트하지 않는다". 각 줄은 그것이 없어서 문제가 생겼기 때문에 존재합니다.
3. **사전 점검 → 실행 → 검증 → 기록.** FAIL이 하나라도 나면 에이전트는 멈추고 원본 출력을 사람에게 넘깁니다. "빨리 고치고 계속하기"는 없습니다.
4. **한 것, 검증한 것, 검증하지 않은 것을 보고하기.** "아마 괜찮을 것"은 받아들일 수 있는 보고가 아닙니다. "컴파일됐다"와 "검증됐다"는 따로 보고합니다.
5. **감사는 읽기 전용이며 근거를 단다.** 모든 행에 `file:line`이 필요합니다. 명세를 보고 추측하는 것보다 "찾지 못함"이 낫습니다.
6. **알려진 불일치를 체크리스트에 심어 두기.** 감사 보고서가 심어 둔 차이를 "일치"로 표시하면 그 보고서는 폐기합니다. 에이전트의 보고를 믿을 수 있는지 시험하는 가장 저렴한 방법입니다.
7. **"어렵다"는 "불가능하다"가 아니다.** 어떤 플랫폼에서 정말로 할 수 없는 일이라면, 에이전트는 무엇이 막고 있는지 말하고 최선의 네이티브 대안을 내놓습니다.
8. **추론은 추론으로 남는다.** "추론"으로 표시된 결론은 누군가 측정하기 전까지 명세나 작업 지시서에 들어갈 수 없습니다.
9. **에이전트에게 반박을 요청하기.** 지시서에는 "직접 검증하고, 그냥 믿지 말라"고 씁니다. 가장 좋은 결과 중 몇 가지는 에이전트가 지시서를 바로잡은 데서 나왔습니다.
10. **"대기 중"으로 턴을 끝내지 않기.** "(빌드 대기 중)"으로 끝나는 서브에이전트는 빌드를 고아로 남깁니다. 같은 턴 안에 끝내거나 다시 실행합니다.
11. **신뢰할 수 없는 데이터는 데이터로 표시한다.** 어시스턴트 스킬에서 Jira 필드, 그룹 채팅 텍스트, 저장소 안의 모든 것은 데이터이며 절대 지시가 아닙니다. 의심스러운 지시는 결과에 인용하고 표시합니다.
12. **밖으로 향하는 모든 행동은 사람이 쥔다.** 분석은 포크된 읽기 전용 에이전트에서 실행됩니다. 답장 보내기, 변경 적용하기, 티켓 등록하기는 각각 사람의 명시적 승인이 필요하며, 이는 프롬프트 문구만이 아니라 권한 규칙과 PreToolUse 가드 훅으로 강제됩니다.

## 6. 재사용 가능한 템플릿

### 6.1 저장소 헌법

```markdown
# <repo> · 프로젝트 헌법

이 저장소는 <upstream>의 포크입니다. 목표: <한 문장>. 프로토콜은 <spec>에 정의되어 있으며, 포맷을 바꾸지 마세요.

## 강제 제약
- <프로토콜 / 서버 상호작용>을 바꾸지 말 것. 훅은 <진입점>에만 둘 것
- 플러그인 코드는 <dir>에 둔다. 업스트림 파일을 바꿀 때마다 `// <MARKER>` 주석을 단다. 변경 범위를 작게 유지한다
- 암호는 <라이브러리>로만 사용한다. 기본 연산을 직접 구현하지 않는다
- 비밀 값과 매개변수는 <설정 파일>에서만 읽는다. 이 파일은 절대 커밋하지 않고 <config.example>만 커밋한다
- 단계마다 자체 브랜치가 있고, 빌드되며, 단위 테스트가 있다. 복호화할 수 없는 데이터는 그대로 표시하고, 절대 죽지 않고, 절대 버리지 않는다

## 작업 방식
- 먼저 계획과 영향받는 파일을 나열하고, 확인을 받은 뒤에만 변경한다
- 편집하기 전에 소스를 읽는다. 파일 이름을 추측하지 않는다
- 훅을 단 경로마다 커밋 하나, 커밋에 훅 위치를 적는다
- 한 단계가 끝나면 보고한다: 바꾼 파일, 검증 방법, 알려진 빈틈
```

### 6.2 강제 제약 블록

```markdown
## 강제 제약 (하나라도 어기면 작업 실패)
- 절대 `git push` 하지 않는다. 설정된 유일한 remote는 공개 업스트림이며, 로컬에만 커밋한다.
- 파일이나 디렉터리를 절대 삭제하지 않는다. 치워야 할 것은 같은 위치의 `_archive-<date>/`로 `mv` 한다.
- 사용자에게 보이는 문자열을 손으로 추가하지 않는다. 유일한 원본은 <strings.json>이며, 플랫폼별 테이블은 생성한다.
- 빌드 명령을 `tee`로 감싸지 않는다(종료 코드를 가린다). 파일로 리디렉션한 뒤 종료 코드를 출력한다.
- 실계정으로 엔드투엔드 테스트를 하지 않는다. 로그인은 사람이 한다.
```

### 6.3 읽기 전용 감사

```markdown
<path>의 참조 구현을 기준으로 <플랫폼>을 감사합니다.

## 읽기 전용 작업
어떤 파일도 수정, 생성, 삭제하지 말 것. git add/commit/stash/checkout 금지. 빌드 금지.

## 방법
코드의 동작이 우선한다. 코드와 명세가 다를 때만 명세를 참고한다. 찾지 못하면 "찾지 못함"이라고 쓴다. 명세로부터 동작을 추론하지 않는다.

## 출력 (엄격, 플랫폼 간에 diff로 비교함)
| ID | 상태 | 근거 file:line | 비고 |
상태는 다음 중 하나: ✅ 일치 / ⚠️ 다름 / ❌ 없음 / N/A
⚠️와 ❌에는 실제로 어떻게 동작하는지, 무엇이 다른지 적는다. 마지막에 "추가 발견 사항"으로 끝낸다.

## 체크리스트
<번호 매긴 항목. 각 항목에 정확한 문자열 키와 기대 동작을 적는다. 알려진 불일치 몇 개를 포함한다>
```

### 6.4 수정 라운드

```markdown
<N>차 라운드, 담당 플랫폼은 <플랫폼>: 저장소 <path>
명세: <섹션> (먼저 섹션 전체를 읽을 것. 이유가 기록되어 있음)

원칙: 모든 플랫폼을 똑같이 유지한다. 어떤 플랫폼에서 정말로 할 수 없는 일이 있으면 기능을 빼지 말고 그곳에서 가능한 최선의 네이티브 형태를 만든다.

## 배경 — 왜 중요한지, 건너뛰면 무엇이 깨지는지
## 참조 구현 (완료, 읽기 전용) — 커밋 + 핵심 코드 조각 + 근거
## 맡은 작업
## ⚠️ 플랫폼 고유의 함정
## 검증 — 명령과 알려진 함정
<강제 제약 블록>

여기서 정말로 할 수 없는 일이라면(단지 어려운 것이 아니라) 무엇이 막고 있는지 말하고 최선의 대안을 제시한다. "어렵다"를 "불가능하다"라고 부르지 않는다.
```

### 6.5 세션 킥오프

```markdown
<path>에 작성된 명세를 실행합니다. 이 명세만으로 완결됩니다.

1. 순서대로 읽는다: 제약 → 사실 → 목표 설계 → 런북 → 결정 사항 → 체크리스트.
2. 읽기 전용 사전 점검을 실행하고 출력을 그대로 붙여 넣는다.
3. 보고한다: 사전 점검 결과, 현재 단계, 다음 단계, 내가 내려야 할 결정. 그런 다음 멈추고 기다린다.

세션 내내 유지되는 안전선: <강제 제약 블록>
작업 방식: 모든 단계는 사전 점검 → 실행 → 검증 → 기록. FAIL이 하나라도 나면 멈춘다. 단계를 건너뛰지 않는다. 명세가 다루지 않는 경우가 생기면 멈추고 묻는다.
```

## 7. 키트를 자기 프로젝트에 맞추기

1. `01-constitutions/`에서 헌법 하나를 복사해 프로토콜, 디렉터리, 마커 이름을 자신의 것으로 바꿉니다.
2. `02-agent-guardrails/00-constraints.md`는 거의 그대로 유지하고, 머신별 항목만 조정합니다.
3. 여러 플랫폼 작업이라면 `04-cross-platform-playbook/`에서 시작하고, 그 "오판" 표를 계속 늘려 갑니다.
4. 실제 대화를 다루는 어시스턴트라면 `05-assistant-skills/`를 권한 거부 목록, 가드 훅과 함께 복사합니다. 프롬프트 문구만으로는 보안 경계가 되지 않습니다.

## 8. 민감 정보 제거

공개하기 전에 머신 이름, 로컬 경로, 회사 고유의 브랜치 이름을 플레이스홀더로 바꿨습니다.

| 플레이스홀더 | 의미 |
|---|---|
| `<workspace>/` | 모든 포크가 들어 있는 로컬 폴더 |
| `<build-cache>/` | 로컬 빌드 캐시 폴더 |
| `dev-mac` / `backup-mac` | 주 개발용 Mac / 에이전트에게는 읽기 전용인 두 번째 Mac |
| `_bazel_<user>` | Bazel 출력 경로에 들어가는 로컬 사용자 이름 |
| `develop、test、staging、release*` | 조회 스킬에 나오는 예시 브랜치 이름 |

인증서, 프로비저닝 프로파일, 팀 ID, API 키, 이메일, IP 주소는 포함되어 있지 않습니다.

## 9. 링크

- 웹사이트: <https://si4key.com>
- 앱의 정보(About) 페이지에 표시되는 소스 주소: <https://github.com/Well365/Si4Gram>

## 10. 라이선스

이 저장소의 프롬프트와 문서: 소유자가 결정할 예정입니다(문서에는 CC BY 4.0이 흔히 쓰입니다). 업스트림 Telegram 클라이언트는 위에 적힌 각자의 라이선스를 유지합니다.
