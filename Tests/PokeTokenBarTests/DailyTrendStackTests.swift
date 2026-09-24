import XCTest
import SwiftUI
@testable import PokeTokenBar

// Provider-stacked daily trend bars (`DailyTrendStack` → `MonthDailyTrend`).
//
// Two contracts matter: the stacked split must add up to the same bar height the single-color
// row would draw, and a month with one provider must render exactly as before — stacking is
// only ever additive for multi-provider users.

final class DailyTrendStackTests: XCTestCase {

    private func days(_ values: [(String, Int)], cost: Double = 0) -> [DailyUsage] {
        values.map { DailyUsage(date: $0.0, inputTokens: 0, outputTokens: $0.1,
                                cacheCreationTokens: 0, cacheReadTokens: 0,
                                totalTokens: $0.1, totalCost: cost) }
    }

    private func provider(_ id: String, _ values: [(String, Int)],
                          reportsCost: Bool = true) -> DailyTrendStack.ProviderSeries {
        DailyTrendStack.ProviderSeries(id: id, name: id, days: days(values), reportsCost: reportsCost)
    }

    // MARK: 순서 — 이번 달 합계 큰 순, 0 은 제외

    func testOrderIsByMonthTotalWithUnusedProvidersDroppedAndTiesBrokenById() {
        let ordered = DailyTrendStack.ordered([
            provider("small", [("2026-08-01", 10), ("2026-08-02", 3)]),
            provider("idle", [("2026-08-01", 0), ("2026-08-02", 0)]),
            provider("big", [("2026-08-01", 1), ("2026-08-02", 900)]),
            provider("tie-b", [("2026-08-01", 15)]),
            provider("tie-a", [("2026-08-02", 15)]),
        ])
        XCTAssertEqual(ordered.map(\.id), ["big", "tie-a", "tie-b", "small"],
                       "월 합계 내림차순, 동률은 id — 0 토큰 프로바이더는 스택에 없다")
    }

    // MARK: 단색 경로 — 프로바이더 1개 이하

    /// 시리즈를 넘기는 프로바이더가 둘이어도 **이번 달에 쓴** 게 하나면 쌓지 않는다.
    func testStackingNeedsTwoProvidersThatActuallyUsedSomethingThisMonth() {
        XCTAssertFalse(DailyTrendStack.isStacked(DailyTrendStack.ordered([])))
        XCTAssertFalse(DailyTrendStack.isStacked(DailyTrendStack.ordered([
            provider("a", [("2026-08-01", 10)]),
        ])))
        XCTAssertFalse(DailyTrendStack.isStacked(DailyTrendStack.ordered([
            provider("a", [("2026-08-01", 10)]),
            provider("b", [("2026-08-01", 0)]),
        ])), "0 토큰 프로바이더는 쌓기 판정에 세지 않는다")
        XCTAssertTrue(DailyTrendStack.isStacked(DailyTrendStack.ordered([
            provider("a", [("2026-08-01", 10)]),
            provider("b", [("2026-08-02", 1)]),
        ])))
    }

    /// 프로바이더 1개 월은 **이전과 픽셀 단위로 같다** — `providers:` 를 안 넘긴 뷰와 비트맵을 비교한다.
    /// 높이만 비교하면 색(오늘 accent → 팔레트)이 바뀌어도 통과하므로 실제로 그려서 본다.
    @MainActor
    func testASingleProviderMonthRendersPixelIdenticalToTheUnstackedRow() throws {
        let values = (1...24).map { (String(format: "2026-08-%02d", $0), $0 * 1_000) }
        let series = days(values, cost: 0.3)
        let one = [DailyTrendStack.ProviderSeries(id: "only", name: "Only", days: series,
                                                  reportsCost: true)]
        let idle = DailyTrendStack.ProviderSeries(id: "idle", name: "Idle",
                                                  days: days(values.map { ($0.0, 0) }),
                                                  reportsCost: true)

        let before = try pixels(MonthDailyTrend(series: series, showsCost: true,
                                                today: "2026-08-24", l: L(.en)))
        let single = try pixels(MonthDailyTrend(series: series, providers: one,
                                                providerOrder: ["only", "idle"], showsCost: true,
                                                today: "2026-08-24", l: L(.en)))
        let withIdle = try pixels(MonthDailyTrend(series: series, providers: one + [idle],
                                                  providerOrder: ["only", "idle"], showsCost: true,
                                                  today: "2026-08-24", l: L(.en)))
        XCTAssertEqual(single, before, "프로바이더 1개인데 추이 행이 달라졌다")
        XCTAssertEqual(withIdle, before, "이번 달 0 토큰 프로바이더가 쌓기를 켰다")
    }

