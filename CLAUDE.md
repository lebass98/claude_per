# Claude Usage Bar — 프로젝트 규칙

- macOS 메뉴바 앱 (Swift/AppKit, SwiftPM). 코드는 `Sources/ClaudeUsageBar/main.swift` 한 파일.
- 빌드: `./build.sh` / 설치: `./build.sh install` / 구글 드라이브 배포: `./release.sh <버전> "<메모>"`
- **작업 후 반드시 `README.md`의 `## 작업 내역`에 날짜별로 변경 사항을 누적 기록한다.** (최신 항목이 위)
- 배포 시 `version.env`의 `BUILD`가 증가해야 앱이 업데이트를 인식한다 (`release.sh`가 자동 처리).
- 커밋 메시지는 한글 + Conventional Commits 접두사. `.DS_Store` 등 OS 파일은 커밋 금지.
