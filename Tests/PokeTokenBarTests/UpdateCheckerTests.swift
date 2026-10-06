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

    // MARK: - Detached upgrade script wait loop (#175)

    func testDetachedUpgradeScriptWaitsOnPidNotProcessName() {
        let script = UpdateChecker.detachedUpgradeScript
        XCTAssertFalse(
            script.contains("pgrep -x"),
            "pgrep -x matches any instance by name and always times out when a duplicate runs"
        )
        XCTAssertTrue(
            script.contains("kill -0 \"$3\""),
            "the wait loop must wait on the specific terminating PID via $3"
        )
    }

    // MARK: - Cooldown stamps only after a successful, validated check

    private static let releaseURL = "https://github.com/chattymin/PokeTokenBar/releases/tag/v2.5.5"

    @MainActor
    private func isolatedDefaults() -> UserDefaults {
        let suite = "UpdateCheckerTests.check.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// A failed GitHub lookup must not start the 30-minute cooldown: otherwise opening the
    /// popover again stays silent until the timer expires, even though no release was seen.
    @MainActor
    func testFailedCheckDoesNotStartTheCooldown() async {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var fetches = 0
        let checker = UpdateChecker(currentVersion: "2.5.3", clock: { now }, defaults: isolatedDefaults()) {
            fetches += 1
            return nil
        }

        await checker.check(minInterval: 1_800)
        XCTAssertEqual(fetches, 1)
        XCTAssertNil(checker.available)

        now = now.addingTimeInterval(5)
        await checker.check(minInterval: 1_800)
        XCTAssertEqual(fetches, 2, "a failed check must not suppress the next attempt")
    }

    @MainActor
    func testSuccessfulCheckStartsTheCooldownAndAppliesTheRelease() async {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var fetches = 0
        let checker = UpdateChecker(currentVersion: "2.5.3", clock: { now }, defaults: isolatedDefaults()) {
            fetches += 1
            return UpdateChecker.LatestRelease(tag: "v2.5.5", url: Self.releaseURL)
        }

        await checker.check(minInterval: 1_800)
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(checker.available?.version, "2.5.5")
        XCTAssertEqual(checker.available?.url, Self.releaseURL)

        now = now.addingTimeInterval(60)
        await checker.check(minInterval: 1_800)
        XCTAssertEqual(fetches, 1, "a successful check must honour minInterval")

        now = now.addingTimeInterval(1_800)
        await checker.check(minInterval: 1_800)
        XCTAssertEqual(fetches, 2, "after the cooldown the next check must fetch again")
    }

    @MainActor
    func testRejectedReleaseUrlDoesNotStartTheCooldown() async {
        var fetches = 0
        let checker = UpdateChecker(currentVersion: "2.5.3", clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                                    defaults: isolatedDefaults()) {
            fetches += 1
            return UpdateChecker.LatestRelease(tag: "v2.5.5", url: "http://evil.example/x")
        }

        await checker.check(minInterval: 1_800)
        XCTAssertNil(checker.available)
        await checker.check(minInterval: 1_800)
        XCTAssertEqual(fetches, 2, "an unsafe URL is a failed check, not a cooldown start")
    }

    /// Malformed tags and unsupported prerelease tags are failed checks: nothing is applied, and the
    /// very next attempt fetches again and applies a valid release instead of waiting 30 minutes.
    @MainActor
    func testMalformedOrPrereleaseTagIsAFailedCheckAndDoesNotBlockTheNextOne() async {
        let badTags = ["", "latest", "v", "v2.5", "2.5.5.1", "v2..5", "2.5.x", "release-2.5.5", "v 2.5.5",
                       "v2.6.0-beta.1", "2.6.0-rc1", "v2.6.0+build.5", "v2.6.0.beta", "v-2.6.0",
                       "v1234567890.0.0", "v٢.٥.٥"]
        for bad in badTags {
            var tag = bad
            var fetches = 0
            let checker = UpdateChecker(currentVersion: "2.5.3", clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                                        defaults: isolatedDefaults()) {
                fetches += 1
                return UpdateChecker.LatestRelease(tag: tag, url: Self.releaseURL)
            }

            await checker.check(minInterval: 1_800)
            XCTAssertNil(checker.available, "\(bad.debugDescription) must not be offered")
            XCTAssertEqual(checker.settingsNotice, .current, "\(bad.debugDescription)")

            tag = "v2.5.5"
            await checker.check(minInterval: 1_800)
            XCTAssertEqual(fetches, 2, "\(bad.debugDescription) must not start the cooldown")
            XCTAssertEqual(checker.available?.version, "2.5.5", "the next valid release applies at once")
        }
    }

    func testNormalizedReleaseVersion() {
        XCTAssertEqual(UpdateChecker.normalizedReleaseVersion("v2.5.5"), "2.5.5")
        XCTAssertEqual(UpdateChecker.normalizedReleaseVersion("2.5.10"), "2.5.10")
        XCTAssertEqual(UpdateChecker.normalizedReleaseVersion(" V2.05.10\n"), "2.5.10", "trimmed, prefix and leading zeros dropped")
        XCTAssertNil(UpdateChecker.normalizedReleaseVersion("v2.6.0-beta.1"))
        XCTAssertNil(UpdateChecker.normalizedReleaseVersion("v2.5"))
        XCTAssertNil(UpdateChecker.normalizedReleaseVersion("v1234567890.0.0"), "component would overflow comparisons")
    }

    /// With no early stamp, overlapping popover opens would each hit GitHub. One fetch at a time.
    @MainActor
    func testOverlappingChecksShareOneFetch() async {
        var fetches = 0
        var release: CheckedContinuation<Void, Never>?
        let checker = UpdateChecker(currentVersion: "2.5.3", defaults: isolatedDefaults()) {
            fetches += 1
            if fetches == 1 { await withCheckedContinuation { release = $0 } }
            return nil
        }
        let first = Task { await checker.check(minInterval: 1_800) }
        while release == nil { await Task.yield() }
        await checker.check(minInterval: 1_800)
        XCTAssertEqual(fetches, 1, "a check while one is in flight returns without fetching")

        release?.resume()
        await first.value
        await checker.check(minInterval: 1_800)
        XCTAssertEqual(fetches, 2, "once the in-flight check finished (failed), the next one fetches")
    }

    /// "Skip this version" hides the banner, but a later check must still know
    /// the release exists. Settings must not treat that as "already latest".
    @MainActor
    func testSkippedReleaseStaysVisibleAndANewerOneReturnsToTheBanner() {
        let suite = "UpdateCheckerTests.skip.\(UUID().uuidString)"
        let box = UserDefaults(suiteName: suite)!
        defer { box.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(currentVersion: "2.5.3", defaults: box)

        checker.consider(latest: "2.5.4", url: "https://github.com/chattymin/PokeTokenBar/releases/tag/v2.5.4")
        XCTAssertEqual(checker.available?.version, "2.5.4")
        XCTAssertNil(checker.skipped)
        XCTAssertEqual(checker.settingsNotice, .offer("2.5.4"))

        checker.skipCurrent()
        XCTAssertNil(checker.available, "the popover banner stays hidden")
        XCTAssertEqual(checker.skipped?.version, "2.5.4")
        XCTAssertEqual(checker.settingsNotice, .skipped("2.5.4"))
        XCTAssertEqual(box.string(forKey: "skippedUpdateVersion"), "2.5.4")

        checker.consider(latest: "v2.5.4", url: "https://github.com/chattymin/PokeTokenBar/releases/tag/v2.5.4")
        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.settingsNotice, .skipped("2.5.4"), "a skipped version is not the latest installed")

        checker.consider(latest: "2.5.5", url: "https://github.com/chattymin/PokeTokenBar/releases/tag/v2.5.5")
        XCTAssertEqual(checker.available?.version, "2.5.5")
        XCTAssertNil(checker.skipped)
        XCTAssertEqual(checker.settingsNotice, .offer("2.5.5"))

        checker.consider(latest: "2.5.3", url: "https://github.com/chattymin/PokeTokenBar/releases/tag/v2.5.3")
        XCTAssertEqual(checker.settingsNotice, .current, "the installed release is the latest")
    }

    @MainActor
    func testShowAgainRestoresTheBannerAndUpdateUsesTheSkippedRelease() {
        let suite = "UpdateCheckerTests.restore.\(UUID().uuidString)"
        let box = UserDefaults(suiteName: suite)!
        defer { box.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(currentVersion: "2.5.3", defaults: box)
        let url = "https://github.com/chattymin/PokeTokenBar/releases/tag/v2.5.4"
        checker.consider(latest: "2.5.4", url: url)
        checker.skipCurrent()

        XCTAssertEqual(checker.updateTarget?.url, url, "Settings can still install a skipped release")

        checker.showSkippedAgain()
        XCTAssertEqual(checker.available?.version, "2.5.4")
        XCTAssertNil(checker.skipped)
        XCTAssertNil(box.string(forKey: "skippedUpdateVersion"))
        XCTAssertEqual(checker.settingsNotice, .offer("2.5.4"))
    }

    func testDetachedUpgradeScriptUsesPositionalParameters() {
        let script = UpdateChecker.detachedUpgradeScript
        XCTAssertTrue(script.contains("\"$1\" update"), "must execute brew via $1 positional arg")
        XCTAssertTrue(script.contains("\"$1\" upgrade"), "must execute brew upgrade via $1 positional arg")
        XCTAssertTrue(script.contains("open \"$2\""), "must open bundlePath via $2 positional arg")
    }
}

// MARK: brew cask 업그레이드 경로
//
// 이 경로는 한 번 통째로 삭제된 적이 있다(ba041b8). cask 토큰만 원본 것으로 남아 있어서, 원본을
// brew 로 설치한 Mac 에서 포크가 자신을 종료한 뒤 **원본 번들을 덮어쓰고** 정작 자신은 갱신되지
// 않았다. 아래 테스트는 그 결함이 되돌아오는 경로를 각각 하나씩 막는다 — 실행 없이 텍스트로
// 검증할 수 있게 `detachedUpgradeScript`·`caskListArguments` 가 프로퍼티로 뽑혀 있다.

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

    func testDetachedUpgradeScriptUpgradesThisForksCask() {
        let s = UpdateChecker.detachedUpgradeScript
        XCTAssertTrue(s.contains("upgrade --cask pika-token-bar"))
        XCTAssertFalse(s.contains("poke-token-bar"),
                       "원본 cask 를 업그레이드하면 /Applications/PokeTokenBar.app 을 덮어쓴다")
    }

    /// `brew update` 가 빠지면 로컬 tap 이 낡아 `upgrade` 가 no-op(exit 0) 이 되고,
    /// 앱만 종료된 채 아무것도 안 바뀐다 — 원본이 실제로 겪은 회귀다.
    func testDetachedUpgradeScriptRefreshesTapBeforeUpgrading() {
        let s = UpdateChecker.detachedUpgradeScript
        guard let update = s.range(of: "\"$1\" update"),
              let upgrade = s.range(of: "\"$1\" upgrade") else {
            return XCTFail("update 또는 upgrade 호출을 찾지 못했다")
        }
        XCTAssertTrue(update.lowerBound < upgrade.lowerBound, "update 는 upgrade 보다 먼저여야 한다")
    }

    /// 실행 중 번들 교체 레이스 회피 — 종료를 기다리는 대상이 **이 프로세스**여야 한다.
    ///
    /// 한때 이 가드는 `pgrep -x \(AppIdentity.executableName)` 을 단정했다(이름으로 기다림). upstream
    /// #175 가 그 방식을 PID 감시로 바꿨고 — 중복 인스턴스가 떠 있으면 이름 매칭이 20s 타임아웃까지
    /// 헛돈다 — 포크는 그 수정을 받았다. 이름이 스크립트 본문에서 사라졌으므로 정체성은 여기서 지킬 게
    /// 없고, 대기 대상이 PID 라는 것만 남는다(같은 취지의 upstream 가드가
    /// `testDetachedUpgradeScriptWaitsOnPidNotProcessName`).
    func testDetachedUpgradeScriptWaitsForThisAppToExit() {
        let s = UpdateChecker.detachedUpgradeScript
        XCTAssertTrue(s.contains("kill -0 \"$3\""), "종료 대기가 PID($3) 기준이 아니다")
        XCTAssertFalse(s.contains("pgrep"), "이름 매칭으로 되돌아가면 중복 인스턴스에서 20s 를 버린다")
    }

    /// 재오픈은 이 포크의 로그인 에이전트를 깨워야 한다 — 라벨이 어긋나면 앱이 안 돌아온다.
    func testDetachedUpgradeScriptReopensThisForksAgent() {
        XCTAssertTrue(UpdateChecker.detachedUpgradeScript.contains("gui/$(id -u)/\(AppIdentity.loginAgentLabel)"))
        XCTAssertFalse(UpdateChecker.detachedUpgradeScript.contains("chattymin"))
    }

    /// brew 가 멈춰도 앱이 종료된 채 영영 안 돌아오면 안 된다 — 워치독과 재오픈 폴백.
    func testDetachedUpgradeScriptCannotLeaveTheAppDown() {
        let s = UpdateChecker.detachedUpgradeScript
        XCTAssertTrue(s.contains("kill -0"), "brew hang 감시 루프가 없다")
        XCTAssertTrue(s.contains("kill \"$brew_pid\""), "hang 시 brew 를 정리하지 않는다")
        XCTAssertTrue(s.contains("open \"$2\""), "kickstart 실패 시 open 폴백이 없다")
    }

    /// 경로는 본문에 보간하지 않고 positional 인자로만 넘긴다 — 공백·따옴표가 섞이면 셸 인젝션이다.
    func testDetachedUpgradeScriptTakesPathsPositionally() {
        let s = UpdateChecker.detachedUpgradeScript
        XCTAssertTrue(s.contains("\"$1\""), "brew 경로가 positional 이 아니다")
        XCTAssertTrue(s.contains("\"$2\""), "번들 경로가 positional 이 아니다")
        XCTAssertFalse(s.contains("/Applications/"), "번들 경로가 스크립트 본문에 박혀 있다")
    }
}
