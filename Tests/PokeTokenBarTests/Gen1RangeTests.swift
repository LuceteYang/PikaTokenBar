import XCTest
@testable import PokeTokenBar

// MARK: 1세대(#1–151) 범위 회귀
//
// 범위를 649→151 로 좁히면 두 곳이 조용히 깨진다. 둘 다 "좁히기 전에는 존재하지 않던 조건"이라
// 기존 테스트가 밟지 않는 경로다:
//   ① 진화 전 단계가 범위 밖인 라인(피카츄←피츄 #172) → base 후보에서 사라짐
//   ② 체인 루트가 범위 밖인 라인 → 루트부터 가지치기하면 트리가 통째로 nil
// 아래는 그 트리거 조건 자체를 재현한다.

final class Gen1RangeTests: XCTestCase {

    // MARK: 범위 경계

    func testRangeIsKantoOnly() {
        XCTAssertEqual(PokemonAssets.animatedSpeciesIDs, 1...151)
    }

    func testBoundarySpeciesInclusion() {
        XCTAssertTrue(PokemonAssets.hasAnimatedSprite(speciesID: 1))    // 이상해씨
        XCTAssertTrue(PokemonAssets.hasAnimatedSprite(speciesID: 151))  // 뮤 — 포함 경계
        XCTAssertFalse(PokemonAssets.hasAnimatedSprite(speciesID: 152)) // 치코리타 — 제외 경계
        XCTAssertFalse(PokemonAssets.hasAnimatedSprite(speciesID: 172)) // 피츄 — 범위 밖 베이비
        XCTAssertFalse(PokemonAssets.hasAnimatedSprite(speciesID: 0))
    }

    // MARK: 진화 트리 re-root
    //
    // PokéAPI 는 체인의 **전체 루트**를 준다. 피카츄 라인을 요청해도 루트는 피츄(#172)다.

    /// 피츄(#172) → 피카츄(#25) → 라이츄(#26) 체인. baseID 는 피카츄.
    private func pichuChain() -> EvoNode {
        EvoNode(speciesID: 172, children: [
            EvoNode(speciesID: 25, children: [
                EvoNode(speciesID: 26, children: []),
            ]),
        ])
    }

    private func line(baseID: Int, tree: EvoNode) -> EvoLine {
        EvoLine(baseID: baseID, tree: tree,
                rarity: Rarity.from(captureRate: 190, isLegendary: false, isMythical: false),
                names: [:])
    }

    func testOutOfRangeRootChainKeepsEvolutions() {
        let l = line(baseID: 25, tree: pichuChain())
        // re-root 없이 루트(피츄)부터 가지치기하면 nil 로 붕괴 → 폴백이 자식 없는 피카츄만 남긴다.
        XCTAssertEqual(l.tree.speciesID, 25)
        XCTAssertEqual(l.tree.children.map(\.speciesID), [26], "피카츄→라이츄 진화가 사라졌다")
        XCTAssertEqual(l.tree.finalIDs, [26])
    }

    func testOutOfRangeRootIsNotReachable() {
        let l = line(baseID: 25, tree: pichuChain())
        XCTAssertNil(l.tree.node(withID: 172), "범위 밖 피츄가 트리에 남아 있다")
    }

    /// baseID == 루트인 일반 라인은 re-root 도입 전후로 동작이 같아야 한다.
    func testNormalLineUnchangedByReRoot() {
        let bulbasaur = EvoNode(speciesID: 1, children: [
            EvoNode(speciesID: 2, children: [EvoNode(speciesID: 3, children: [])]),
        ])
        let l = line(baseID: 1, tree: bulbasaur)
        XCTAssertEqual(l.tree.speciesID, 1)
        XCTAssertEqual(l.tree.children.map(\.speciesID), [2])
        XCTAssertEqual(l.tree.finalIDs, [3])
    }

    /// 범위 밖 최종 진화는 잘려야 한다 — 예: 이브이(#133) 라인의 블래키(#197).
    func testOutOfRangeEvolutionIsPruned() {
        let eevee = EvoNode(speciesID: 133, children: [
            EvoNode(speciesID: 134, children: []),   // 샤미드 — 범위 안
            EvoNode(speciesID: 197, children: []),   // 블래키 — 2세대, 잘려야 함
        ])
        let l = line(baseID: 133, tree: eevee)
        XCTAssertEqual(l.tree.children.map(\.speciesID), [134])
    }
}

// MARK: REST 폴백 인덱스 완성도 판정
//
// 원래 판정은 `bases.count >= 150` 이었다. 150 은 649 범위에서 나온 숫자라 1세대(base 약 78종)에선
// 절대 통과하지 못한다 — 인덱스가 영영 캐시되지 않고 매 세션 REST 를 재구축한다. 판정 신호를
// "찾은 base 개수"(범위·진화 구조에 따라 변함)에서 "실패한 요청 비율"(범위 무관)로 바꾼 것을 고정한다.

final class RESTIndexCompletenessTests: XCTestCase {

    func testCleanSweepIsUsable() {
        XCTAssertTrue(PokeAPIClient.isRESTIndexUsable(attempted: 151, failed: 0))
    }

