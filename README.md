# Claude Usage Bar

맥 상단 메뉴바에 Claude 사용량(5시간 세션 / 주간)을 **남은 비율(%)** 로 실시간 표시하는 macOS 앱.

```
5h 97%  7d 85%  Fable 95%
```

## 기능

- 5시간 세션·주간 한도의 **남은 비율** 표시 (30% 이하 주황, 10% 이하 빨강)
- 메뉴에서 모델별 주간 한도(예: Fable), 막대그래프, 초기화까지 남은 시간 확인
- 갱신 주기 선택 (30초 / 1분 / 2분 / 5분), 잠자기 해제 시 즉시 갱신
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
- 업데이트 기능: Google Drive for desktop 동기화 (`내 드라이브/ClaudeUsageBar/`)

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
3. `내 드라이브/ClaudeUsageBar/`에 zip과 `latest.json` 복사 (zip은 최근 3개만 유지)

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

### 2026-10-22
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
