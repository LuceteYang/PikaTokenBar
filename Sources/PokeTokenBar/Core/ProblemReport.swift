import Foundation

/// 설정의 "문제점 알리기" — 이 포크의 GitHub 이슈 작성 화면을 진단 정보로 미리 채워 연다.
/// 원본은 메일(SupportMail.swift, 삭제됨)로 원작자에게 보냈지만, 그러면 팀원이 겪은 1세대 전용
/// 버그를 원작자가 받게 된다(그가 본 적도 없는 빌드에 대한 리포트) — 이 포크는 자기 저장소
/// 이슈로 받는다. 앱이 직접 이슈를 만들지는 않는다(GitHub 계정/토큰 불필요) — URL 조립까지만.
enum ProblemReport {
    private static let issuesNewPath = "https://github.com/\(AppIdentity.releasesRepo)/issues/new"

    /// title/body 를 채운 "새 이슈" URL. 인코딩된 쿼리가 URL 로 조립되지 않으면(극단적으로
    /// 길거나 손상된 문자) title/body 없이 빈 폼이라도 열리도록 base URL 로 폴백한다 — 버튼이
    /// 조용히 아무 일도 안 하는 것보다는 낫다.
    static func newIssueURL(title: String, body: String) -> URL {
        // 리터럴 https URL — 조립 실패 가능성 없음(표준 관례, 다른 static URL 들과 동일).
        let fallback = URL(string: issuesNewPath)!
        var components = URLComponents(string: issuesNewPath)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        guard let raw = components?.url?.absoluteString, let q = raw.firstIndex(of: "?") else {
            return fallback
        }
        let head = raw[...q]
        // URLComponents 는 query 의 '+' 를 percent-encode 하지 않는다(SupportMail 시절과 같은 문제) —
        // GitHub 이슈 폼도 이를 공백으로 오독할 수 있으므로 '+' 만 %2B 로 치환.
        let query = raw[raw.index(after: q)...].replacingOccurrences(of: "+", with: "%2B")
        return URL(string: String(head) + query) ?? fallback
    }
}
