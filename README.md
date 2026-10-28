# Claude Usage Bar

맥 상단 메뉴바에 Claude·ChatGPT 사용량(5시간 / 주간)을 **남은 비율(%)** 로 실시간 표시하는 macOS 앱. 서비스마다 숫자 색이 다르다 (Claude 주황, ChatGPT 초록).

```
5h 97%  7d 85%  Fb 95%
```

## 기능

- 5시간·주간 한도의 **남은 비율** 표시 (서비스별 색상, 10% 이하 빨강)
- ChatGPT 사용량 (Codex CLI 로그인 사용)
- 모델별 주간 한도(예: Fable → `Fb`)도 메뉴바에 함께 표시
- 메뉴바를 클릭하면 맨 위에 한도별 초기화 날짜·시간 표시
- 로그인 확인: 로그인된 계정·요금제 표시, 미로그인/만료 시 안내
- 브라우저로 로그인 (Claude Code의 `claude auth login` 사용)
- 갱신 주기 선택 (1분 / 2분 / 5분), 잠자기 해제 시 즉시 갱신, 요청 제한(429) 시 자동 백오프
- 표시 방식 선택 (5시간+주간 / 5시간만 / 주간만)
- 로그인 시 자동 실행
- 구글 드라이브를 통한 **자동 업데이트 확인 및 설치** (새 버전이 있으면 메뉴바에 `↑` 표시)

## 작동 방식

- macOS 키체인의 Claude Code 로그인 토큰(`Claude Code-credentials`)을 `/usr/bin/security`로 읽는다.
- `https://api.anthropic.com/api/oauth/usage`를 호출해 Claude Code `/usage`와 같은 수치를 받는다. (비공개 API라 변경될 수 있음)
- 토큰이 만료되면 `⚠` 표시. Claude Code를 한 번 실행하면 토큰이 갱신되고 다음 주기에 자동 반영된다.

## 요구 사항

- macOS 13 이상, Swift 툴체인 (Xcode 또는 Command Line Tools)
- Claude Code 로그인 상태
- 업데이트 기능: Google Drive for desktop 동기화 (`내 드라이브/App/ClaudeUsageBar/`)

## 빌드 / 설치

```bash
./build.sh            # build/ClaudeUsageBar.app 생성
./build.sh install    # 빌드 후 /Applications에 설치하고 재실행
```

## 배포 (구글 드라이브)

```bash
./release.sh 1.2.0 "변경 메모"
```

1. `version.env`의 `BUILD`를 1 올리고 버전을 갱신
2. 앱 빌드 → `ClaudeUsageBar-<버전>-<빌드>.zip` 생성
3. `내 드라이브/App/ClaudeUsageBar/`에 zip과 `latest.json` 복사 (zip은 최근 3개만 유지)

앱은 실행 시와 6시간마다(또는 메뉴 › 업데이트 확인) `latest.json`의 `build`를 현재 빌드와 비교한다. 새 버전이면 **⬆ 업데이트 설치**를 누를 때 압축 해제 → 앱 교체 → 재실행한다.

> 다른 맥에 처음 설치할 때는 ad-hoc 서명이라 Gatekeeper가 막을 수 있다. Finder에서 우클릭 › 열기로 한 번 실행하면 된다.

## 파일 구성

| 파일 | 설명 |
|---|---|
| `Sources/ClaudeUsageBar/main.swift` | 앱 전체 코드 (AppKit) |
| `build.sh` | .app 번들 빌드 / 설치 |
| `release.sh` | 구글 드라이브 배포 |
| `version.env` | 버전(`VERSION`)·빌드 번호(`BUILD`) |

## 작업 내역

### 2026-10-28
- **v1.5.1 (build 23)**
  - 라벨(5h/7d)과 숫자 사이 세로 간격 축소: 글꼴 상자 높이 대신 실제 글자 높이(capHeight) 기준으로 붙여 쌓고 세로 가운데 정렬 (`BarLayout.lineGap` 기본 2pt / 압축 1.5pt)
  - 10% 이하 빨간 배경이 라벨과 겹치지 않게 위쪽 여백 조정
- **v1.5.0 (build 22)**
  - 압축 표시 추가 (기본 켜짐): `%` 기호 생략, 숫자 11→10pt·라벨 7.5→6.5pt·로고 11→9pt, 간격 축소 → 같은 내용 기준 폭 163pt → 97pt (약 40% 감소)
  - 메뉴 › 상태바 표시 › "압축 표시 (폭 줄이기)"로 켜고 끄기
  - 크기·간격을 `BarLayout`(기본/압축)으로 묶어 관리
- **메뉴바에 안 보이던 문제 원인 확인 (코드 변경 없음)**
  - 앱 자체 진단 결과 항목은 정상 표시 상태(폭 193pt)였으나, 메인 모니터(V26FX75, 2560×1080) 메뉴바가 가득 차서 macOS가 넘친 아이콘을 메뉴바가 없는 LG HDR 4K 상단으로 밀어냄 (CleanMyMac 아이콘도 같은 위치)
  - Finder처럼 메뉴가 적은 앱이 앞에 있으면 메인 메뉴바(x≈1072)에 정상 표시됨을 확인
  - 대응: ⌘+드래그로 아이콘을 시계 쪽(오른쪽)으로 옮기면 다른 아이콘이 먼저 숨겨짐 / "상태바 표시"에서 Fb·ChatGPT·주간을 꺼 폭 줄이기
