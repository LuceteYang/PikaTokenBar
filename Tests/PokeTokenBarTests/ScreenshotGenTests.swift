import XCTest
import SwiftUI
@testable import PokeTokenBar

/// 릴리스 에셋 생성기 — **기본적으로 건너뛴다.** 환경변수로 출력 폴더를 주면 그때만 그린다:
///
///     PTB_SCREENSHOT_DIR=assets swift test --filter ScreenshotGenTests
///
/// 왜 테스트 안에 있나: 이 스크린샷은 `gen-settings-screenshots.py`(설정 화면 = HTML 목업)와 달리
/// **프로덕션 SwiftUI 뷰를 그대로 렌더**한다. HTML 로 다시 그리면 목업과 실제 UI 가 조용히 갈라져
/// "스크린샷에는 있는데 앱에는 없는" 상태가 만들어진다 — 실제 뷰를 쓰려면 모듈에 접근할 수 있는
/// 이 자리가 유일하게 새 빌드 타깃이 필요 없는 곳이다.
///
/// 배경·크기는 기존 다크 스크린샷과 맞춰 뒀다(720px 폭 = 팝오버 360pt × 2, 배경 rgb(41,41,42)).
///
/// 함정: `ScrollView` 를 품은 뷰(`ProviderTabBar`)는 `ImageRenderer` 에서 빈 칸으로 나온다 —
/// 스크린샷에 넣지 말 것. 헤더처럼 스크롤 없는 부분만 렌더된다.
final class ScreenshotGenTests: XCTestCase {

    /// 데모용 한 달치 일별 사용량 — 실제 로그처럼 쉬는 날(0)과 몰아친 날이 섞여야 기능이 읽힌다.
    private static let demoDailyTokens = [
        0, 1_240_000, 3_100_000, 480_000, 0, 0, 2_050_000,
        5_600_000, 4_100_000, 900_000, 0, 1_700_000, 6_900_000, 3_300_000,
        2_200_000, 0, 140_000, 4_800_000, 5_100_000, 2_600_000, 3_900_000,
    ]

    @MainActor
    func testGenerateDailyTrendScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["PTB_SCREENSHOT_DIR"] else {
            throw XCTSkip("PTB_SCREENSHOT_DIR 미지정 — 에셋 생성은 릴리스 때만 실행한다")
        }
        for (language, suffix) in [(AppLanguage.en, ""), (.ko, "-ko"), (.ja, "-ja")] {
            let data = try render(language: language)
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("screenshot-daily-trend\(suffix).png")
            try data.write(to: url)
            print("wrote \(url.path) (\(data.count) bytes)")
        }
    }

    @MainActor
    private func render(language: AppLanguage) throws -> Data {
        let l = L(language)
        let today = "2026-07-21"
        let series = Self.demoDailyTokens.enumerated().map { index, value in
            DailyUsage(date: String(format: "2026-07-%02d", index + 1),
                       inputTokens: value / 4, outputTokens: value / 4,
                       cacheCreationTokens: value / 4, cacheReadTokens: value / 4,
                       totalTokens: value, totalCost: Double(value) / 1_000_000 * 3.2)
        }
        let monthTotal = series.reduce(0) { $0 + $1.totalTokens }
        let monthCost = series.reduce(0.0) { $0 + $1.totalCost }
        let weekTotal = series.suffix(7).reduce(0) { $0 + $1.totalTokens }
        let weekCost = series.suffix(7).reduce(0.0) { $0 + $1.totalCost }
        let todayUsage = try XCTUnwrap(series.last)

        let content = VStack(alignment: .leading, spacing: 6) {
            Text(l.todayTokens).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(TokenFormatter.compact(todayUsage.totalTokens))
                    .font(.system(size: 28, weight: .bold)).monospacedDigit()
                Text(TokenFormatter.grouped(todayUsage.totalTokens))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(TokenFormatter.cost(todayUsage.totalCost))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                periodLabel(l.thisWeek, weekTotal, weekCost)
                periodLabel(l.thisMonth, monthTotal, monthCost)
                Spacer()
            }
            .padding(.top, 2)

            MonthDailyTrend(series: series, showsCost: true, today: today, l: l)

        }
        .padding(.horizontal, PopoverMetrics.padding)
        .padding(.vertical, 16)
        .frame(width: PopoverMetrics.width, alignment: .leading)
        .background(Color(red: 41 / 255, green: 41 / 255, blue: 42 / 255))
        .environment(\.colorScheme, .dark)
        .environment(\.locale, language.displayLocale)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func periodLabel(_ name: String, _ tokens: Int, _ cost: Double) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.caption).foregroundStyle(.tertiary)
            Text(TokenFormatter.compact(tokens)).font(.caption.weight(.semibold)).monospacedDigit()
            Text(TokenFormatter.cost(cost)).font(.caption).foregroundStyle(.secondary)
        }
    }
}
