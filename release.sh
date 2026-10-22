#!/bin/zsh
# 구글 드라이브 배포 스크립트
#   ./release.sh [버전] ["변경 메모"]
#   예) ./release.sh 1.1.0 "남은 비율 표시"
# 빌드 번호(BUILD)는 자동으로 1 증가하며, 앱은 이 번호로 새 버전 여부를 판단한다.
set -e
cd "$(dirname "$0")"
source ./version.env

NEW_VERSION="${1:-$VERSION}"
NOTES="${2:-}"
NEW_BUILD=$((BUILD + 1))
printf 'VERSION=%s\nBUILD=%s\n' "$NEW_VERSION" "$NEW_BUILD" > version.env

./build.sh

# 드라이브 폴더명은 NFD(자모 분리)로 저장되어 있어 정규화해서 비교한다
DRIVE=$(python3 -I - <<'PY'
import os, unicodedata
root = os.path.expanduser("~/Library/CloudStorage")
for acc in sorted(os.listdir(root)):
    if not acc.startswith("GoogleDrive-"):
        continue
    for name in os.listdir(os.path.join(root, acc)):
        if unicodedata.normalize("NFC", name) in ("내 드라이브", "My Drive"):
            print(os.path.join(root, acc, name)); raise SystemExit
PY
)
[[ -z "$DRIVE" ]] && { echo "❌ 구글 드라이브 동기화 폴더를 찾을 수 없습니다"; exit 1; }
DEST="$DRIVE/App/ClaudeUsageBar"
mkdir -p "$DEST"

ZIP="ClaudeUsageBar-${NEW_VERSION}-${NEW_BUILD}.zip"
ditto -c -k --keepParent build/ClaudeUsageBar.app "build/$ZIP"
cp "build/$ZIP" "$DEST/"

# latest.json은 zip 복사 후에 써서, 앱이 아직 없는 파일을 가리키지 않게 한다
python3 -I -c 'import json,sys; print(json.dumps({"version":sys.argv[1],"build":int(sys.argv[2]),"file":sys.argv[3],"notes":sys.argv[4]}, ensure_ascii=False, indent=2))' \
    "$NEW_VERSION" "$NEW_BUILD" "$ZIP" "$NOTES" > "$DEST/latest.json"

# 오래된 zip은 최근 3개만 남김
ls -t "$DEST"/ClaudeUsageBar-*.zip | tail -n +4 | while read -r f; do rm -f "$f"; done

echo "✅ 배포 완료: $DEST/$ZIP"