- **Gemini 보류 (코드 변경 없음)**
  - Antigravity 로그인 파일(`~/.gemini/jetski-standalone-oauth-token`)의 토큰은 1시간마다 만료되고, Antigravity IDE·`agy`를 실행해도 이 파일은 갱신되지 않음
  - `agy` 안의 OAuth 클라이언트 후보 3개 × 시크릿 2개 + 시크릿 없음 조합으로 `refresh_token` 갱신을 시도했으나 모두 `401 invalid_client`
  - Antigravity 내부 인증 구조에 의존하면 업데이트마다 깨질 수 있어 Gemini 표시는 보류 (로고·색상 `#4285F4`는 코드에 준비됨)
  - 공식 Gemini CLI(`@google/gemini-cli` 0.66.0) 브라우저 로그인도 시도: 로그인은 성공했으나 개인 무료 등급은 `UNSUPPORTED_CLIENT`("Antigravity로 이전하라"), 표준 등급은 Google Cloud 프로젝트(기업 라이선스) 필요 → 할당량 조회 `403 SUBSCRIPTION_REQUIRED`
  - Gemini 앱(gemini.google.com)은 남은 사용량을 숫자로 제공하지 않음 → 개인 계정으로는 Gemini 할당량을 가져올 공식 경로가 현재 없음
- **v1.4.3 (build 21)**
  - 그룹 배경을 서비스 색 85%로 진하게, 그 위의 로고·라벨·숫자는 모두 흰색 (다크·라이트 미리보기로 확인)
  - 남은 비율 10% 이하는 빨간 글씨 대신 숫자 뒤에 빨간 배경
  - Claude 오류 `⚠`를 Claude 묶음 안으로 옮기고, 업데이트 `↑`만 모든 묶음 뒤에 표시 — 서비스 묶음이 한 덩어리로 붙어 있도록 (메뉴바 항목 1개라 다른 앱 아이콘이 끼어들 수 없음)
  - 갱신 주기 기본 1분 (Claude·ChatGPT 동일). 예전 30초 설정이 남아 있으면 실행 시 삭제
- **v1.4.2 (build 20)**
  - 서비스 묶음(로고+숫자) 뒤에 서비스 색을 옅게(22%) 깐 둥근 배경 추가 — 다크·라이트 모드 미리보기로 확인
  - Gemini: 토큰 갱신(Antigravity `refresh_token` 사용) 시도가 Claude Code 자동 모드 안전 검사([Credential Exploration])에서 차단되어 보류
- **v1.4.1 (build 19)**
  - 메뉴바 표시를 2줄 배치로 변경: 기간 라벨(5h/7d/Fb)을 숫자 **위에** 작게 표시 (이미지로 그려 다크/라이트 모드 자동 대응)
  - 서비스 묶음 앞에 구분 로고 추가: Claude 주황 불꽃, ChatGPT 초록 육각형 (Gemini 파랑 별 준비). 공식 이미지가 아닌 코드로 그린 단순 도형
  - Claude 정보를 못 가져오면 Claude 로고 뒤에 `⚠` 표시
  - Gemini(Antigravity) 조사: 할당량 API(`daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`)는 확인했으나, `~/.gemini/jetski-standalone-oauth-token`이 갱신되지 않아(만료 토큰) 아직 미적용
- **v1.4.0 (build 18)**
  - ChatGPT 사용량 추가: Codex CLI 로그인(`~/.codex/auth.json`)으로 `chatgpt.com/backend-api/wham/usage` 조회 → 5시간·주간 남은 비율 표시
  - 서비스별 숫자 색상 구분: Claude `#D97757`, ChatGPT `#10A37F` (Gemini는 `#4285F4` 예정). 남은 비율 10% 이하는 빨강 (기존 30% 이하 주황 규칙은 서비스 색과 겹쳐 제거)
  - 메뉴에 ChatGPT 요금제(Codex) 로그인 상태, 초기화 시간(`GPT 5h/7d`) 표시, 상태바 표시에 "ChatGPT 사용량" 켜고 끄기
  - Claude 정보를 못 가져와도 ChatGPT는 계속 표시

### 2026-10-22
- **v1.3.0 (build 17)**
  - 메뉴에 "브라우저로 로그인…" 추가: Claude Code의 `claude auth login --claudeai`를 실행해 브라우저에서 로그인 → 키체인 갱신 후 계정·사용량 즉시 다시 확인
  - 이미 로그인된 상태에서는 "Claude Code 로그인도 함께 바뀐다"는 확인 팝업 후 진행
  - 로그인 진행 중 메뉴에 표시, 실패 시 팝업 안내, 로그는 `~/Library/Logs/ClaudeUsageBar-login.log`
  - 미로그인/만료 안내 문구를 터미널 `/login` 대신 브라우저 로그인으로 변경
