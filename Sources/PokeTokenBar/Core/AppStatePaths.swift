import Foundation

/// 상태 파일을 둘 Application Support 디렉토리.
///
/// 포크에서는 **경로도 환경변수 해석도 여기서 하지 않는다** — `AppIdentity.stateDirectory` 가
/// 단일 진실원이다(디렉토리명이 `PikaTokenBar`, `PTB_STATE_DIR` 을 읽는 유일한 지점).
/// upstream 은 이 파일에서 직접 `ProcessInfo` 를 읽고 `PokeTokenBar` 를 하드코딩하는데,
/// 그대로 두면 두 앱이 같은 상태 파일을 쓰고 `UsageEnvironmentTests` 의 환경변수 직독 가드도
/// 구멍이 난다. upstream 호출부(`CompanionStore`·`CursorUsageAPI`)를 건드리지 않으려고
/// 파일은 남기되 위임만 한다.
enum AppStatePaths {
    static func directory() -> URL { AppIdentity.stateDirectory }
}
