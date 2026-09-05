import XCTest
import SwiftUI
@testable import PokeTokenBar

// 이번 달 일별 추이(`monthDailySeries` → `ProviderEnrichment.monthDaily` → `UsageStore.monthDailyTotals`
// → `MonthDailyTrend`) 의 계약 가드.
//
// 이 기능의 실제 함정은 하나다: enrichment 스캔은 **파일 mtime** 필터라, 지난달에 시작해 이번 달까지
// 이어진 세션은 이번 달 mtime 으로 읽히며 **지난달 엔트리까지 함께** 메모리에 올라온다. 엔트리를
// localDay 로 그룹핑해 그대로 내보내면 지난달이 부분적으로만 채워진 채(다른 지난달 파일은 스캔조차
// 안 됐다) 시리즈에 섞인다. 그래서 순수 함수만 보지 않고 **실제 mtime 스캔을 통과한 엔트리**로
// 트리거 조건을 재현한다 — 픽스처 배열을 직접 만들면 "그 상황이 일어나는가"에 답하지 못한다.

// MARK: 한도 스텁 (refresh 가 Keychain·네트워크를 건드리지 않게)

private enum TrendStubError: Error { case unavailable }

private struct NoClaudeLimits: ClaudeLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus { throw TrendStubError.unavailable }
}
private struct NoCodexLimits: CodexLimitsProviding {
    func fetch() async throws -> CodexRateLimitStatus? { nil }
}
private struct NoAntigravityLimits: AntigravityLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus {
        throw TrendStubError.unavailable
    }
}
private struct NoStatus: ProviderStatusProviding {
    func fetch() async -> [String: ProviderStatus] { [:] }
}

/// enrichment 를 테스트가 직접 지정하는 프로바이더 — 시리즈를 못 주는 프로바이더(nil)를 섞기 위함.
private final class TrendProvider: UsageProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let reportsCost: Bool
    nonisolated(unsafe) var daily: DailyUsage?
    nonisolated(unsafe) var enrichment: ProviderEnrichment

    init(id: String, daily: DailyUsage?, enrichment: ProviderEnrichment, reportsCost: Bool = true) {
        self.id = id
        self.displayName = id
        self.reportsCost = reportsCost
        self.daily = daily
        self.enrichment = enrichment
    }
    func fetchDaily() async throws -> DailyUsage? { daily }
    func fetchEnrichment() async -> ProviderEnrichment { enrichment }
}

final class MonthDailyTrendTests: XCTestCase {

    // MARK: 픽스처