    /// 1세대 전수 훑기에서 base 는 약 78종뿐 — 옛 `count >= 150` 판정이 죽던 바로 그 지점.
    func testFewBasesButNoFailuresIsUsable() {
        XCTAssertTrue(PokeAPIClient.isRESTIndexUsable(attempted: 151, failed: 0),
                      "base 개수가 적다는 이유로 인덱스를 버리면 안 된다")
    }

    func testToleratesSmallFailureRate() {
        XCTAssertTrue(PokeAPIClient.isRESTIndexUsable(attempted: 151, failed: 15))   // 약 10%
    }

    func testRejectsHighFailureRate() {
        XCTAssertFalse(PokeAPIClient.isRESTIndexUsable(attempted: 151, failed: 16))  // 10% 초과
        XCTAssertFalse(PokeAPIClient.isRESTIndexUsable(attempted: 151, failed: 151))
    }

    func testRejectsEmptySweep() {
        XCTAssertFalse(PokeAPIClient.isRESTIndexUsable(attempted: 0, failed: 0))
    }

    // MARK: GraphQL base 질의
    //
    // base 조건은 `evolves_from IS NULL` 만으로 부족하다 — 진화 전이 범위 밖이면(피카츄←피츄 #172)
    // 그 종이 곧 이 범위의 시작점이다. 이 `_or` 가지가 빠지면 1세대 11개 라인이 부화 풀에서 사라진다.

    func testBaseQueryAcceptsOutOfRangePreEvolution() {
        let q = PokeAPIClient.baseIndexQuery(maxID: 151, dittoID: 132)
        XCTAssertTrue(q.contains("evolves_from_species_id: {_is_null: true}"))
        XCTAssertTrue(q.contains("evolves_from_species_id: {_gt: 151}"),
                      "진화 전이 범위 밖인 종을 base 로 받는 가지가 없다")
        XCTAssertTrue(q.contains("_or"))
        XCTAssertTrue(q.contains("_lte: 151"))
        XCTAssertTrue(q.contains("_neq: 132"))
    }

    func testBaseQueryFollowsTheConfiguredRange() {
        let q = PokeAPIClient.baseIndexQuery(maxID: PokemonAssets.animatedSpeciesIDs.upperBound,
                                             dittoID: PokemonOdds.dittoSpeciesID)
        XCTAssertTrue(q.contains("_lte: 151"), "질의가 실제 범위 상한을 따르지 않는다")
    }

    // MARK: 요청은 다 성공했는데 base 를 하나도 못 찾은 경우
    //
    // 실패율만 보면 이 경우를 놓친다 — failed == 0 이라 `isRESTIndexUsable` 는 통과한다. 하지만 빈
    // 배열을 캐싱하면 `baseIndexCache != nil` 이 되어 이번 세션 내내 재시도가 막힌다(REST 재구축
    // 자신도, GraphQL 실패 경로도). `shouldPersistRESTIndex` 가 이 조건을 추가로 걸러낸다.

    func testRejectsCleanSweepThatFoundNothing() {
        XCTAssertFalse(PokeAPIClient.shouldPersistRESTIndex(attempted: 151, failed: 0, foundCount: 0),
                        "요청이 전부 성공했어도 base 를 하나도 못 찾았으면 캐싱하면 안 된다")
    }

    func testPersistsCleanSweepThatFoundBases() {
        XCTAssertTrue(PokeAPIClient.shouldPersistRESTIndex(attempted: 151, failed: 0, foundCount: 78))
    }

    func testShouldPersistStillRespectsFailureRate() {
        XCTAssertFalse(PokeAPIClient.shouldPersistRESTIndex(attempted: 151, failed: 16, foundCount: 78),
                        "실패율 판정을 우회하면 안 된다")
    }

    // MARK: base 판정의 파싱 실패 가드
    //
    // `baseSpecies(id:)` 는 진화 전 URL 을 `id(from:)` 로 파싱해 그 id 가 범위 밖이면 base 로 인정한다.
    // `id(from:)` 파싱에 실패하면 0 을 반환하는데, `guard preEvoID > 0` 가 없으면 0 이 "범위 밖"으로
    // 오인되어 진화 중간체가 base(=부화 가능)로 잘못 승격된다. 이 가드가 그 오인을 막는 절반이다.

    func testIDFromParsesWellFormedSpeciesURL() {
        XCTAssertEqual(PokeAPIClient.id(from: "https://pokeapi.co/api/v2/pokemon-species/25/"), 25)
    }

    func testIDFromReturnsZeroOnMalformedURL() {
        XCTAssertEqual(PokeAPIClient.id(from: "not-a-url"), 0)
    }

    /// 0 은 "이 종의 id" 가 아니라 "파싱 불가"를 뜻한다. 그런데 0 은 애니메이션 스프라이트 범위
    /// (1...151) 밖이라 `!hasAnimatedSprite(0)` 는 true — `guard preEvoID > 0` 이 없으면 파싱 실패가
    /// "진화 전이 범위 밖"으로 오인되어 진화 중간체가 base(=부화 가능)로 잘못 승격된다.
    /// `preEvoID > 0` 가드가 그 오인을 막는 절반이다(baseSpecies(id:) 참고).
    func testZeroLooksOutOfRangeWithoutTheParseGuard() {
        XCTAssertFalse(PokemonAssets.hasAnimatedSprite(speciesID: 0),
                        "0 은 범위 밖으로 보이므로 guard 없이는 base 로 승격된다")
    }
}
