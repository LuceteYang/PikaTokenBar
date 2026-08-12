---
summary: "PikaTokenBar 포크 유지보수 — upstream 추적·머지 규칙·포크 소유 파일·릴리스 절차."
read_when:
  - upstream(chattymin/PokeTokenBar) 변경을 검토·반영할 때
  - 이 포크를 배포할 때 (자연어 트리거 포함: "배포해줘", "릴리스 올려줘")
  - 머지 충돌에서 어느 쪽을 지켜야 할지 판단할 때
---

> 동기화·기여를 **실행**할 때는 `upstream-sync` 스킬이 절차를 담당한다. 이 문서는 그 스킬이
> 참조하는 **정책**(포크 소유 파일·릴리스 규칙)이다.

# PikaTokenBar 포크 유지보수

이 저장소는 `chattymin/PokeTokenBar` 의 포크다. 두 가지가 원본과 다르다:
**등장 범위가 1세대(#1–151)** 이고, **앱 정체성이 완전히 분리**돼 있다(원본과 같은 Mac 에 공존).

## 릴리스 — `release.sh` 가 아니라 `release-fork.sh`

원본 `scripts/release.sh` 는 실행 즉시 중단되도록 가드가 걸려 있다(파일 맨 위, `set -euo pipefail`
직후). 원작자 저장소(`chattymin/PokeTokenBar`)·homebrew tap·원작자 서명 인증서로 배포하게 고정돼
있어 이 포크에서 실행하면 안 되기 때문이다.

    PTB_NOTES_FILE=/tmp/notes.md ./scripts/release-fork.sh <version>

버전은 **포크 자체 semver** 다(원본 버전과 무관, `1.0.0` 부터). 접미사(`-gen1`)를 붙이면
`UpdateChecker.isNewer` 의 정수 파싱(`Int($0) ?? 0`)에서 조용히 0 으로 잘리므로 순수 semver 만 쓴다.
`release-fork.sh` 도 버전 인자를 `^[0-9]+\.[0-9]+\.[0-9]+$` 로 하드 게이트한다.

배포 후 공유할 것은 링크 하나다 — 설치와 업데이트가 같은 명령이다:

    curl -fsSL https://github.com/LuceteYang/PokeTokenBar/releases/latest/download/install.sh | bash

`install.sh` 는 실행 중이면 로그인 에이전트를 먼저 내리고(bootout) 프로세스를 정리한 뒤 새 버전을
풀어 quarantine 을 해제한다(`xattr -dr com.apple.quarantine`) — 자체서명 앱이라 공증이 없고, Gatekeeper
우회 경로가 이것뿐이다.

## upstream 추적

앱은 **내 포크 릴리스만** 확인한다(`AppIdentity.releasesRepo`). 원본이 새 버전을 내도 팀원 앱은
조용하다. 반영 여부는 내가 정한다.

    git fetch upstream
    git log --oneline main..upstream/main     # 무엇이 바뀌었나
    git diff main..upstream/main -- Sources/  # 내 변경과 겹치는가
    git merge upstream/main                    # 반영하기로 한 경우만
    swift test && ./scripts/test-gate.sh
    ./scripts/release-fork.sh <version>

## 포크가 소유한 파일 — 충돌 시 내 쪽을 지킨다

upstream 이 아래를 바꿔 충돌이 나면 **원본 값을 그대로 받아들이면 안 된다.** 받아들이는 순간
두 앱이 같은 데이터를 쓰거나, 팀원이 원본 빌드로 유도된다.

| 파일 | 지켜야 할 것 |
|---|---|
| `Sources/PokeTokenBar/Core/AppIdentity.swift` | 전체 (포크 전용 파일 — 정체성 단일 진실원) |
| `Core/LoginItem.swift` | `plistName`·`label` 이 `AppIdentity` 참조 |
| `Core/UpdateChecker.swift` | `repo` 가 `AppIdentity.releasesRepo` 참조. **Homebrew cask 분기는
  통째로 삭제돼 있다** — 이 포크는 GitHub Release + `install.sh` 로만 배포하고 cask 를 절대 안 내므로,
  `brew list --cask` 로 원본 cask 를 오탐해 원본 앱 번들을 덮어쓰는 경로 자체가 없다. 머지가 그 분기를
  되살리면 되돌린다. (`pgrep`/`launchctl` 로 실행 중인 인스턴스를 내리는 로직은 이 파일이 아니라
  `scripts/install.sh` 쪽에 있다.) |
| `Core/AppLog.swift`, `CrashReporter.swift`, `Localization.swift` | 로그 파일명 |
| `Core/CompanionStore.swift`, `PokeAPIClient.swift`, `LocalUsageCache.swift`, `UsageStore.swift`, `UI/SpriteLoader.swift` | 저장 경로가 `AppIdentity.supportDirectory` |
| `Core/CompanionModel.swift` | `animatedSpeciesIDs = 1...151`, `EvoLine.init` 의 re-root |
| `Core/PokeAPIClient.swift` | `baseIndexQuery` 의 `_or`/`_gt` 가지, `isRESTIndexUsable` |
| `PokeTokenBarApp.swift` | 레거시 저장소 이전이 **없어야** 한다 |
| `scripts/build-app.sh` | 정체성 변수·`PTB_UNIVERSAL`. **손으로 값을 적지 않는다** — `read_identity()` 가
  `AppIdentity.swift` 를 `sed` 로 파싱해 `APP_NAME`/`BUNDLE_ID`/`AGENT_LABEL` 을 끌어온다. 즉 `AppIdentity.swift`
  를 리포맷(줄바꿈·따옴표 스타일 변경 등)하면 이 파싱이 조용히 빈 문자열을 돌릴 수 있는데, 스크립트가 값이
  비면 즉시 `exit 1` 로 죽으므로 실패는 시끄럽게 난다(의도된 설계). |
| `scripts/release.sh` | 맨 위 중단 가드 |
| `scripts/e2e.sh`, `parity-check.sh` | 번들·로그·스냅샷 경로 |

`release-fork.sh` 2단계가 `Sources/` 에서 원본 정체성 문자열(`chattymin`·`"PokeTokenBar"`·
`PokeTokenBar.log`)을 grep 해 하드 게이트로 막는다 — 머지에서 되돌아온 리터럴은 배포 전에 걸린다.

## 범위를 바꿀 때 (1세대 → 다른 범위)

`PokemonAssets.animatedSpeciesIDs` 하나가 네 곳에 작용한다: 부화 후보 질의(GraphQL `_lte`/`_gt`),
REST 폴백 난수 범위, 스프라이트 로딩, 진화 트리 가지치기. 범위에 비례하지 않는 **고정 임계값을
넣지 마라** — 원본의 `bases.count >= 150` 이 정확히 그래서 1세대에서 항상-실패로 뒤집혔다
(`isRESTIndexUsable` 로 교체됨). `Tests/PokeTokenBarTests/Gen1RangeTests.swift` 가 경계를 고정한다.

## 1세대 범위의 알려진 결과 — 손대지 않기로 한 것

1세대는 (디토를 뺀) 베이스 종이 **78종**이고, 부화 확률 가중치가 common 9695 / uncommon 210 /
rare 1135 / legendary 57 로 나뉜다. 649종 전체 풀과 비교하면 **uncommon 밴드가 2종뿐**으로
좁아져, Uncommon Egg 로 부화하면 rare-이상이 나올 확률이 **85%**다
(`rarePlusShare` = (1135+57)/(210+1135+57) = 1192/1402 ≈ 0.8502).

현재 가격(Uncommon 2.5B, Rare 4.0B)의 손익분기는 `uncommonPrice / rarePrice` = 2.5/4.0 = **0.625**다.
0.8502 > 0.625 이므로 **Rare Egg 가 지배당하는(dominated) 상품**이 된다 — rare-이상 1개를 얻는 데
드는 기대비용이 Uncommon Egg 반복 구매로는 `2.5B / 0.8502` ≈ **2.94B**인데, Rare Egg 직접 구매는
**4.0B**다. 즉 이 가격대에서는 항상 Uncommon Egg 를 반복 사는 쪽이 더 싸다.

`PremiumEggTests.testRareEggIsNotDominatedAtMeasuredPoolComposition` 은 이 역전을 **못 잡는다** —
그 테스트가 단언하는 가중치(`weight[.common] = 37_240` 등)는 포크 이전 649종 풀의 하드코딩된
스냅샷이고, 1세대 78종 풀로 갱신돼 있지 않다. 즉 이 테스트가 통과한다고 해서 "Rare Egg 가
지배당하지 않는다"가 1세대에서도 참인 것은 **아니다** — 읽는 사람이 착각하지 않도록 남긴다.

오너가 이 역전을 검토했고, **upstream 가격을 그대로 유지하기로 결정**했다. 버그가 아니라
받아들인 트레이드오프로 기록한다.

## 하지 않는 것

- Apple 공증 — 개발자 계정 비용. 대신 `install.sh` 가 quarantine 을 해제한다.
- Homebrew cask·랜딩 페이지·다국어 README 갱신 — 원본 파이프라인의 산출물이고 이 포크엔 없다.