    // MARK: 구간 높이

    /// 구간 합 == 막대 높이. 각 구간을 독립적으로 비율 계산하면 부동소수 오차가 쌓여 단색 막대와
    /// 높이가 어긋난다 — 나누어 떨어지지 않는 값들로 여러 높이에서 확인한다.
    func testSegmentsAddUpExactlyToTheBarHeight() {
        let stack = DailyTrendStack.ordered([
            provider("a", [("d", 333_333)]),
            provider("b", [("d", 222_221)]),
            provider("c", [("d", 7)]),
        ])
        for height in [DailyTrendMetrics.baseline, 1.7, 9.3, 17.77, DailyTrendMetrics.track] {
            let segments = DailyTrendStack.segments(on: "d", stack: stack, barHeight: height)
            XCTAssertEqual(segments.map(\.providerID), ["a", "b", "c"])
            XCTAssertEqual(segments.reduce(0) { $0 + $1.height }, height, "\(height) 에서 합이 어긋났다")
            XCTAssertTrue(segments.allSatisfy { $0.height >= 0 })
        }
        let twoToOne = DailyTrendStack.segments(
            on: "d", stack: DailyTrendStack.ordered([provider("a", [("d", 200)]),
                                                     provider("b", [("d", 100)])]),
            barHeight: 24)
        XCTAssertEqual(twoToOne.map(\.height), [16, 8], "구간 높이는 그날 토큰 비율")
    }

    /// 그날 안 쓴 프로바이더는 구간이 없다(0pt 뷰를 쌓지 않는다). 순서는 **그날이 아니라 이번 달**
    /// 기준이라, 그날 작게 쓴 월간 1위도 맨 아래에 남는다 — 날마다 색 순서가 뒤집히지 않게.
    func testZeroTokenProvidersAreOmittedAndTheMonthLeaderStaysAtTheBottom() {
        let stack = DailyTrendStack.ordered([
            provider("leader", [("2026-08-01", 1_000), ("2026-08-02", 10)]),
            provider("second", [("2026-08-01", 0), ("2026-08-02", 90)]),
        ])
        XCTAssertEqual(DailyTrendStack.segments(on: "2026-08-01", stack: stack, barHeight: 20)
                        .map(\.providerID), ["leader"])
        XCTAssertEqual(DailyTrendStack.segments(on: "2026-08-02", stack: stack, barHeight: 20)
                        .map(\.providerID), ["leader", "second"])
        XCTAssertEqual(DailyTrendStack.segments(on: "2026-08-03", stack: stack, barHeight: 20), [],
                       "아무도 안 쓴 날(또는 시리즈에 없는 날)은 구간이 없다")
    }

    // MARK: 색 — 등록 순서 고정

    /// 사용량 순위가 바뀌어도 색은 그대로다. 순위로 색을 매기면 월중에 한 프로바이더가 다른 걸
    /// 추월하는 순간 두 색이 맞바뀌어, 같은 막대가 다른 서비스로 읽힌다.
    func testColorsFollowRegistrationOrderNotUsageRank() {
        let registry = ["first", "second", "third"]
        let claudeLeads = DailyTrendStack.ordered([
            provider("first", [("d", 900)]), provider("second", [("d", 100)]),
        ])
        let codexLeads = DailyTrendStack.ordered([
            provider("first", [("d", 100)]), provider("second", [("d", 900)]),
        ])
        XCTAssertNotEqual(claudeLeads.map(\.id), codexLeads.map(\.id), "전제: 순위가 실제로 뒤집혔다")

        let a = DailyTrendStack.colorIndices(for: claudeLeads.map(\.id), registry: registry, paletteCount: 8)
        let b = DailyTrendStack.colorIndices(for: codexLeads.map(\.id), registry: registry, paletteCount: 8)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, ["first": 0, "second": 1])

