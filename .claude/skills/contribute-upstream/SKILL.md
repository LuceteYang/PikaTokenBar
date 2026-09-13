---
name: contribute-upstream
description: Use when work done in this PikaTokenBar fork is headed for upstream chattymin/PokeTokenBar — starting a feature meant to be contributed, extracting a fork commit onto an upstream-based branch, opening or tracking that PR, or deciding what to do with the branch after it merges or stalls.
---

# Contribute Upstream

포크에서 **만들고**, 원본 기준으로 **다시 딴다**. 내 저장소로 되돌아오는 건 PR 이 아니라
**다음 동기화**가 한다.

    ① sync    upstream/main 을 Pika main 에 통째로 머지        ← 기능 시작 전에 먼저
         ↓
    ② 개발    Pika 에서 feat/<topic> → 구현 → 빌드·실사용 확인
         ↓
    ③ 추출    upstream/main 기준 브랜치로 옮겨 담아 → 영어 PR
         ↓
    ④ 귀환    upstream 스쿼시 머지 → 다음 ① 에서 Pika 로 들어옴

반영 방향(원본 → 포크)은 `upstream-sync` 스킬이 담당한다. 이 스킬은 **나가는 방향**이다.

## 별도 clone 은 필요 없다

`LuceteYang/PikaTokenBar` 는 `chattymin/PokeTokenBar` 의 **GitHub 포크**다(이름만 다르다).
같은 fork network 안이라 `LuceteYang:feat/x → chattymin:main` cross-repo PR 이 성립한다.
이 저장소에 `upstream` 리모트가 이미 붙어 있으므로 원본 기준 브랜치도 여기서 판다.

원본 기준 브랜치를 **동시에** 열어둬야 하면 clone 말고 worktree 를 쓴다:

    git worktree add /tmp/ptb-upstream -b contrib/<topic> upstream/main
    git worktree remove /tmp/ptb-upstream        # 끝나면

## ① 기능 시작 전에 sync 한다

오래된 base 에서 만들면 ③의 cherry-pick 이 남의 변경 위에서 깨진다. 기능을 시작하기 전에
`upstream-sync` 로 `main` 을 최신화한다. 이미 최신이면 넘어간다.

    git fetch upstream && git log --oneline main..upstream/main     # 비어 있으면 바로 ②

## ② 개발과 검증은 포크에서 한다

원본 기준 브랜치가 아니라 **Pika main 기준**으로 딴다. 실제 앱으로 확인할 수단이 포크에만 있기
때문이다 — `AppIdentity`, `build-app.sh` 의 정체성 주입, 설치된 `PikaTokenBar.app`.

    git switch -c feat/<topic> main
    swift test && ./scripts/test-gate.sh
    ./scripts/build-app.sh            # PikaTokenBar.app 로 설치 — 며칠 써보고 판단한다

## ③ 원본 기준으로 다시 담아 PR

포크 `main` 에는 정체성 변경이 얹혀 있다. **거기서 뻗은 브랜치로 PR 을 만들면 안 된다.**

올리기 전에 세 조건을 **모두** 만족하는지 본다:

- `AppIdentity` 를 참조하지 않는다
- 1세대 범위를 가정하지 않는다 — #649 에서도 참이어야 한다
- 원본에서 **실제로 재현되는** 문제를 고친다 (내 범위에서만 드러나는 잠재 결함이면 원본 기준
  재현을 먼저 확인한다. 재현 안 되면 "견고성 개선"으로 제안하되 거절될 수 있음을 안다)

앞의 둘은 추상적이라 판정이 흔들린다. 구체적인 판정표는 `docs/reference/fork-maintenance.md` 의
**포크가 소유한 파일** 표다 — 내 diff 가 그 표의 파일을 건드렸으면 자격을 다시 본다.

    git fetch upstream
    git switch -c contrib/<topic> upstream/main
    git cherry-pick <feat 브랜치의 커밋들>
    swift build && swift test                    # 원본 CI 가 도는 것과 같다 (CONTRIBUTING.md)
    git push -u origin contrib/<topic>
    gh pr create --repo chattymin/PokeTokenBar --base main \
                 --head LuceteYang:contrib/<topic>

cherry-pick 이 정체성·범위 변경을 끌고 오면 **커밋을 쪼개지 말고 ② 에서 애초에 나눠 둔다** — 기여할
변경과 포크 전용 변경을 같은 커밋에 담지 않는 게 유일하게 싼 방법이다. 이미 섞인 커밋이라면:

    git cherry-pick -n <sha>
    git restore --staged --worktree <포크 전용 파일>
    git diff --cached                            # 남은 게 기여분뿐인지 눈으로 본다

**여기서 `./scripts/build-app.sh` 를 돌리지 않는다** — 원본 판 스크립트는 `PokeTokenBar.app` 을
`/Applications` 에 설치해 원본 설치본을 덮어쓴다. 이 브랜치의 검증은 `swift build && swift test` 까지다.
앱으로 확인할 것이 남았으면 ②의 포크 브랜치에서 한다.

