---
name: benchmarking-for-upstream
description: Use when hunting for feature ideas by surveying comparable token-usage or menu-bar apps on GitHub, when asked what this app should build next, or when judging whether a feature idea is worth building — the answer turns on upstream's backlog and rejection history, not on what rival apps happen to have.
---

# Benchmarking for Upstream

이 저장소는 `chattymin/PokeTokenBar` 의 포크다. **기능 아이디어는 희소하지 않다.** 경쟁 앱을
스무 개 훑으면 후보 서른 개가 나온다. 희소한 건 *upstream 이 아직 안 받았고, 이미 거절하지
않았고, 이 포크의 두 차이(1세대 범위·앱 정체성)에 걸리지 않는* 후보다.

그래서 이 스킬의 내용은 검색 요령이 아니라 **순서**다.

## 순서를 뒤집으면 결과가 통째로 버려진다

경쟁 앱부터 훑고 upstream 을 나중에 확인하면, 남이 이미 올려둔 것을 발견으로 착각한 목록이
나온다. 그 목록은 순위까지 틀린다 — 무엇이 남아 있는지 모르는 채 매긴 순위이기 때문이다.

> 실측(2026-09-11, 이 스킬 없이 같은 작업): 추천 8개 중 **5개가 이미 upstream 에 있었다.**
> 스트릭·공유 카드·효율 점수는 셋이 합쳐 이슈 #260 하나였고, 프로젝트별 분해는 #201·#202 였다.
> 그리고 원작자가 `help wanted` + `good first issue` 로 **직접 모집 중인** 두 건
> (#149 새 UI 언어, #115 새 사용량 프로바이더)은 추천 목록에 아예 없었다.

    1. upstream 백로그를 먼저 읽는다   ← 후보를 만들기 전에
    2. 경쟁 앱을 훑는다
    3. 남은 것만 코드베이스와 대조한다

## 1. upstream 백로그 (먼저)

    gh issue list --repo chattymin/PokeTokenBar --state open --limit 40 \
      --json number,title,labels --jq '.[]|"#\(.number) \(.title) [\(.labels|map(.name)|join(","))]"'
    gh pr list --repo chattymin/PokeTokenBar --state open --limit 30 --json number,title \
      --jq '.[]|"#\(.number) \(.title)"'
    gh pr list --repo chattymin/PokeTokenBar --state closed --limit 40 \
      --json number,title,mergedAt --jq '.[]|select(.mergedAt==null)|"#\(.number) \(.title)"'

여기서 세 가지를 얻는다:

- **이미 요청됨** — 그 이슈에 붙어 구현하는 쪽이 새 아이디어보다 낫다. 원작자가 원한다고 이미
  말해 둔 것이라 방향 논쟁이 없다.
- **이미 거절됨** — 머지되지 않고 닫힌 PR 은 "이 방향은 안 받는다"는 신호다. 닫힌 *이유*까지
  읽어라. (#233 Ollama 프로바이더는 닫혔는데 #115 는 프로바이더를 모집한다 — 모집한다고 아무
  프로바이더나 받는 게 아니다. 이 둘을 같이 안 보면 정반대로 읽는다.)
- **모집 중** — `help wanted`·`good first issue` 라벨. 가장 확실한 기여 경로이고, **경쟁 앱을
  아무리 훑어도 여기서는 안 나온다.**

## 2. 경쟁 앱 훑기

    gh search repos "claude code usage" --sort stars --limit 30
    gh search repos "token usage menubar macos" --sort stars --limit 20

기록하는 건 기능 이름이 아니라 **그 기능이 푸는 문제**다. "히트맵"은 UI 이고, 문제는 "어제도
했는지를 앱이 모른다"다. 문제로 적어야 이 앱의 게임 루프에 맞는 다른 해법이 보인다 — 기능
이름으로 적으면 남의 UI 를 옮겨 그리는 제안이 된다.

## 3. 후보 걸러내기

후보마다 세 질문. **하나라도 아니면 `포크 전용` 으로 분류하고 upstream 추천 목록에서 뺀다**
(버리는 게 아니라 다른 목록으로 옮긴다).

| 질문 | 확인 방법 |
|---|---|
| 정체성과 무관한가 | `AppIdentity` 를 참조해야 하는 기능인가 |
| 649종에서도 참인가 | 151 을 가정하는가. "도감 완성도 %" 같은 지표는 범위에 종속된다 |
| 이미 있지 않은가 | 기억이 아니라 `grep -rn "<개념>" Sources/`. 이름만 다르게 이미 있을 수 있다 |

기여 절차(방향 B — `upstream/main` 기준 브랜치, 영어 PR)는 `upstream-sync` 스킬에 있다.
여기서 반복하지 않는다.

## 추천 하나의 형식

추천은 아래 슬롯을 **전부** 채운다. 못 채우는 슬롯이 있으면 그건 아직 추천이 아니라 조사 대상이다.

    ### <기능 이름>
    - **푸는 문제**: <기능이 아니라 문제로>
    - **근거**: <앱 이름 ★수> — 거기서 어떤 모양인가
    - **upstream 상태**: 없음 | #NNN 이슈로 요청됨 | #NNN PR 진행 중 | #NNN 로 거절됨
    - **자격**: 기여 가능 | 포크 전용(이유)
    - **손댈 지점**: <파일·확장 지점. `provider-extension.md` 가 정해 둔 지점인가>

`upstream 상태` 와 `자격` 이 이 형식이 존재하는 이유다. 나머지 셋은 그 둘을 판단하기 위한
재료다. 근거 없이 별점만 적힌 줄은 슬롯을 채운 게 아니다.

## 순위

**기여 가능성 순으로 정렬한다. 재미있는 순이 아니다.**

1. `help wanted` / `good first issue` 라벨이 붙은 것
2. upstream 이슈로 요청됐는데 아무도 손대지 않은 것 (열린 PR 이 없는 이슈)
3. 백로그에 없고 세 질문을 통과한 것
4. *(별도 목록)* 포크 전용 — 범위·정체성 때문에 upstream 에 못 가는 것

## Common Mistakes

| 실수 | 왜 나쁜가 |
|---|---|
| 경쟁 앱부터 훑는다 | 후보 절반이 이미 upstream 에 있는데 그걸 모른 채 순위를 매긴다 |
| 열린 이슈만 본다 | 닫힌 PR 이 "안 받는 방향"을 알려준다. 빼먹으면 거절될 것을 추천한다 |
| 라벨을 안 읽는다 | `help wanted` 는 원작자가 손 들어 달라고 한 것이다. 가장 쉬운 기여를 놓친다 |
| 포크 제품 논리로 순위 | "이 앱만의 무기" 는 포크 기준이다. 기여가 목표면 649종에서도 참인지가 먼저다 |
| 있는지 기억으로 판단 | 이름만 다르게 이미 구현돼 있다. `grep Sources/` 로 확인한다 |
| grep 히트를 결함으로 단정 | 리터럴 분기 하나 봤다고 "확장 규약 위반" 이라 쓰지 마라. **주변 주석을 먼저 읽어라** — 의도된 결정이면 위반이 아니라 설계다. 위반으로 단정한 제안은 기여가 아니라 리뷰 싸움이 된다 (`UsageStore.claudeActiveBlock` 이 정확히 그 예: `== "claude_code"` 지만 "Claude 공식 한도와 짝" 이라는 이유가 바로 위에 적혀 있다). 남는 관찰은 "위반"이 아니라 "Codex·Antigravity 도 공식 한도가 있는데 예측을 못 받는다"로 적는다 |
| 별점을 근거로 쓴다 | ★수는 그 앱의 인기지 그 기능의 근거가 아니다. 그 기능이 *어떤 문제를 푸는지*를 적어라 |
