#!/usr/bin/env bash
#
# release-fork.sh — PikaTokenBar(포크) 릴리스.
#
# 원본 release.sh 를 쓰지 않는 이유: 저장소·homebrew tap·서명 인증서 leaf 가 원작자 것으로
# 고정돼 있고, cask·랜딩·스크린샷 게이트가 이 포크엔 존재하지 않는 산출물을 요구한다.
#
# 사용:
#   PTB_NOTES_FILE=/tmp/notes.md ./scripts/release-fork.sh 1.0.0
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="LuceteYang/PokeTokenBar"
APP_NAME="PikaTokenBar"
# 내 self-signed 인증서의 leaf SHA-1. 인증서를 재생성하면 이 값을 갱신해야 한다.
EXPECTED_LEAF="AD9CB282F034186623289577B6E95B3F4030827E"

VERSION="${1:?사용: release-fork.sh <version>  (예: 1.0.0)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "✗ 버전 형식 오류: $VERSION — 접미사 없는 semver 만 (UpdateChecker.isNewer 가 정수 파싱)"; exit 1; }

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "$BRANCH" == "main" ]] || { echo "✗ main 브랜치에서 실행하세요 (현재: $BRANCH)"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ 작업 트리가 깨끗하지 않습니다 — 커밋 후 실행하세요"; exit 1; }

# origin 이 정말 이 포크인지 확인 — release.sh 가드가 막는 것과 같은 부류의 사고(남의 저장소에
# push)를 origin 자체가 잘못 설정된 경우에도 막는다. $REPO 는 gh(release create)에만 쓰이고
# git push 는 origin 을 그대로 믿으므로 여기서 검증해야 한다.
[[ "$(git remote get-url origin)" == *"$REPO"* ]] || {
  echo "✗ origin 이 $REPO 가 아닙니다 (현재: $(git remote get-url origin))"; exit 1; }

# origin/main 보다 뒤처져 있으면 커밋까지 만든 뒤에야 push 가 non-fast-forward 로 실패한다
# (I-2 상태로 빠짐) — 커밋 전인 지금 미리 확인한다.
git fetch origin >/dev/null 2>&1 || { echo "✗ origin fetch 실패 — 네트워크/인증 확인"; exit 1; }
git merge-base --is-ancestor origin/main HEAD || {
  echo "✗ origin/main 이 로컬 HEAD 보다 앞서 있습니다 — pull/rebase 후 재시도"; exit 1; }

# gh 인증은 마지막 단계(GitHub Release 생성)에서만 쓰이지만, 실패 시점이 가장 늦으면 커밋·push 가
# 이미 끝난 뒤라 복구가 번거롭다(I-2) — 미리 확인해 늦은 실패를 앞당긴다.
gh auth status >/dev/null 2>&1 || { echo "✗ gh 인증이 안 되어 있습니다 — gh auth login 후 재시도"; exit 1; }

PREV=$(grep -oE 'VERSION="[0-9.]+"' scripts/build-app.sh | grep -oE '[0-9.]+')
echo "=== PikaTokenBar 릴리스 $PREV → $VERSION ==="

echo "▶ 1/7 테스트 게이트"
./scripts/test-gate.sh >/dev/null || { echo "✗ test-gate 실패 — 중단"; exit 1; }
echo "  ✓ 통과"

echo "▶ 2/7 정체성 누수 검사"
# 원본 정체성이 소스에 남아 있으면 두 앱이 같은 파일을 쓴다. 릴리스로 새 나가면 팀원 Mac 에서
# 원본의 데이터를 덮어쓰므로 여기서 하드 게이트로 막는다.
# 예외(의도된 유지): SettingsView 의 Web·Sponsor 링크 — 이 포크엔 랜딩 페이지가 없어 바꾸면
# 404 가 되고, 후원은 원작자에게 가는 게 맞다(SettingsView.swift 주석 참조). 그 두 URL만 걸러내고
# bare "chattymin" 은 그대로 둔다 — 새로운 upstream 참조가 섞여 들어오면 여전히 걸린다.
LEAK=$(grep -rn 'chattymin\|"PokeTokenBar"\|PokeTokenBar\.log' Sources/ 2>/dev/null \
  | grep -v 'chattymin\.github\.io\|sponsors/chattymin' || true)
if [[ -n "$LEAK" ]]; then
  echo "$LEAK"
  echo "  ✗ 원본 정체성 문자열이 소스에 남아 있습니다 → AppIdentity 로 치환하세요."; exit 1
fi
echo "  ✓ 누수 없음"

echo "▶ 3/7 코드서명 신원 게이트"
# 인증서가 바뀌면 팀원 전원이 Claude 키체인 접근을 재승인해야 한다(지정요구에 leaf 가 들어간다).
SIGN_IDENTITY="${CODESIGN_IDENTITY:-PokeTokenBar Local}"
# 이름이 같은 identity 가 keychain 에 두 개 이상이면 build-app.sh 의 codesign -s "$SIGN_IDENTITY" 가
# 어느 쪽을 골랐는지 여기서 확인한 leaf 와 다를 수 있다 — 반드시 정확히 1개여야 한다.
MATCH_COUNT=$(security find-identity -v -p codesigning | grep -Fc "\"$SIGN_IDENTITY\"" || true)
if [[ "$MATCH_COUNT" != "1" ]]; then
  echo "✗ codesigning identity '$SIGN_IDENTITY' 가 keychain 에 $MATCH_COUNT 개 있습니다(정확히 1개여야 함) → 중복 제거 후 재시도."; exit 1
fi
LEAF=$(security find-identity -v -p codesigning | awk -v id="\"$SIGN_IDENTITY\"" '$0 ~ id {print $2; exit}')
if [[ -z "$LEAF" ]]; then
  echo "✗ 유효 codesigning identity '$SIGN_IDENTITY' 없음 → ./scripts/create-signing-cert.sh 실행 후 재시도."; exit 1
fi
if [[ "$LEAF" != "$EXPECTED_LEAF" ]]; then
  echo "⚠ 서명 인증서 leaf 불일치: 현재 $LEAF ≠ 고정 $EXPECTED_LEAF"
  echo "  이대로 배포하면 기존 팀원 전원이 키체인을 1회 재승인해야 합니다."
  read -r -p "  의도한 변경이면 EXPECTED_LEAF 를 갱신하고 계속하세요. 지금 계속? [y/N] " a
  [[ "$a" == "y" || "$a" == "Y" ]] || { echo "중단"; exit 1; }
fi
echo "  ✓ leaf=$LEAF"
export PTB_REQUIRE_STABLE_SIGN=1   # build-app.sh 방어선: ad-hoc 폴백 차단

echo "▶ 4/7 VERSION 범프 $PREV → $VERSION (아직 미커밋)"
perl -pi -e "s/VERSION=\"[0-9.]+\"/VERSION=\"$VERSION\"/" scripts/build-app.sh

echo "▶ 5/7 universal 빌드 + zip (push 전 검증)"
# build-app.sh 는 codesign 직후 /Applications 에 곧바로 설치한다(pkill+rm+cp) — 아래 검증들이
# 실패해도 이미 로컬 앱은 이 빌드로 바뀌어 있다. 복구 안내에 그 사실을 명시한다.
RECOVER="복구: git checkout scripts/build-app.sh — 그리고 /Applications 의 $APP_NAME 도 이전 릴리스로 되돌리세요(curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash)"
PTB_UNIVERSAL=1 ./scripts/build-app.sh >/dev/null
# leaf 는 keychain 신원을 확인했을 뿐 실제로 이 아티팩트에 서명됐는지는 보증하지 않는다 —
# codesign -s 는 이름으로 고르므로(3/7), 빌드물 자체의 Authority 를 다시 확인한다.
codesign -dvv "build/$APP_NAME.app" 2>&1 | grep -q "Authority=$SIGN_IDENTITY" \
  || { echo "✗ 빌드된 앱의 서명 Authority 가 '$SIGN_IDENTITY' 가 아닙니다 ($RECOVER)"; exit 1; }
BUILT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/$APP_NAME.app/Contents/Info.plist")
[[ "$BUILT" == "$VERSION" ]] || { echo "✗ 빌드 버전 불일치: $BUILT ($RECOVER)"; exit 1; }
lipo -info "build/$APP_NAME.app/Contents/MacOS/$APP_NAME" | grep -q "x86_64" \
  || { echo "✗ universal 아님 — Intel Mac 팀원이 실행할 수 없습니다 ($RECOVER)"; exit 1; }
rm -f "build/$APP_NAME.zip"
ditto -c -k --keepParent "build/$APP_NAME.app" "build/$APP_NAME.zip"

echo "▶ 6/7 커밋 + push"
git add scripts/build-app.sh
# gh release create(7/7)가 실패해 재실행할 때, VERSION 이 이미 범프돼 있으면 diff 가 비어 커밋할
# 게 없다 — 그대로 커밋하면 set -e 로 스크립트가 죽어 재시도가 막힌다(I-2). 커밋을 조건부로 만들어
# push+release 재시도만으로 복구되게 한다.
git diff --cached --quiet || git commit -q -m "release: bump version to $VERSION

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push -q origin main

echo "▶ 7/7 GitHub Release v$VERSION"
NOTES=$(mktemp)
{
  echo "## 설치 · 업데이트"
  echo
  echo '```bash'
  echo "curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash"
  echo '```'
  echo
  echo "설치와 업데이트가 같은 명령입니다. 새 버전이 나오면 이 명령을 다시 실행하세요."
  echo
  echo "> 자체서명 앱이라 Gatekeeper 격리 속성 해제가 필요합니다 — 위 스크립트가 처리합니다."
  echo "> 수동 설치를 원하면 아래 \`$APP_NAME.zip\` 을 받아 \`/Applications\` 에 넣고,"
  echo "> 시스템 설정 → 개인정보 보호 및 보안 → \"확인 없이 열기\" 를 누르세요."
  echo
  if [[ -n "${PTB_NOTES_FILE:-}" && -f "${PTB_NOTES_FILE:-}" ]]; then
    echo "## 변경사항"; echo; cat "$PTB_NOTES_FILE"; echo
  fi
  echo "---"
  echo "upstream 베이스: \`$(git rev-parse --short "$(git merge-base HEAD upstream/main 2>/dev/null || echo HEAD)")\`"
} > "$NOTES"

gh release create "v$VERSION" "build/$APP_NAME.zip" "scripts/install.sh" \
  --repo "$REPO" --title "$APP_NAME v$VERSION" --target main --notes-file "$NOTES"
rm -f "$NOTES"

echo "✓ v$VERSION 배포 완료."
echo "  공유: https://github.com/$REPO/releases/latest"
echo "  팀원 명령: curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash"
