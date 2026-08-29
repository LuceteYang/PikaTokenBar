#!/bin/bash
# PokeTokenBar.app 번들 조립 + /Applications 설치
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.4.1"
PRODUCT="PokeTokenBar"           # SPM 산출물명 — 모듈명은 바꾸지 않는다
BUILD_DIR="build"

# 정체성은 AppIdentity.swift 가 단일 진실원이다. 여기 손으로 적으면 두 곳이 조용히 어긋난다.
IDENTITY_SRC="Sources/PokeTokenBar/Core/AppIdentity.swift"
read_identity() {   # $1 = 상수명
    sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" "$IDENTITY_SRC" | head -1
}
APP_NAME=$(read_identity executableName)
BUNDLE_ID=$(read_identity bundleID)
AGENT_LABEL=$(read_identity loginAgentLabel)
for v in APP_NAME BUNDLE_ID AGENT_LABEL; do
    [[ -n "${!v}" ]] || { echo "✗ $IDENTITY_SRC 에서 $v 를 못 읽었습니다 — 상수 형태가 바뀌었는지 확인하세요." >&2; exit 1; }
done
APP="$BUILD_DIR/$APP_NAME.app"

# 팀 배포용 zip 은 Intel Mac 도 받으므로 universal 로 빌드한다. 로컬 개발 빌드까지 두 아키텍처를
# 굽면 느려지므로 릴리스 경로(release-fork.sh)에서만 PTB_UNIVERSAL=1 을 켠다.
if [[ "${PTB_UNIVERSAL:-0}" == "1" ]]; then
    echo "==> swift build -c release (universal: arm64 + x86_64)"
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/$PRODUCT"
else
    echo "==> swift build -c release (host arch)"
    swift build -c release
    BIN=".build/release/$PRODUCT"
fi

echo "==> $APP 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# 심볼 strip — 릴리스 바이너리 1.84MB → 0.80MB(-57%). codesign 전에 수행(서명 무효화 방지).
strip -rSTx "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || strip -rSx "$APP/Contents/MacOS/$APP_NAME"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 크래시/OOM(exit≠0) 시 자동 재실행 LaunchAgent(KeepAlive) — SMAppService.agent 가 등록해 launchd 가
# 워치독으로 동작. 정상 종료(exit 0: 사용자 종료·업데이트)엔 재실행 안 함(SuccessfulExit=false).
# ProgramArguments 는 brew 설치 경로(/Applications) 고정. codesign 전에 생성해 서명 seal 에 포함.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
AGENT

echo "==> codesign"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-PokeTokenBar Local}"
# 안정적 Keychain ACL 을 위해서는 인증서 존재가 아니라 유효한 codesigning identity 가 필요하다.
if security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null; then
    # 안정적 자체 서명 신원 → 재빌드해도 Keychain "항상 허용" 유지
    codesign --force -s "$SIGN_IDENTITY" "$APP"
else
    # 인증서 없음 → ad-hoc (빌드마다 cdhash 변경 = Keychain 재프롬프트 가능)
    if [[ "${PTB_REQUIRE_STABLE_SIGN:-0}" == "1" ]]; then
        # 릴리스 경로(release.sh 가 세팅). ad-hoc 릴리스는 사용자 Keychain 승인을 깨므로 절대 금지.
        echo "   ✗ PTB_REQUIRE_STABLE_SIGN=1 인데 '$SIGN_IDENTITY' 유효 identity 없음 → ad-hoc 금지, 중단." >&2
        echo "     ./scripts/create-signing-cert.sh 실행 후 다시 시도하세요." >&2
        exit 1
    fi
    echo "   ('$SIGN_IDENTITY' 유효 codesigning identity 없음 → ad-hoc 서명 — 로컬 개발용)"
    echo "   반복 Keychain 허용 프롬프트를 줄이려면 ./scripts/create-signing-cert.sh 실행 후 다시 빌드하세요."
    codesign --force -s - "$APP"
fi

echo "==> 기존 인스턴스 종료 + /Applications 설치"
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" /Applications/

echo "완료: open /Applications/$APP_NAME.app"
