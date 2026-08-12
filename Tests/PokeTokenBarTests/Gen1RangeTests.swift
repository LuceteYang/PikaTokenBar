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
