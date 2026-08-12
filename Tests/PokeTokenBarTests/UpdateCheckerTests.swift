import XCTest
@testable import PokeTokenBar

final class UpdateCheckerTests: XCTestCase {
    func testNewerPatch() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.2", than: "2.0.1"))
    }
    func testSameIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("2.0.1", than: "2.0.1"))
    }
    func testOlderIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("2.0.0", than: "2.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("2.0.9", than: "2.1.0"))
    }
    func testNumericNotLexical() {
        // "2.0.10" 은 "2.0.9" 보다 높다 (문자열 비교면 반대로 틀림)
        XCTAssertTrue(UpdateChecker.isNewer("2.0.10", than: "2.0.9"))
    }
    func testMinorAndMajor() {
        XCTAssertTrue(UpdateChecker.isNewer("2.1.0", than: "2.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("3.0.0", than: "2.9.9"))
    }
    func testDifferentComponentCounts() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.1", than: "2.0"))   // 2.0.1 > 2.0.0
        XCTAssertFalse(UpdateChecker.isNewer("2.0", than: "2.0.0"))  // 동일
    }
}

// MARK: brew cask 업그레이드 경로
//
// 이 경로는 한 번 통째로 삭제된 적이 있다(ba041b8). cask 토큰만 원본 것으로 남아 있어서, 원본을
// brew 로 설치한 Mac 에서 포크가 자신을 종료한 뒤 **원본 번들을 덮어쓰고** 정작 자신은 갱신되지
// 않았다. 아래 테스트는 그 결함이 되돌아오는 경로를 각각 하나씩 막는다 — 실행 없이 텍스트로
// 검증할 수 있게 `upgradeScript`·`caskListArguments` 가 프로퍼티로 뽑혀 있다.

final class UpdateCheckerBrewTests: XCTestCase {

    // MARK: cask 판정

    func testCaskListArgumentsTargetThisForksCask() {
        XCTAssertEqual(UpdateChecker.caskListArguments, ["list", "--cask", "pika-token-bar"])
        XCTAssertFalse(UpdateChecker.caskListArguments.contains("poke-token-bar"),
                       "원본 cask 를 조회하면 원본이 설치된 Mac 에서 참이 되어 남의 앱을 업그레이드한다")
    }

    func testCaskTokenComesFromAppIdentity() {
        XCTAssertEqual(UpdateChecker.caskListArguments.last, AppIdentity.brewCaskToken)
    }

    /// brew 가 없으면 판정 자체가 불가 → nil(릴리스 페이지 폴백). curl 설치 사용자가 여기 해당한다.
    func testNoBrewMeansNoCaskPath() {
        XCTAssertNil(UpdateChecker.brewCaskPath(brew: nil) { _, _ in true })
    }

    func testCaskInstalledReturnsBrewPath() {
        XCTAssertEqual(UpdateChecker.brewCaskPath(brew: "/opt/homebrew/bin/brew") { _, _ in true },
                       "/opt/homebrew/bin/brew")
    }

    /// brew 는 있지만 이 cask 로 설치된 게 아니면 nil — curl 로 깔고 brew 도 쓰는 사용자.
    func testBrewWithoutThisCaskReturnsNil() {
        XCTAssertNil(UpdateChecker.brewCaskPath(brew: "/opt/homebrew/bin/brew") { _, _ in false })
    }

    /// 판정에 넘기는 인자가 실제로 우리 cask 인지 — probe 를 통과한 인자를 직접 붙잡는다.
    func testProbeReceivesThisForksCaskArguments() {
        var seen: [String] = []
        _ = UpdateChecker.brewCaskPath(brew: "/opt/homebrew/bin/brew") { _, args in
            seen = args
            return true
        }
        XCTAssertEqual(seen, ["list", "--cask", "pika-token-bar"])
    }

    // MARK: 업그레이드 스크립트

    func testUpgradeScriptUpgradesThisForksCask() {
        let s = UpdateChecker.upgradeScript
        XCTAssertTrue(s.contains("upgrade --cask pika-token-bar"))
        XCTAssertFalse(s.contains("poke-token-bar"),
                       "원본 cask 를 업그레이드하면 /Applications/PokeTokenBar.app 을 덮어쓴다")
    }

    /// `brew update` 가 빠지면 로컬 tap 이 낡아 `upgrade` 가 no-op(exit 0) 이 되고,
    /// 앱만 종료된 채 아무것도 안 바뀐다 — 원본이 실제로 겪은 회귀다.
    func testUpgradeScriptRefreshesTapBeforeUpgrading() {
        let s = UpdateChecker.upgradeScript
        guard let update = s.range(of: "\"$1\" update"),
              let upgrade = s.range(of: "\"$1\" upgrade") else {
            return XCTFail("update 또는 upgrade 호출을 찾지 못했다")
        }
        XCTAssertTrue(update.lowerBound < upgrade.lowerBound, "update 는 upgrade 보다 먼저여야 한다")
    }

    /// 실행 중 번들 교체 레이스 회피 — 종료를 기다리는 대상이 이 앱이어야 한다.
    func testUpgradeScriptWaitsForThisAppToExit() {
        XCTAssertTrue(UpdateChecker.upgradeScript.contains("pgrep -x \(AppIdentity.executableName)"))
        XCTAssertTrue(UpdateChecker.upgradeScript.contains("pgrep -x PikaTokenBar"))
    }

    /// 재오픈은 이 포크의 로그인 에이전트를 깨워야 한다 — 라벨이 어긋나면 앱이 안 돌아온다.
    func testUpgradeScriptReopensThisForksAgent() {
        XCTAssertTrue(UpdateChecker.upgradeScript.contains("gui/$(id -u)/\(AppIdentity.loginAgentLabel)"))
        XCTAssertFalse(UpdateChecker.upgradeScript.contains("chattymin"))
    }

    /// brew 가 멈춰도 앱이 종료된 채 영영 안 돌아오면 안 된다 — 워치독과 재오픈 폴백.
    func testUpgradeScriptCannotLeaveTheAppDown() {
        let s = UpdateChecker.upgradeScript
        XCTAssertTrue(s.contains("kill -0"), "brew hang 감시 루프가 없다")
        XCTAssertTrue(s.contains("kill \"$brew_pid\""), "hang 시 brew 를 정리하지 않는다")
        XCTAssertTrue(s.contains("open \"$2\""), "kickstart 실패 시 open 폴백이 없다")
    }

    /// 경로는 본문에 보간하지 않고 positional 인자로만 넘긴다 — 공백·따옴표가 섞이면 셸 인젝션이다.
    func testUpgradeScriptTakesPathsPositionally() {
        let s = UpdateChecker.upgradeScript
        XCTAssertTrue(s.contains("\"$1\""), "brew 경로가 positional 이 아니다")
        XCTAssertTrue(s.contains("\"$2\""), "번들 경로가 positional 이 아니다")
        XCTAssertFalse(s.contains("/Applications/"), "번들 경로가 스크립트 본문에 박혀 있다")
    }
}
