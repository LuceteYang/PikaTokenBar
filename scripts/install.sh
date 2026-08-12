#!/bin/bash
# PikaTokenBar 설치/업데이트 — 최신 릴리스를 받아 /Applications 에 설치하고 실행한다.
# 설치와 업데이트가 같은 명령이다(GitHub 의 latest/download 가 항상 최신을 가리킨다).
#
#   curl -fsSL https://github.com/LuceteYang/PokeTokenBar/releases/latest/download/install.sh | bash
set -euo pipefail

APP_NAME="PikaTokenBar"
AGENT_LABEL="sh.otis.pikatokenbar.login"
REPO="LuceteYang/PokeTokenBar"
ZIP_URL="https://github.com/$REPO/releases/latest/download/$APP_NAME.zip"
DEST="/Applications/$APP_NAME.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> 최신 $APP_NAME 내려받는 중"
curl -fsSL "$ZIP_URL" -o "$TMP/app.zip" || { echo "✗ 다운로드 실패: $ZIP_URL" >&2; exit 1; }

# 실행 중이면 먼저 멈춘다. 시그널로 죽이면 launchd(KeepAlive)가 비정상 종료로 보고 즉시 재실행해
# 번들 교체와 경합한다 → 로그인 에이전트를 먼저 내리고(bootout), 그 다음 프로세스를 정리한다.
# bootout 은 에이전트가 등록돼 있지 않으면 실패하는데 정상 상황이므로 무시한다.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "==> 실행 중인 $APP_NAME 종료"
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.5
    done
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
fi

echo "==> $DEST 설치"
rm -rf "$DEST"
# release-fork.sh 는 `ditto -c -k --keepParent` 로 압축한다 — 파일별 xattr 을 AppleDouble
# 멤버(._*)로 저장하는 방식인데, Info-ZIP unzip 은 이를 이해하지 못하고 서명된 번들 *안에*
# 실제 파일로 풀어놓는다. 그러면 codesign 이 "file added" 로 seal 불일치를 보고하고, launchd 가
# 번들 서명을 검증하는 LaunchAgent(로그인 시 실행·크래시 워치독)까지 조용히 죽는다 — 반드시
# ditto 로 풀어야 한다(같은 도구로 싸고 풀어야 AppleDouble 을 xattr 로 되돌린다).
ditto -x -k "$TMP/app.zip" /Applications || { echo "✗ 압축 해제 실패" >&2; exit 1; }
[ -d "$DEST" ] || { echo "✗ $DEST 가 만들어지지 않았습니다" >&2; exit 1; }

# 압축 해제 방식이 서명을 깨는 건 조용히 일어난다(앱은 실행은 된다) — 여기서 즉시 검증해
# 이 부류의 결함이 다시 소리 없이 나가지 못하게 한다.
echo "==> 서명 확인"
codesign --verify --deep --strict "$DEST" 2>/dev/null \
  || { echo "✗ 설치된 앱의 서명이 유효하지 않습니다 — 다운로드가 손상됐거나 압축 해제가 잘못됐습니다." >&2; exit 1; }

# 공증(notarization)을 하지 않는 자체서명 앱이라 quarantine 이 붙어 있으면 Gatekeeper 가 막는다.
# macOS 15(Sequoia)부터는 Control-클릭 → 열기 우회가 제거돼 이 해제가 사실상 유일한 경로다.
echo "==> Gatekeeper 격리 속성 해제"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> 실행"
open "$DEST"

VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")
echo "완료: $APP_NAME $VER — 메뉴바를 확인하세요."
echo "(설정에서 '로그인 시 실행'을 다시 켜면 자동 시작이 복구됩니다.)"