PR 제목·본문은 **영어**다(`CLAUDE.md` 기여 언어 규약 — 한국어로 지시받아도 산출물은 영어).
포크 이야기는 쓰지 않는다. 원본 입장에서 그 변경이 왜 옳은지만 쓴다. 나머지 규약은 원본 것을
따른다 — 제목은 Conventional Commits(`fix:`·`feat:`…), 본문은 `.github/PULL_REQUEST_TEMPLATE.md`
체크리스트를 채우고, `Sources/PokeTokenBar/UI/` 를 건드렸으면 before/after 를 글로 적는다
(`CONTRIBUTING.md`).

**AI 생성·공동작성 트레일러는 붙이지 않는다.** 머지된 #212·#241·#270 본문에 없다 — 외부
메인테이너에게 가는 산출물이고, 공동작성자는 실제 사람만 적는 게 이 저장소 규약이다(`CLAUDE.md`).

## ④ 착지 — feat 브랜치를 Pika main 에 머지하지 않는다

PR 이 머지되면 upstream 에 **스쿼시 커밋 한 개**로 들어간다. 그게 다음 sync 때 Pika 로 온다.
같은 변경을 로컬에서 main 에 미리 머지해 두면, 그 스쿼시본이 **다른 위치에 두 번째 사본**으로
들어와 git 이 충돌로 잡지 못하고 조용히 둘 다 남긴다. 컴파일러의 `invalid redeclaration` 이
유일한 신호다(`docs/reference/fork-maintenance.md` §머지에서 매번 나오는 두 부류).

    PR 을 올린 뒤 feat/<topic> 은 그대로 둔다. main 에 머지하지 않는다.
    gh pr list --repo chattymin/PokeTokenBar --author LuceteYang --state all

머지를 확인했다고 바로 지우지 않는다. **다음 sync 가 그 변경을 `main` 에 실제로 들여놓은 뒤**
지운다 — 그 전에 지우면 sync 가 틀어졌을 때 되돌릴 원본이 없다.

    git branch -d feat/<topic> contrib/<topic>
    git push origin --delete contrib/<topic>

**탈출구 두 개** — 대기가 성립하지 않는 상황이다:

| 상황 | 처리 |
|---|---|
| 머지 전에 그 기능을 내 앱에서 써야 한다 | `feat/<topic>` 에서 `build-app.sh` 로 설치해 쓴다. **main 에는 올리지 않는다** — 릴리스는 main 에서만 나가므로 배포본은 여전히 깨끗하다 |
| PR 이 거절됐거나 오래 방치됐다 | 포크 고유 기능으로 전환한다. `feat/<topic>` 을 main 에 머지하고, 커밋 메시지에 PR 번호와 "upstream 에 안 들어감"을 남긴다. 이후 sync 에서 중복 사본이 올 일이 없다 |

## Quick Reference

| 상황 | 할 일 |
|---|---|
| 기여할 기능을 시작한다 | 먼저 sync → `git switch -c feat/<topic> main` |
| 만든 걸 원본에 올린다 | 자격 3조건 확인 → `contrib/<topic>` (base `upstream/main`) → cherry-pick → 영어 PR |
| 원본 기준으로 앱을 돌려보고 싶다 | 돌리지 않는다. `swift test` 까지. 앱 확인은 포크 브랜치에서 |
| PR 머지됨 | 아무것도 안 한다. 다음 sync 가 가져온다 → 그 뒤 브랜치 삭제 |
| PR 거절·방치 | 포크 고유 기능으로 전환해 main 에 머지 |
| 원본이 뭐 바뀌었나 / 머지 충돌 | 이 스킬 아님 → `upstream-sync` |

## Common Mistakes

| 실수 | 왜 나쁜가 |
|---|---|
| 포크 `main` 에서 뻗은 브랜치로 upstream PR | 정체성 변경이 딸려가 리뷰가 산으로 간다 |
| 오래된 main 에서 기능 시작 | ③ cherry-pick 이 남의 변경 위에서 깨져 결국 손으로 다시 옮긴다 |
| PR 올린 기능을 Pika main 에 미리 머지 | 다음 sync 에서 스쿼시본이 **두 번째 사본**으로 조용히 들어온다. 충돌이 아니라 `invalid redeclaration` 으로 터진다 |
| upstream 기준 브랜치에서 `build-app.sh` | `/Applications/PokeTokenBar.app` 을 덮어쓴다 — 원본 설치본을 밀어버린다 |
| PR 본문을 한국어로 | 스쿼시 머지라 PR 제목이 곧 원본 `main` 커밋 제목이 된다 |
| 원본에 못 올릴 걸 `contrib/` 에 담아 push | 정체성·1세대 범위에 걸리면 리뷰에서 되돌아온다. 올리기 전에 자격 3조건을 본다 |
