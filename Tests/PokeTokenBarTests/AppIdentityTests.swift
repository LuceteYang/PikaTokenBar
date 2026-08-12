import XCTest
@testable import PokeTokenBar

// MARK: 앱 정체성 분리
//
// 이 포크는 원본 PokeTokenBar 와 **같은 Mac 에 공존**한다. 저장 경로·로그·로그인 에이전트 라벨이
// 한 곳이라도 원본과 겹치면 두 앱이 서로의 데이터를 덮어쓴다. 정체성은 AppIdentity 한 곳에서만
// 나와야 하고, 어떤 경로도 "PokeTokenBar" 를 직접 문자열로 들고 있으면 안 된다.

// `CompanionStore`·`LoginItem`·`SpriteLoader` 는 모두 `@MainActor` 다 — 클래스 전체를 격리해야
// Swift 6 에서 컴파일된다.
@MainActor
final class AppIdentityTests: XCTestCase {

    func testIdentityValues() {
        XCTAssertEqual(AppIdentity.bundleID, "sh.otis.pikatokenbar")
        XCTAssertEqual(AppIdentity.executableName, "PikaTokenBar")
        XCTAssertEqual(AppIdentity.supportDirectoryName, "PikaTokenBar")
        XCTAssertEqual(AppIdentity.logFileName, "PikaTokenBar.log")
        XCTAssertEqual(AppIdentity.loginAgentLabel, "sh.otis.pikatokenbar.login")
        XCTAssertEqual(AppIdentity.loginAgentPlistName, "sh.otis.pikatokenbar.login.plist")
        XCTAssertEqual(AppIdentity.releasesRepo, "LuceteYang/PokeTokenBar")
    }

    func testLoginItemUsesForkIdentity() {
        XCTAssertEqual(LoginItem.label, AppIdentity.loginAgentLabel)
        XCTAssertEqual(LoginItem.plistName, AppIdentity.loginAgentPlistName)
    }

    func testSupportDirectoryIsNotSharedWithUpstream() {
        let path = AppIdentity.supportDirectory.path
        XCTAssertTrue(path.hasSuffix("/PikaTokenBar"))
        XCTAssertFalse(path.contains("/PokeTokenBar"), "원본과 같은 폴더를 쓰고 있다")
    }

    /// 상태 파일이 실제로 포크 폴더 아래에 떨어지는지 — 상수만 맞고 사용처가 안 바뀐 경우를 잡는다.
    /// `PTB_STATE_DIR` 이 설정된 셸에서 돌면 `defaultURL()` 이 그 오버라이드를 타 실패/무의미 통과할
    /// 수 있으므로, 테스트 동안만 비워 실제 환경과 무관하게 만든다.
    func testCompanionStatePathLivesUnderForkDirectory() {
        let key = "PTB_STATE_DIR"
        let saved = ProcessInfo.processInfo.environment[key]
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        unsetenv(key)

        let url = CompanionStore.defaultURL()
        XCTAssertTrue(url.path.contains("/PikaTokenBar/"), "companion 상태가 원본 폴더에 저장된다: \(url.path)")
        XCTAssertEqual(url.lastPathComponent, "companion-state.json")
    }

    func testLogFileLivesUnderForkName() {
        XCTAssertEqual(AppLog.logFileURL.lastPathComponent, "PikaTokenBar.log")
    }

    func testSpriteCacheLivesUnderForkDirectory() {
        XCTAssertTrue(SpriteLoader.cacheDir.path.contains("/PikaTokenBar/"),
                      "스프라이트 캐시가 원본 폴더를 가리킨다: \(SpriteLoader.cacheDir.path)")
    }

    /// `SpriteStore`(actor, 쓰기)와 `SpriteLoader`(@MainActor, 읽기)는 서로 다른 격리 도메인이라
    /// 경로 상수를 그대로 공유할 수 없다 — 리뷰에서 지적된 대로, 둘 중 한쪽만 고치거나 되돌리면
    /// 쓰기는 원본 폴더로 읽기는 포크 폴더로 갈라져도 컴파일도 다른 테스트도 안 잡고 "스프라이트가
    /// 오프라인마다 계속 재다운로드된다"는 증상으로만 드러난다. 이 테스트가 그 갈림을 직접 잡는다.
    func testSpriteStoreWritesToSameDirectorySpriteLoaderReads() async {
        let writeDir = await SpriteStore.shared.dir
        XCTAssertEqual(writeDir, SpriteLoader.cacheDir)
    }
}
