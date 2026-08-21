#!/usr/bin/env swift
//
// probe-session-key.swift — claude.ai 세션 키 경로 실기 검증 (opt-in, CI 제외).
//
// 왜 스크립트인가: 이 엔드포인트는 단위 테스트로 검증할 수 없다. Cloudflare 가 curl 을 챌린지로
// 403 시키고(`cf-mitigated: challenge`) URLSession 만 통과하므로, 앱과 같은 클라이언트로
// 사람이 직접 한 번 눌러봐야 한다. 세션 키를 인자로 받는 대신 파일에서 읽는다 — 셸 히스토리와
// 프로세스 목록(`ps`)에 자격증명을 남기지 않기 위함.
//
//   1) 브라우저 DevTools → Application → Cookies → claude.ai → sessionKey 값 복사
//   2) umask 077; pbpaste > /tmp/sk
//   3) swift scripts/probe-session-key.swift /tmp/sk
//   4) rm /tmp/sk
//
// 출력에 키를 찍지 않는다(길이·prefix 만). 조직 uuid 는 앞 8자만.

import Foundation

guard CommandLine.arguments.count == 2 else {
    print("usage: swift scripts/probe-session-key.swift <세션 키가 담긴 파일>")
    exit(2)
}

let path = CommandLine.arguments[1]
guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("✗ 파일을 읽을 수 없습니다: \(path)")
    exit(2)
}
let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
guard key.hasPrefix("sk-ant-"), key.count >= 40 else {
    print("✗ 세션 키 형식이 아닙니다 (len=\(key.count), prefix=\(key.prefix(8)))")
    exit(2)
}
print("키: len=\(key.count) prefix=\(key.prefix(13))…")

let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
                "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

func get(_ urlString: String) async -> (status: Int, data: Data) {
    var request = URLRequest(url: URL(string: urlString)!, timeoutInterval: 15)
    request.httpShouldHandleCookies = false
    request.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
    request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    } catch {
        print("✗ 요청 실패: \(error)")
        return (-2, Data())
    }
}

let orgs = await get("https://claude.ai/api/organizations")
print("GET /api/organizations → \(orgs.status)")
guard orgs.status == 200,
      let rows = try? JSONSerialization.jsonObject(with: orgs.data) as? [[String: Any]] else {
    print("✗ 조직 목록 실패. 챌린지(403 + text/html)면 UA·Origin 헤더나 Cloudflare 정책을 확인한다.")
    exit(1)
}

var picked: (id: String, util: Double)?
for row in rows {
    guard let id = row["uuid"] as? String else { continue }
    let name = row["name"] as? String ?? "-"
    let capabilities = row["capabilities"] as? [String] ?? []
    guard capabilities.contains("chat") else {
        print("  · \(id.prefix(8))… \(name) — chat 없음, 건너뜀 (caps=\(capabilities))")
        continue
    }
    let usage = await get("https://claude.ai/api/organizations/\(id)/usage")
    guard usage.status == 200,
          let json = try? JSONSerialization.jsonObject(with: usage.data) as? [String: Any] else {
        print("  · \(id.prefix(8))… \(name) — usage \(usage.status) (접근 불가)")
        continue
    }
    let fiveHour = (json["five_hour"] as? [String: Any])?["utilization"] as? Double
    let sevenDay = (json["seven_day"] as? [String: Any])?["utilization"] as? Double
    let hasLimits = (json["limits"] as? [[String: Any]])?.count ?? 0
    print("  ✓ \(id.prefix(8))… \(name) — five_hour=\(fiveHour?.description ?? "nil") " +
          "seven_day=\(sevenDay?.description ?? "nil") limits[\(hasLimits)]")
    if picked == nil || (fiveHour ?? 0) > (picked?.util ?? 0) {
        picked = (id, fiveHour ?? 0)
    }
}

guard let picked else {
    print("✗ 한도를 볼 수 있는 조직이 없습니다.")
    exit(1)
}
print("→ 앱이 고를 조직: \(picked.id.prefix(8))… (five_hour=\(picked.util))")
