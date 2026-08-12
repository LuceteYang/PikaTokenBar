#!/usr/bin/env bash
#
# release-fork.sh — PikaTokenBar(포크) 릴리스.
#
# 원본 release.sh 를 쓰지 않는 이유: 저장소·homebrew tap·서명 인증서 leaf 가 원작자 것으로
# 고정돼 있고, cask·랜딩·스크린샷 게이트가 이 포크엔 존재하지 않는 산출물을 요구한다.
#
# 사용:
#   PTB_NOTES_FILE=/tmp/notes.md ./scripts/release-fork.sh 1.0.0
#   ./scripts/release-fork.sh --check-only        # 상태를 바꾸지 않는 게이트만 점검
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="LuceteYang/PokeTokenBar"
APP_NAME="PikaTokenBar"
# 내 self-signed 인증서의 leaf SHA-1. 인증서를 재생성하면 이 값을 갱신해야 한다.
EXPECTED_LEAF="AD9CB282F034186623289577B6E95B3F4030827E"

# --check-only: 버전 범프·빌드·커밋·push·릴리스 없이, 상태를 바꾸지 않는 게이트만 돌려서
# "지금 release-fork.sh <version> 을 실행하면 몇 번째 게이트에서 멈출지"를 미리 보여준다.
# release.sh 의 --check-only 관례를 따라 버전 인자보다 먼저 파싱한다.
# 게이트 하나가 실패해도 나머지를 계속 점검하도록 여기서만 set -e 를 끈다(요약을 보려면 전부
# 돌려봐야 한다) — 항상 exit 0 로 끝난다(release.sh --check-only 와 동일한 관례: 진짜 배포가
# 아니라 점검 리포트이므로, 실패 여부는 아래 요약 줄로 사람이 읽고 판단한다).
if [[ "${1:-}" == "--check-only" ]]; then
  set +e
  echo "=== release-fork.sh --check-only (배포 없음 — 게이트만 점검) ==="
  FAIL=0
  ok()  { echo "  ✓ $1"; }
  bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [[ "$BRANCH" == "main" ]] && ok "브랜치 = main" || bad "main 브랜치가 아닙니다 (현재: $BRANCH)"

  [[ -z "$(git status --porcelain)" ]] && ok "작업 트리 깨끗함" || bad "작업 트리가 깨끗하지 않습니다"

  ORIGIN_URL=$(git remote get-url origin 2>/dev/null)
  [[ "$ORIGIN_URL" == *"$REPO"* ]] && ok "origin = $REPO" || bad "origin 이 $REPO 가 아닙니다 (현재: $ORIGIN_URL)"

  if git fetch origin >/dev/null 2>&1; then
    if git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
      ok "origin/main 대비 최신 (뒤처지지 않음)"
    else
      bad "origin/main 이 로컬 HEAD 보다 앞서 있습니다 — pull/rebase 필요"
    fi
  else
    bad "origin fetch 실패 — 네트워크/인증 확인"
  fi

  gh auth status >/dev/null 2>&1 && ok "gh 인증됨" || bad "gh 인증 안 됨 — gh auth login 필요"

  if ./scripts/test-gate.sh >/dev/null 2>&1; then
    ok "test-gate 통과"
  else
    bad "test-gate 실패"
  fi

  LEAK=$(grep -rn 'chattymin\|"PokeTokenBar"\|PokeTokenBar\.log' Sources/ 2>/dev/null \
    | grep -v 'https://chattymin\.github\.io/PokeTokenBar/\|https://github\.com/sponsors/chattymin')
  if [[ -z "$LEAK" ]]; then
    ok "정체성 누수 없음"
  else
    bad "원본 정체성 문자열이 소스에 남아 있습니다:"
    echo "$LEAK" | sed 's/^/      /'
  fi

  SIGN_IDENTITY="${CODESIGN_IDENTITY:-PokeTokenBar Local}"
  MATCH_COUNT=$(security find-identity -v -p codesigning | grep -Fc "\"$SIGN_IDENTITY\"")
  if [[ "$MATCH_COUNT" == "1" ]]; then
    LEAF=$(security find-identity -v -p codesigning | awk -v id="\"$SIGN_IDENTITY\"" '$0 ~ id {print $2; exit}')
    if [[ "$LEAF" == "$EXPECTED_LEAF" ]]; then
      ok "서명 identity 단일·leaf 일치 (leaf=$LEAF)"
    else
      bad "서명 identity leaf 불일치: 현재 $LEAF ≠ 고정 $EXPECTED_LEAF"
    fi
  else
    bad "codesigning identity '$SIGN_IDENTITY' 가 keychain 에 $MATCH_COUNT 개 있습니다(정확히 1개여야 함)"
  fi

  # 5/7 의 아티팩트 게이트(서명 Authority·버전·universal) — 두 번이나 검증 없이 실려나간 바로 그
  # 부류(C-2). 여기서 새로 빌드하면 /Applications 를 덮어쓰고 실행 중인 앱을 죽이므로(build-app.sh
  # 가 codesign 직후 곧바로 설치한다) --check-only 는 상태를 안 바꾼다는 원칙에 어긋난다 — 대신
  # build/ 에 이미 있는 산출물을 대상으로 같은 검사를 돌리고, 없으면 그 사실만 알린다.
  if [[ -d "build/$APP_NAME.app" ]]; then
    AUTH=$(codesign -dvv "build/$APP_NAME.app" 2>&1 || true)
    [[ "$AUTH" == *"Authority=$SIGN_IDENTITY"* ]] \
      && ok "build/$APP_NAME.app 서명 Authority = $SIGN_IDENTITY" \
      || bad "build/$APP_NAME.app 서명 Authority 가 '$SIGN_IDENTITY' 가 아닙니다"

    BUILT_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/$APP_NAME.app/Contents/Info.plist" 2>/dev/null)
    if [[ "$BUILT_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      ok "build/$APP_NAME.app 버전 읽힘: $BUILT_VER (release-fork.sh <version> 실행 시 그 값과 비교됨)"
    else
      bad "build/$APP_NAME.app 의 CFBundleShortVersionString 을 못 읽었습니다"
    fi

    LIPO_INFO=$(lipo -info "build/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>&1 || true)
    [[ "$LIPO_INFO" == *"x86_64"* ]] \
      && ok "build/$APP_NAME.app universal(x86_64 포함)" \
      || bad "build/$APP_NAME.app 이 universal 이 아닙니다(현재 build/ 는 참고용 — 실제 릴리스는 PTB_UNIVERSAL=1 로 새로 빌드함)"
  else
    echo "  ℹ build/$APP_NAME.app 없음 — 아티팩트 게이트(서명 Authority·버전·universal)는 지금 확인할 산출물이 없습니다."
    echo "    release-fork.sh <version> 을 실제로 실행하면 5/7 에서 새로 빌드해 이 게이트들을 통과시켜야 합니다."
  fi

  echo "---"
  if [[ "$FAIL" -eq 0 ]]; then
    echo "✓ 모든 게이트 통과 — release-fork.sh <version> 실행 가능"
  else
    echo "✗ $FAIL 개 게이트 실패 — 위 항목을 해결한 뒤 다시 확인하세요"
  fi
  exit 0
fi

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
# 404 가 되고, 후원은 원작자에게 가는 게 맞다(SettingsView.swift 주석 참조). 그 정확한 두 URL만
# 걸러낸다 — 호스트 단위(chattymin.github.io/*, sponsors/chattymin 하위 전체)로 거르면 나중에
# 같은 호스트에 새로 추가되는 upstream 참조까지 조용히 새나간다(I-6).
LEAK=$(grep -rn 'chattymin\|"PokeTokenBar"\|PokeTokenBar\.log' Sources/ 2>/dev/null \
  | grep -v 'https://chattymin\.github\.io/PokeTokenBar/\|https://github\.com/sponsors/chattymin' || true)
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
#
# `cmd | grep -q` 로 쓰지 않는다: grep -q 는 매치를 찾는 순간 읽기를 멈추고 종료하는데, 그 시점에
# 원본 명령이 아직 나머지 줄을 쓰는 중이면 SIGPIPE(exit 141)를 받는다 — pipefail 하에선 grep 이
# 성공(0)해도 파이프 전체가 실패로 보인다. 명령 출력을 변수로 먼저 받아 문자열로 비교한다.
AUTH=$(codesign -dvv "build/$APP_NAME.app" 2>&1 || true)
[[ "$AUTH" == *"Authority=$SIGN_IDENTITY"* ]] \
  || { echo "✗ 빌드된 앱의 서명 Authority 가 '$SIGN_IDENTITY' 가 아닙니다 ($RECOVER)"; exit 1; }
BUILT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/$APP_NAME.app/Contents/Info.plist")
[[ "$BUILT" == "$VERSION" ]] || { echo "✗ 빌드 버전 불일치: $BUILT ($RECOVER)"; exit 1; }
LIPO_INFO=$(lipo -info "build/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>&1 || true)
[[ "$LIPO_INFO" == *"x86_64"* ]] \
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

# gh release create 는 idempotent 하지 않다 — 업로드가 중간에 끊기거나(네트워크·API 일시 오류) 하면
# 태그·릴리스 객체는 이미 만들어진 채로 실패하는데, 이 시점에는 버전 범프가 이미 커밋·push 돼 있다(6/7).
# 같은 버전으로 재실행하면 "release already exists" 로 죽어 사람이 붙잡힌다 — 먼저 존재를 확인해서 있으면
# 노트 갱신 + 에셋 재업로드(clobber)로 이어가고, 없으면 평소처럼 새로 만든다. 이 단계 자체가 실패해도
# 정확히 뭘 하면 되는지 메시지에 남긴다(I-7).
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "  ⚠ v$VERSION 릴리스가 이미 존재합니다 — 이전 실행이 중간에 끊겼을 가능성. 노트 갱신 + 에셋 재업로드로 이어갑니다."
  gh release edit "v$VERSION" --repo "$REPO" --title "$APP_NAME v$VERSION" --notes-file "$NOTES" \
    || { echo "✗ 릴리스 노트 갱신 실패 → 확인: gh release view v$VERSION --repo $REPO"; exit 1; }
  gh release upload "v$VERSION" "build/$APP_NAME.zip" "scripts/install.sh" --repo "$REPO" --clobber \
    || { echo "✗ 에셋 재업로드 실패 → 직접 재시도: gh release upload v$VERSION build/$APP_NAME.zip scripts/install.sh --repo $REPO --clobber"; exit 1; }
else
  gh release create "v$VERSION" "build/$APP_NAME.zip" "scripts/install.sh" \
    --repo "$REPO" --title "$APP_NAME v$VERSION" --target main --notes-file "$NOTES" \
    || { echo "✗ GitHub Release 생성 실패 → 태그/릴리스가 부분적으로 만들어졌을 수 있습니다. 그대로 ./scripts/release-fork.sh $VERSION 를 재실행하면 위 분기(에셋 재업로드)로 자동 전환됩니다. 깨끗이 지우고 다시 하려면: gh release delete v$VERSION --repo $REPO --yes && git push origin :refs/tags/v$VERSION"; exit 1; }
fi
rm -f "$NOTES"

echo "✓ v$VERSION 배포 완료."
echo "  공유: https://github.com/$REPO/releases/latest"
echo "  팀원 명령: curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash"
