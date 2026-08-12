import AppKit
import Observation

/// GitHub 릴리스 최신 버전을 확인해 새 버전이 있으면 팝오버에 알린다.
/// 이 포크는 Homebrew cask 를 배포하지 않는다(GitHub Release + `install.sh`) — 실제 설치는
/// 항상 릴리스 페이지를 연다. brew 업그레이드 분기는 절대 만들지 않는다: 이 머신에 원본
/// PokeTokenBar 가 brew cask 로 설치돼 있으면 `brew list --cask poke-token-bar` 가 그
/// **원본의** cask 를 보고 성공해 버려서, 포크가 원본 앱 번들을 덮어쓰고 자신은 갱신되지 않는다.
@MainActor
@Observable
final class UpdateChecker {
    struct Available: Equatable { let version: String; let url: String }

    private(set) var available: Available?
    private(set) var isUpdating = false

    let currentVersion: String
    private let repo = AppIdentity.releasesRepo
    private let clock: () -> Date
    private var lastChecked: Date?

    init(currentVersion: String? = nil, clock: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        self.clock = clock
    }

    /// 최신 릴리스 조회 → 새 버전이고 사용자가 그 버전을 'skip' 하지 않았으면 available 설정.
    /// minInterval 보다 자주 호출되면 무시(레이트리밋 보호).
    func check(minInterval: TimeInterval = 1800) async {
        if let last = lastChecked, clock().timeIntervalSince(last) < minInterval { return }
        lastChecked = clock()
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let html = json["html_url"] as? String,
              // 응답 필드가 NSWorkspace.open 으로 가므로 https + github.com 만 허용(스킴 하이재킹 방지)
              let htmlURL = URL(string: html), htmlURL.scheme == "https", htmlURL.host == "github.com"
        else { return }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let skipped = UserDefaults.standard.string(forKey: "skippedUpdateVersion")
        if Self.isNewer(latest, than: currentVersion), latest != skipped {
            available = Available(version: latest, url: html)
        } else {
            available = nil
        }
    }

    /// 이 버전은 다시 알리지 않음.
    func skipCurrent() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: "skippedUpdateVersion") }
        available = nil
    }

    /// 업데이트 적용: 이 포크는 배포하는 cask 가 없으므로 항상 릴리스 페이지를 연다
    /// (`install.sh` 안내가 거기 있다). brew 자동 업그레이드는 두지 않는다 — 위 헤더 주석 참조.
    func applyUpdate() {
        guard let update = available, !isUpdating else { return }
        AppLog.write("update: 릴리스 페이지 열기")
        if let u = URL(string: update.url) { NSWorkspace.shared.open(u) }
    }

    // MARK: 버전 비교

    /// a 가 b 보다 높은 semver 인가. ("2.0.10" > "2.0.9" 등 숫자 비교)
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
