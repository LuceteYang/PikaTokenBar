---
name: upstream-sync
description: Use when this fork's relationship to upstream chattymin/PokeTokenBar comes up — checking what changed upstream, deciding whether to take an upstream change, resolving a merge conflict in a fork-owned file, or judging whether a local fix belongs upstream.
---

# Upstream Sync

이 저장소는 `chattymin/PokeTokenBar` 의 포크(PikaTokenBar)다. 원본과 다른 점은 **두 가지뿐**이고,
모든 판단은 이 둘로 환원된다:

1. **범위** — 등장 포켓몬이 1세대(#1–151)다. (`PokemonAssets.animatedSpeciesIDs`)
2. **정체성** — 원본과 같은 Mac 에 공존하는 별개 앱이다. (`AppIdentity`)

그 외 모든 것 — 버그 수정, 새 사용량 프로바이더, UI 개선, 성능 — 은 **원본을 따라간다.**
포크는 원본에서 갈라져 나온 제품이 아니라 **두 군데만 다른 같은 제품**이다.

정책 원본(포크 소유 파일 목록·릴리스 절차)은 `docs/reference/fork-maintenance.md` 다. 이 스킬은
그 문서를 대체하지 않고 **언제·어떤 순서로 판단하는가**를 담는다.

## 방향 A: 원본 → 포크 (반영)

### 거부는 cherry-pick 이 아니라 revert 다

가장 흔한 실수다. 원하는 커밋만 `cherry-pick` 하면 `merge-base` 가 제자리에 머물러 **다음 동기화
때 이미 판단한 커밋이 전부 다시 올라온다.** 동기화할수록 심사량이 늘고, 결국 아무도 안 하게 된다.

    항상 upstream/main 을 통째로 머지한다.
    거부는 그 위에 얹는 revert 커밋으로 표현한다.

이러면 merge-base 가 전진해 같은 커밋을 두 번 심사하지 않는다. 그리고 revert 커밋 메시지에
**원본 커밋 해시와 거부 이유**를 적으면 git history 자체가 결정 로그가 된다 — 따로 표를 관리하지 않는다.

    git log --grep="upstream-reject"     # 지금까지 거부한 것과 그 이유

### 동기화는 스쿼시 PR 로 올리지 않는다

이건 위의 merge-then-revert 를 **조용히 무효로 만드는** 함정이라, 순서상 먼저 못 박는다.

이 저장소는 스쿼시 머지다(`CLAUDE.md`). 스쿼시는 브랜치를 **부모가 하나뿐인 새 커밋**으로 납작하게
만든다 — 머지 커밋의 두 번째 부모(upstream 계보)가 사라진다. 그러면 `upstream/main` 은 여전히
`main` 의 조상이 아니고, 통째로 머지해서 얻으려던 것이 통째로 날아간다. **cherry-pick 을 피한 의미가
없어진다.**

그리고 이건 조용히 실패한다. 코드는 전부 들어와 있어 정상으로 보이고, 다음 동기화에서 같은 커밋
6개가 다시 올라오고 나서야 알게 된다.

동기화 결과는 **`main` 에 직접 push 한다.**

    git switch main
    git merge upstream/main
    # (적응·거부 커밋)
    git push origin main

리뷰를 거치고 싶으면 PR 을 열되 **merge commit 으로 머지한다** — `gh pr merge --merge`,
`--squash`·`--rebase` 금지. 평소 기능 개발의 스쿼시 규약은 그대로 두고, **동기화 PR 만 예외**다.

### 충돌 해소를 재사용한다

같은 충돌이 동기화마다 같은 자리에서 난다(정체성 리터럴·범위 상수). 한 번 해소한 걸 git 이 기억하게 한다:

    git config rerere.enabled true

### 절차

    git fetch upstream
    git log --oneline main..upstream/main
    git diff main...upstream/main --stat

각 커밋을 아래 셋 중 하나로 분류한다:

| 판정 | 조건 | 처리 |
|---|---|---|
| **수용** | 범위·정체성과 무관 (버그 수정·새 프로바이더·UI·성능) | 그대로 둔다 — 대부분 여기다 |
| **적응** | 포크 소유 파일을 건드림 (정체성 리터럴·범위 상수) | 머지 후 포크 값으로 되돌린다 |
| **거부** | 이 포크의 목적과 충돌 (2세대 이상 콘텐츠·원본 배포 경로·cask/랜딩) | 머지 후 revert |

그다음:

    git merge upstream/main

충돌이 나면 **포크 소유 파일은 내 쪽을 지킨다.** 어떤 파일이 그런지는
`docs/reference/fork-maintenance.md` 의 표에 있다 — 외우지 말고 그 표를 열어라.

"적응"·"거부" 처리는 머지 커밋과 **분리된 후속 커밋**으로 한다. 머지 커밋 안에서 손보면 나중에
"원본이 뭘 줬고 내가 뭘 덜어냈는지"가 한 덩어리로 뭉개진다.

    git revert --no-commit <upstream-sha>
    git commit -m "upstream-reject <upstream-sha>: <한 줄 이유>"

revert 는 커밋일 뿐이라 **git 에게 그 내용을 앞으로도 거부하라고 가르치지 않는다.** 원본이 나중에
거부한 코드 위에 무언가를 쌓으면 그 변경이 다시 들어온다(삭제한 파일이 재추가되는 경우는 충돌
없이 조용히 들어온다). 다음 동기화에서 같은 판정을 다시 내리면 된다 —
`git log --grep="upstream-reject"` 가 그때 "전에 왜 거부했는지"를 준다.

검증 후 배포:

    swift test && ./scripts/test-gate.sh
    ./scripts/release-fork.sh <version>

`release-fork.sh` 의 정체성 누수 게이트가 머지에서 되돌아온 원본 리터럴을 배포 전에 잡는다.
**그 게이트가 걸리면 머지 해소가 틀린 것이다** — 게이트를 끄지 말고 해소를 고쳐라.

### 판단이 애매할 때

범위와 무관해 보이는데 확신이 안 서면, **수용 쪽으로 기운다.** 포크의 목적은 원본에서 멀어지는 게
아니라 두 지점만 다르게 유지하는 것이다. 불필요하게 거부할수록 다음 머지가 어려워진다.

## 방향 B: 포크 → 원본 (기여)

포크에서 고친 것 중 **범위·정체성과 무관한 것**은 원본 사용자에게도 이롭다. 원본에 올리면 다음
동기화 때 그 수정이 upstream 쪽에서 돌아와 포크의 diff 가 줄어든다 — 유지비가 내려간다.

### 자격

세 가지를 **모두** 만족해야 후보다:

- `AppIdentity` 를 참조하지 않는다 (정체성 무관)
- 1세대 범위를 가정하지 않는다 — 649 에서도 참이어야 한다
- 원본에서 **실제로 재현되는** 문제를 고친다 (내 범위에서만 드러나는 잠재 결함이면, 원본 기준으로
  재현되는지 먼저 확인한다. 재현 안 되면 "견고성 개선"으로 제안하되 거절될 수 있음을 안다)

### 절차

포크 `main` 은 정체성 변경을 이고 있으므로 **거기서 PR 을 만들면 안 된다.** 원본 기준으로 새로 딴다:

    git fetch upstream
    git checkout -b fix/<topic> upstream/main
    git cherry-pick <내-커밋-sha>       # 정체성 변경이 섞여 있으면 손으로 덜어낸다
    swift test                          # 649 범위 기준으로 통과해야 한다
    git push -u origin fix/<topic>
    gh pr create --repo chattymin/PokeTokenBar --base main

**PR 제목·본문은 영어로 쓴다** (`CLAUDE.md` 기여 언어 규약 — 한국어로 지시받아도 산출물은 영어).
포크에 대한 언급은 PR 에 넣지 않는다. 원본 입장에서 그 변경이 왜 옳은지만 쓴다.

## Quick Reference

| 상황 | 할 일 |
|---|---|
| "원본 뭐 바뀌었어?" | `git fetch upstream && git log --oneline main..upstream/main` |
| 원본 변경을 반영 | `main` 에서 통째로 머지 → 적응/거부는 후속 커밋 → `main` 에 직접 push |
| 동기화를 PR 로 올리고 싶다 | 열되 `gh pr merge --merge`. 스쿼시하면 계보가 날아간다 |
| 원본 커밋이 포크 목적과 충돌 | 머지 후 `git revert` + `upstream-reject <sha>:` 커밋 메시지 |
| 머지 충돌 | `fork-maintenance.md` 표에서 포크 소유 파일 확인 → 내 쪽 유지 |
| 지금까지 뭘 거부했지? | `git log --grep="upstream-reject"` |
| 내 수정을 원본에 | `upstream/main` 기준 브랜치 → cherry-pick → 영어 PR |

## Common Mistakes

| 실수 | 왜 나쁜가 |
|---|---|
| 동기화 PR 을 스쿼시 머지 | 머지 커밋이 부모 하나로 납작해져 upstream 계보가 사라진다 — 통째로 머지한 의미가 없어지고, **조용히** 그렇게 된다 |
| 원하는 커밋만 cherry-pick | merge-base 가 안 움직여 다음 동기화 때 전부 다시 심사한다 |
| 머지 커밋 안에서 거부분 정리 | 원본이 준 것과 내가 덜어낸 것이 뭉개져 나중에 판독 불가 |
| 충돌에서 원본 값 채택 | 정체성이 되돌아가 두 앱이 같은 데이터를 쓴다 |
| 누수 게이트를 끄고 배포 | 게이트가 잡은 건 머지 해소 오류다. 게이트가 아니라 해소를 고쳐라 |
| 포크 `main` 에서 upstream PR | 정체성 변경이 딸려간다. `upstream/main` 기준으로 새 브랜치를 판다 |
| 애매하면 거부 | 포크가 불필요하게 멀어지고 다음 머지가 더 어려워진다 |
