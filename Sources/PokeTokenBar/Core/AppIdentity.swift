import Foundation

/// 이 포크(PikaTokenBar)의 앱 정체성 — 원본 PokeTokenBar 와 데이터·프로세스·업데이트 채널을
/// 가르는 단일 진실원.
///
/// 왜 한 곳에 모으나: 정체성 문자열이 소스 10곳에 흩어져 있으면 (a) 한 곳만 빠뜨려도 두 앱이
/// 같은 파일을 쓰게 되고 (b) upstream 을 머지할 때마다 충돌 지점이 10개가 된다. 여기 하나만
/// 지키면 나머지는 파생된다.
///
/// **UserDefaults 는 번들 ID 로 자동 분리되므로 코드에서 손댈 것이 없다.**
enum AppIdentity {
    static let bundleID = "sh.otis.pikatokenbar"

    /// 번들 실행파일명 = 프로세스명(`pgrep -x`) = `.app` 파일명. SPM 모듈명(`PokeTokenBar`)과는 별개다.
    static let executableName = "PikaTokenBar"

    /// `~/Library/Application Support/<이것>`
    static let supportDirectoryName = "PikaTokenBar"

    /// `~/Library/Logs/<이것>`
    static let logFileName = "PikaTokenBar.log"

    static let loginAgentLabel = "sh.otis.pikatokenbar.login"
    static var loginAgentPlistName: String { "\(loginAgentLabel).plist" }

    /// 업데이트 확인 대상. **원본이 아니라 내 포크다** — 원본 릴리스가 이 앱 사용자를 원본
    /// 다운로드로 유도하면 1세대 패치가 없는 빌드로 갈아타게 된다.
    static let releasesRepo = "LuceteYang/PikaTokenBar"

    /// 이 포크의 Homebrew cask 토큰. tap 은 `LuceteYang/homebrew-tap`,
    /// 설치는 `brew install --cask LuceteYang/tap/pika-token-bar`, 갱신은 `brew upgrade --cask <이것>`.
    ///
    /// **원본 토큰(`poke-token-bar`)을 여기 넣으면 안 된다.** 이 값이 소스에 인라인으로 박혀 있어
    /// 포크 때 같이 안 바뀐 것이 ba041b8 에서 brew 분기를 통째로 들어낸 원인이다 — 원본이 brew 로
    /// 설치된 Mac 에서 `brew list --cask poke-token-bar` 가 **원본의** cask 를 보고 성공해,
    /// 포크가 자신을 종료한 뒤 원본 번들(`/Applications/PokeTokenBar.app`)을 덮어쓰고
    /// 정작 자신은 영영 갱신되지 않았다. 정체성 문자열은 예외 없이 이 파일에서만 나온다.
    static let brewCaskToken = "pika-token-bar"

    /// 앱 전용 저장 디렉토리. 없으면 만든다.
    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportDirectoryName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