    private var root: URL!
    private var cacheFile: URL!
    private let calendar = Calendar.current
    private let dayFormatter = LocalUsageReader.localDayFormatter()

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptb-trend-\(UUID().uuidString)")
        root = base.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cacheFile = base.appendingPathComponent("usage-cache.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func claudeLine(id: String, output: Int, at date: Date) -> String {
        let ts = ISO8601DateFormatter().string(from: date)
        return """
        {"type":"assistant","requestId":"r-\(id)","timestamp":"\(ts)","message":{"id":"m-\(id)","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    private func writeSession(_ name: String, lines: [String], mtime: Date) throws {
        let url = root.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func entry(_ id: String, at date: Date, output: Int) -> LocalUsageReader.Entry {
        LocalUsageReader.Entry(id: id, date: date, localDay: dayFormatter.string(from: date),
                              model: "claude-opus-4-8", input: 0, output: output,
                              cacheWrite: 0, cacheRead: 0)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: 월경계 — 이 기능의 유일한 실제 함정

    /// 트리거 재현(통합): 이번 달 mtime 을 가진 한 파일이 지난달 엔트리와 이번 달 엔트리를 함께 품는다.
    /// ① 실제 mtime 스캔이 **지난달 엔트리까지 메모리에 올린다**는 것을 먼저 확인한다 — 안 올라오면
    ///    아래 컷 검증은 애초에 통과할 조건이었던 셈이고(false confidence) 이 테스트가 먼저 실패한다.
    /// ② 그 엔트리로 만든 시리즈에 지난달 날짜가 **한 칸도** 없어야 한다.
    func testCrossMonthSessionDoesNotLeakLastMonthIntoTheSeries() async throws {
        let now = day(2026, 7, 10)
        let lastMonthTurn = day(2026, 6, 29, hour: 23)
        let thisMonthTurn = day(2026, 7, 8, hour: 1)

        // 한 세션 파일이 월경계를 넘는다. mtime 은 마지막 턴(이번 달) — 그래서 스캔에 걸린다.
        try writeSession("straddle.jsonl", lines: [
            claudeLine(id: "june", output: 700, at: lastMonthTurn),
            claudeLine(id: "july", output: 300, at: thisMonthTurn),
        ], mtime: thisMonthTurn)

        let cache = LocalUsageCache(claudeRoot: root, codexRoot: nil, fileURL: cacheFile,
                                    now: { now })
        let entries = await cache.claudeEntries(
            modifiedSince: LocalUsageReader.enrichmentScanStart(now: now))

        // ① 트리거 조건이 실재하는가 — 지난달 엔트리가 실제로 로드된다.
        let loadedDays = Set(entries.map(\.localDay))
        XCTAssertTrue(loadedDays.contains(dayFormatter.string(from: lastMonthTurn)),
                      "전제: 월경계 세션은 지난달 엔트리까지 메모리에 올린다 — 안 올라오면 컷 검증이 무의미하다")
        XCTAssertTrue(loadedDays.contains(dayFormatter.string(from: thisMonthTurn)))

        // ② 컷: 시리즈에 지난달은 없다.
        let series = LocalUsageReader.monthDailySeries(entries: entries, now: now)
        XCTAssertTrue(series.allSatisfy { $0.date.hasPrefix("2026-07") },
                      "지난달 날짜가 시리즈에 섞였다: \(series.map(\.date).filter { !$0.hasPrefix("2026-07") })")
        XCTAssertEqual(series.first?.date, "2026-07-01")
        XCTAssertEqual(series.last?.date, "2026-07-10")

        // 이번 달 턴은 제 날짜에 살아 있다(컷이 과하게 잘라내지 않았다).
        let july8 = try XCTUnwrap(series.first { $0.date == "2026-07-08" })
        XCTAssertEqual(july8.outputTokens, 300)

        // 그리고 같은 엔트리로 계산한 월 합계와 시리즈 합이 일치한다 — 컷이 월 스칼라와 같은 창을 쓴다.
        let month = LocalUsageReader.period(
            entries: entries, periodKey: LocalUsageReader.monthKey(now),
            fromDay: dayFormatter.string(from: LocalUsageReader.startOfMonth(now)),
            toDay: dayFormatter.string(from: now))
        XCTAssertEqual(series.reduce(0) { $0 + $1.totalTokens }, month.totalTokens)
    }

    /// 같은 컷을 프로덕션 조립 경로(`ProviderEnrichment.local`)에서도 확인한다 —
    /// 헬퍼만 맞고 조립이 다른 창을 쓰면 화면은 여전히 틀린다.
    func testEnrichmentSeriesAndMonthTotalStayInAgreement() {
        let now = day(2026, 7, 10)
        let entries = [
            entry("june", at: day(2026, 6, 29), output: 700),
            entry("july-3", at: day(2026, 7, 3), output: 100),
            entry("july-10", at: day(2026, 7, 10), output: 40),
        ]
        let enrichment = ProviderEnrichment.local(entries: entries, now: now)
        let series = try! XCTUnwrap(enrichment.monthDaily)

        XCTAssertTrue(series.allSatisfy { $0.date.hasPrefix("2026-07") })
        XCTAssertEqual(series.reduce(0) { $0 + $1.totalTokens },
                       enrichment.monthTotal?.totalTokens,
                       "일별 합 != 월 스칼라 — 두 창이 갈라졌다")
        XCTAssertEqual(series.reduce(0.0) { $0 + $1.totalCost },
                       enrichment.monthTotal?.totalCost ?? -1, accuracy: 1e-9)
    }

    // MARK: 빈 날짜 — 0 으로 채운다(누락 아님)

    /// 사용 없는 날은 0 으로 존재한다. 막대 위치가 곧 날짜라, 빈 날을 빼면 이후 막대가 전부 밀린다.
    func testUnusedDaysAreExplicitZerosSoTheAxisCannotShift() {
        let now = day(2026, 7, 10)
        let series = LocalUsageReader.monthDailySeries(
            entries: [entry("only", at: day(2026, 7, 3), output: 500)], now: now)

        XCTAssertEqual(series.map(\.date),
                       (1...10).map { String(format: "2026-07-%02d", $0) },
                       "월초→오늘의 모든 날이 순서대로 있어야 한다")
        XCTAssertEqual(series.filter { $0.totalTokens > 0 }.map(\.date), ["2026-07-03"])
        XCTAssertTrue(series.filter { $0.date != "2026-07-03" }.allSatisfy { $0.totalTokens == 0 })
    }

    /// 축은 오늘에서 끝난다 — 아직 오지 않은 날을 0 막대로 그리면 "오늘 안 썼다"로 오독된다.
    func testSeriesStopsAtTodayAndNeverRunsToTheEndOfTheMonth() {
        let now = day(2026, 7, 10)
        let series = LocalUsageReader.monthDailySeries(entries: [], now: now)
        XCTAssertEqual(series.count, 10)
        XCTAssertEqual(series.last?.date, dayFormatter.string(from: now))
    }

    /// 축 길이는 그 달의 "오늘이 며칠인가"와 항상 같아야 한다. 하루 전진을 고정 86400 초로 하면
    /// DST 전환이 있는 달에서 현지 자정이 23/25시간이 되어 축이 어긋나고(날짜 중복 또는 하루 누락),
    /// 그 뒤 막대가 전부 밀린다.
    ///
    /// **시간대를 주입해서 돈다.** 개발 기기가 Asia/Seoul(DST 없음)이면 고정 86400 결함이 그대로
    /// 통과한다 — 실측으로 확인했다(주입 전 이 테스트는 결함을 못 잡았고, `TZ=America/Los_Angeles`
    /// 로 돌렸을 때만 빨개졌다). 시간대가 계약의 일부이므로 기여자의 로케일에 맡기지 않는다.
    /// Lord Howe 는 30분 DST 라 시/분 단위 가정까지 같이 밟는다.
    ///
    /// 12개월 + 윤년 말일을 함께 돌려 달 길이(28/29/30/31) 처리도 같이 고정한다.
    func testAxisLengthMatchesTheDayOfMonthInEveryMonthAndAcrossDSTTimeZones() throws {
        for identifier in ["Asia/Seoul", "America/Los_Angeles", "Australia/Lord_Howe",
                           "Pacific/Chatham", "Europe/Berlin"] {
            let zone = try XCTUnwrap(TimeZone(identifier: identifier), identifier)
            var zoned = Calendar(identifier: .gregorian)
            zoned.timeZone = zone
            let zonedFormatter = LocalUsageReader.localDayFormatter(timeZone: zone)

            var cases = (1...12).map { (2026, $0, 27) }
            cases.append((2028, 2, 29))   // 윤년 말일

            for (year, month, dayOfMonth) in cases {
                let now = try XCTUnwrap(zoned.date(from: DateComponents(
                    timeZone: zone, year: year, month: month, day: dayOfMonth, hour: 12)))
                let series = LocalUsageReader.monthDailySeries(entries: [], now: now, timeZone: zone)

                XCTAssertEqual(series.count, dayOfMonth,
                               "\(identifier) 축 길이가 날짜와 다르다: \(zonedFormatter.string(from: now))")
                XCTAssertEqual(series.last?.date, zonedFormatter.string(from: now), identifier)
                XCTAssertEqual(series.first?.date,
                               String(format: "%04d-%02d-01", year, month), identifier)
                XCTAssertEqual(Set(series.map { $0.date }).count, series.count,
                               "\(identifier) 중복 날짜: \(zonedFormatter.string(from: now))")
            }
        }
    }

    // MARK: 비용 — 구독제 소스는 0 을 유지

    /// `zeroCost` 는 스칼라와 시리즈에 **함께** 걸려야 한다. 한쪽만 0 이면 팝오버에서 월 비용은
    /// $0 인데 막대 툴팁엔 금액이 뜬다(구독제 소스가 내지 않은 돈).
    func testSubscriptionSourcesReportZeroCostInTheSeriesToo() {
        let now = day(2026, 7, 10)
        let entries = [entry("t", at: day(2026, 7, 5), output: 5_000)]

        let priced = ProviderEnrichment.local(entries: entries, now: now)
        XCTAssertGreaterThan(priced.monthDaily?.reduce(0.0) { $0 + $1.totalCost } ?? 0, 0,
                             "전제: 단가표가 붙는 소스는 비용이 0 이 아니다 — 0 이면 아래 대조가 무의미하다")

        let flat = ProviderEnrichment.local(entries: entries, now: now, zeroCost: true)
        XCTAssertEqual(flat.monthTotal?.totalCost, 0)
        XCTAssertTrue(flat.monthDaily?.allSatisfy { $0.totalCost == 0 } ?? false)
        // 토큰은 그대로 — 비용만 눕힌다.
        XCTAssertEqual(flat.monthDaily?.reduce(0) { $0 + $1.totalTokens },
                       priced.monthDaily?.reduce(0) { $0 + $1.totalTokens })
    }

    // MARK: 프로바이더 무관 — 시리즈를 못 주는 프로바이더가 섞여도

    /// 시리즈가 nil 인 프로바이더는 합계에서 빠질 뿐, 나머지는 정상 합산된다(조용한 degrade).
    /// 비용은 `monthCostTotal` 과 같은 규칙 — 토큰은 전부, 금액은 실제로 청구되는 프로바이더만.
    @MainActor
    func testProvidersWithoutASeriesDropOutWhileTheRestStillAggregate() async {
        let now = Date()
        let today = LocalUsageReader.todayKey()
        let yesterdayKey = dayFormatter.string(
            from: calendar.date(byAdding: .day, value: -1, to: now)!)

        func series(_ values: [(String, Int, Double)]) -> [DailyUsage] {
            values.map { DailyUsage(date: $0.0, inputTokens: 0, outputTokens: $0.1,
                                    cacheCreationTokens: 0, cacheReadTokens: 0,
                                    totalTokens: $0.1, totalCost: $0.2) }
        }
        func daily(_ tokens: Int) -> DailyUsage {
            DailyUsage(date: today, inputTokens: 0, outputTokens: tokens, cacheCreationTokens: 0,
                       cacheReadTokens: 0, totalTokens: tokens, totalCost: 0)
        }

        var withSeries = ProviderEnrichment()
        withSeries.periodsOK = true
        withSeries.monthDaily = series([(yesterdayKey, 100, 1.0), (today, 20, 0.5)])

        var flatRate = ProviderEnrichment()
        flatRate.periodsOK = true
        flatRate.monthDaily = series([(today, 7, 99.0)])   // 금액을 보고해도 flat-rate 는 제외돼야 한다

        var noSeries = ProviderEnrichment()
        noSeries.periodsOK = true
        noSeries.monthDaily = nil                          // 시리즈를 못 주는 프로바이더

        let store = UsageStore(
            providers: [
                TrendProvider(id: "priced", daily: daily(20), enrichment: withSeries),
                TrendProvider(id: "flat", daily: daily(7), enrichment: flatRate, reportsCost: false),
                TrendProvider(id: "blind", daily: daily(3), enrichment: noSeries),
            ],
            claudeLimitsProvider: NoClaudeLimits(), codexLimitsProvider: NoCodexLimits(),
            antigravityLimitsProvider: NoAntigravityLimits(), statusProvider: NoStatus(),
            autoRefresh: false,
            defaults: UserDefaults(suiteName: "MonthDailyTrendTests.\(UUID().uuidString)")!)
        await store.refresh(scheduleEmptyRetry: false)

        let totals = store.monthDailyTotals
        XCTAssertEqual(totals.map(\.date), [yesterdayKey, today], "날짜 오름차순 축")
        XCTAssertEqual(totals.first?.totalTokens, 100)
        XCTAssertEqual(totals.last?.totalTokens, 27, "시리즈를 주는 두 프로바이더의 합")
        XCTAssertEqual(totals.first?.totalCost ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(totals.last?.totalCost ?? -1, 0.5, accuracy: 1e-9,
                       "flat-rate 프로바이더의 금액은 합계에 섞이지 않는다")
    }

    // MARK: 막대 기하

    /// 0 은 사라지지 않고 바닥 눈금으로 남고, 아주 작은 값도 바닥 눈금 이상을 받는다.
    /// `peak <= 0` 은 호출부가 이미 게이트하지만 0 나눗셈이 나지 않아야 한다.
    func testBarHeightBoundaries() {
        XCTAssertEqual(DailyTrendMetrics.barHeight(tokens: 0, peak: 1_000), DailyTrendMetrics.baseline)
        XCTAssertEqual(DailyTrendMetrics.barHeight(tokens: 500, peak: 0), DailyTrendMetrics.baseline)
        XCTAssertEqual(DailyTrendMetrics.barHeight(tokens: 0, peak: 0), DailyTrendMetrics.baseline)
        XCTAssertEqual(DailyTrendMetrics.barHeight(tokens: 1_000, peak: 1_000), DailyTrendMetrics.track)
        XCTAssertEqual(DailyTrendMetrics.barHeight(tokens: 2_000, peak: 1_000), DailyTrendMetrics.track,
                       "최댓값을 넘는 입력은 트랙 밖으로 나가지 않는다")
        XCTAssertGreaterThanOrEqual(DailyTrendMetrics.barHeight(tokens: 1, peak: 10_000_000),
                                    DailyTrendMetrics.baseline)
        XCTAssertLessThanOrEqual(DailyTrendMetrics.barHeight(tokens: 999, peak: 1_000),
                                 DailyTrendMetrics.track)
    }

    // MARK: 표시 게이트 — #56 부류(옵셔널 tautology) 재발 방지

    /// 생산자가 빈 날도 0 으로 채우므로 **이번 달을 한 번도 안 쓴 사용자에게도 배열은 non-empty** 다.
    /// `isEmpty`/`!= nil` 로 게이트하면 빈 막대 행이 뜬다(#56 "안 썼는데 왜 뜨지" 계열).
    /// 게이트가 의미값(`peak > 0`)인지 렌더 높이로 확인한다 — 코드를 읽는 게 아니라 그려보는 것.
    @MainActor
    func testAnAllZeroMonthRendersNothingWhileOneUsedDayRendersTheRow() {
        func zeros(_ count: Int) -> [DailyUsage] {
            (1...count).map { DailyUsage(date: String(format: "2026-07-%02d", $0),
                                         inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0,
                                         cacheReadTokens: 0, totalTokens: 0, totalCost: 0) }
        }
        func rendered(_ series: [DailyUsage]) -> CGFloat {
            let view = MonthDailyTrend(series: series, showsCost: true,
                                       today: "2026-07-10", l: L(.en))
            return NSHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: PopoverMetrics.contentWidth, height: 600)).height
        }

        // 전제: 사용이 0 인 달에도 시리즈는 비어 있지 않다(그래서 isEmpty 게이트가 통하지 않는다).
        let allZero = zeros(10)
        XCTAssertFalse(allZero.isEmpty)
        XCTAssertEqual(rendered(allZero), 0, "사용 0 인 달엔 아무것도 그리지 않아야 한다")

        var used = allZero
        used[2] = DailyUsage(date: "2026-07-03", inputTokens: 0, outputTokens: 1_234,
                             cacheCreationTokens: 0, cacheReadTokens: 0,
                             totalTokens: 1_234, totalCost: 0.4)
        XCTAssertGreaterThan(rendered(used), DailyTrendMetrics.track,
                             "하루라도 썼으면 캡션+막대 행이 그려져야 한다")
    }

    /// 빈 시리즈(아직 enrichment 가 안 돌아온 첫 폴링 전)에서도 그리지 않고 크래시하지 않는다.
    @MainActor
    func testEmptySeriesRendersNothing() {
        let view = MonthDailyTrend(series: [], showsCost: false, today: "2026-07-10", l: L(.en))
        let height = NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: PopoverMetrics.contentWidth, height: 600)).height
        XCTAssertEqual(height, 0)
    }
}