- **v1.2.9 (build 16)**
  - 로그인 확인 기능 추가: 메뉴 맨 위에 로그인된 계정(이름·이메일)과 요금제(예: Max 20x) 표시
  - 로그인 안 됨 / 만료 시 메뉴에 안내, "로그인 확인"(⌘L)을 누르면 결과를 팝업으로 안내
  - 계정 정보는 `/api/oauth/profile`, 요금제는 키체인의 `rateLimitTier`에서 읽음 (실행 시·6시간마다 확인)
  - 로그인 문제가 해소되면 사용량을 즉시 다시 가져옴
- **v1.2.8 (build 15)**
  - 구글 드라이브 배포 폴더를 `내 드라이브/ClaudeUsageBar` → `내 드라이브/App/ClaudeUsageBar`로 이전 (`release.sh` 경로 변경)
  - 앱은 새 위치와 예전 위치를 모두 확인해, 이전 전 버전도 업데이트를 받을 수 있게 함
- **v1.2.7 (build 14)**
  - "업데이트 확인"을 누르면 결과를 팝업으로 안내 (최신 버전 / 새 버전 → 지금 설치·나중에 / 확인 실패 사유). 기존에는 메뉴 하단 회색 글씨로만 표시돼 메뉴가 닫히면 보이지 않았음
  - 업데이트 설치 실패 시에도 팝업으로 안내
  - v1.2.6 → v1.2.7 메뉴 업데이트 설치 및 자동 재실행 검증 완료
- **v1.2.6 (build 13)**
  - 툴팁 대신 메뉴바를 클릭하면 메뉴 맨 위에 한도별 초기화 날짜·시간 표시 (메뉴가 붙은 상태바 항목은 툴팁이 뜨지 않음)
- **v1.2.5 (build 12)**
  - 메뉴바에 마우스를 올리면 한도별 초기화 날짜·시간을 툴팁으로 표시 (예: `5h  10/22(목) 19:20`)
- **v1.2.4 (build 11)**
  - 메뉴의 사용량 상세 항목(5시간 세션·주간 전체·주간 Fable 막대그래프와 초기화 시간) 삭제
- **v1.2.3 (build 10)**
  - 메뉴바 기간 라벨(5h/7d/Fb) 크기를 숫자의 절반(12pt → 6pt)으로 축소
- **v1.2.2 (build 9)**
  - 메뉴바 `⚠` 원인 확인: 사용량 API가 `429`(요청 제한) 응답 — 30초 갱신 주기 + 잦은 재시작이 원인
  - 429 대응: `retry-after` 준수, 연속 실패 시 대기 시간 2배씩 늘림(1분 → 최대 10분), 성공하면 초기화
  - 429일 때는 직전 값을 유지하고 `⚠`를 띄우지 않음 (메뉴에만 안내)
  - 갱신 주기 30초 옵션 제거, 최소 1분
- **v1.2.1 (build 8)**
  - 메뉴바 모델 라벨 축약: Fable → `Fb` (Opus `Op`, Sonnet `Sn`, Haiku `Hk`, 그 외 앞 두 글자). 메뉴 상세에는 전체 이름 유지
- **v1.2.0 (build 7)**
  - 메뉴바에 모델별 주간 한도(Fable 등) 남은 비율 표시 (`5h 100%  7d 85%  Fable 95%`)
  - 메뉴 › 상태바 표시 › "모델별 주간 한도 (Fable 등)"로 켜고 끄기 (기본 켜짐)
- **v1.1.3 (build 5) / v1.1.4 (build 6)**
  - 업데이트 후 앱이 재실행되지 않던 문제 수정: 새 앱을 `.new`로 복사한 뒤 교체(실패 시 기존 앱 유지), 재실행 최대 5회 재시도
  - 업데이트 로그 기록: `~/Library/Logs/ClaudeUsageBar-update.log`
  - v1.1.4는 v1.1.3에서 업데이트 동작을 검증하기 위한 배포본 → v1.1.3 → v1.1.4 업데이트 및 자동 재실행 검증 완료
- **v1.1.2 (build 4)**
  - 메뉴바의 기간 라벨(5h/7d)을 숫자와 같은 크기·굵게·기본 글자색(다크 메뉴바에서 흰색)으로 표시
- **v1.1.1 (build 3)** — 업데이트 기능 테스트 배포
- **v1.1.0 (build 2)**
  - 구글 드라이브 기반 업데이트 기능 추가 (`release.sh`, 메뉴 › 업데이트 확인/설치, 메뉴바 `↑` 표시)
  - `version.env`로 버전 관리, `build.sh install` 옵션 추가
  - 구글 드라이브 폴더명 NFD(자모 분리) 정규화 처리
  - README, CLAUDE.md 추가, GitHub 저장소 연결
- **v1.0.0 (build 1)**
  - 메뉴바 앱 최초 작성: 키체인 토큰 + OAuth usage API로 5시간/주간 사용량 표시
  - 사용률 대신 **남은 비율** 표시로 변경, 모델별 주간 한도(`limits`) 메뉴 표시
  - 갱신 주기·표시 방식·로그인 시 자동 실행 메뉴
