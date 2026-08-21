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

    /// 상태 파일(companion 상태·세션 키 등)을 둘 디렉토리. 기본은 `supportDirectory`,
    /// `PTB_STATE_DIR` 이 있으면 그 디렉토리 — 개발/QA 격리용(실제 세이브·자격증명을 건드리지 않고
    /// 데모 상태로 실행). 프로덕션은 이 변수가 없어 무영향.
    ///
    /// **환경변수를 읽는 유일한 지점이다.** 상태 경로마다 각자 `ProcessInfo` 를 뒤지면 격리가 반쪽만
    /// 걸려 QA 실행이 실제 데이터를 섞어 쓴다(`UsageEnvironmentTests` 의 직독 금지 가드가 이걸 잡는다).
    /// 공백만 있는 값은 무시한다 — `URL(fileURLWithPath:)` 가 CWD 상대경로로 해석하는 것 방지.
    static var stateDirectory: URL {
        let override = (ProcessInfo.processInfo.environment["PTB_STATE_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !override.isEmpty else { return supportDirectory }
        let dir = URL(fileURLWithPath: override, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 앱 전용 저장 디렉토리. 없으면 만든다.
    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportDirectoryName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