        // 중간 프로바이더가 이번 달 안 써도 나머지 색은 밀리지 않는다.
        XCTAssertEqual(DailyTrendStack.colorIndices(for: ["third", "first"], registry: registry,
                                                    paletteCount: 8),
                       ["first": 0, "third": 2])
    }

    /// 팔레트보다 프로바이더가 많아 같은 칸을 원해도, 화면에 함께 나오는 프로바이더끼리는 겹치지 않는다.
    func testProvidersThatWrapOntoTheSameSlotStillGetDistinctColors() {
        let registry = (0..<13).map { "p\($0)" }
        let slots = DailyTrendStack.colorIndices(for: ["p8", "p0"], registry: registry, paletteCount: 8)
        XCTAssertEqual(slots["p0"], 0)
        XCTAssertEqual(slots["p8"], 1, "p8 은 0 칸을 원하지만 p0 이 먼저 차지했다")

        let all = DailyTrendStack.colorIndices(for: Array(registry.prefix(8)).reversed(),
                                               registry: registry, paletteCount: 8)
        XCTAssertEqual(Set(all.values).count, 8, "팔레트 크기까지는 전부 다른 색")

        // 팔레트보다 많이 쓰면(등록 13개) 겹침은 피할 수 없다 — 그래도 전부 칸을 받고 멈추지 않는다.
        let crowded = DailyTrendStack.colorIndices(for: registry, registry: registry, paletteCount: 8)
        XCTAssertEqual(crowded.count, 13)
        XCTAssertEqual(Set(crowded.values), Set(0..<8))
    }

    // MARK: 분해 줄

    /// 쌓기가 켜지면 분해 줄 한 줄이 더해지고, 그 줄은 프로바이더 수·언어와 무관하게 **한 줄**이다.
    /// 억 단위·네 자리 비용이면 이름을 넣은 줄은 2개부터, 이름을 뺀 줄도 4개부터 폭을 넘는다 —
    /// 이름 → 비용 순으로 빼는 폴백이 있어야 한다. 5개까지 잰다.
    @MainActor
    func testBreakdownAddsExactlyOneLineAtAnyProviderCountAndLanguage() {
        let values = (1...31).map { (String(format: "2026-08-%02d", $0), 888_888_888) }
        func series(_ count: Int) -> [DailyTrendStack.ProviderSeries] {
            (0..<count).map { index in
                DailyTrendStack.ProviderSeries(id: "p\(index)", name: "Provider Name \(index)",
                                               days: days(values, cost: 8_888.88), reportsCost: true)
            }
        }
        let total = days(values.map { ($0.0, $0.1 * 4) }, cost: 8_888.88 * 4)
        func size(_ providers: [DailyTrendStack.ProviderSeries], _ language: AppLanguage) -> CGSize {
            let view = MonthDailyTrend(series: total, providers: providers,
                                       providerOrder: providers.map(\.id), showsCost: true,
                                       today: "2026-08-24", l: L(language))
                .environment(\.locale, language.displayLocale)
            return NSHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: PopoverMetrics.contentWidth, height: 600))
        }
        // 조각마다 `fixedSize` 라 넘쳐도 줄바꿈 대신 **옆으로** 삐져나간다 — 높이만 보면 못 잡으므로 폭도 잰다.
        func height(_ providers: [DailyTrendStack.ProviderSeries], _ language: AppLanguage) -> CGFloat {
            let measured = size(providers, language)
            XCTAssertLessThanOrEqual(measured.width, PopoverMetrics.contentWidth + 0.5,
                                     "\(language) · 프로바이더 \(providers.count)개에서 분해 줄이 팝오버 폭을 넘었다")
            return measured.height
        }

        let unstacked = height(series(1), .en)
        let stacked = height(series(2), .en)
        XCTAssertGreaterThan(stacked, unstacked, "쌓기가 켜지면 분해 줄이 보여야 한다")
        for language in AppLanguage.allCases {
            for count in 2...5 {
                XCTAssertEqual(height(series(count), language), stacked, accuracy: 0.5,
                               "\(language) · 프로바이더 \(count)개에서 분해 줄이 줄바꿈됐다")
            }
        }
    }

    // MARK: 렌더 헬퍼

    @MainActor
    private func pixels(_ view: MonthDailyTrend) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: PopoverMetrics.contentWidth))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "렌더 실패")
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        XCTAssertGreaterThan(image.height, 0)
        return data
    }
}
