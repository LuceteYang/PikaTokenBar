import XCTest
import SwiftUI
@testable import PokeTokenBar

/// Contract guards for the visualization choice (`ActivityVisualization`) and the calendar grid
/// (`MonthHeatmapMetrics`).
///
/// The real traps in this feature are two.
/// ① **Date arithmetic in the grid.** Advancing a day by a fixed 86400 seconds slips the grid in a
///    month with DST, and that bug is green or red depending on the contributor's time zone — it
///    passes in Asia/Seoul and fails only in America/Los_Angeles. So the tests inject a DST zone.
/// ② **Is the extension point really that narrow.** "Just add a case" is a lie unless checked.
final class ActivityVisualizationTests: XCTestCase {

    // MARK: Choice — the extension point

    /// The default is the existing bar chart. If it changed, an update alone would silently change
    /// people's popover.
    func testDefaultVisualizationIsTheExistingBarChart() {
        XCTAssertEqual(ActivityVisualization.default, .monthlyBars)
        XCTAssertEqual(ActivityVisualization.allCases.first, .monthlyBars,
                       "the cycle must start at the default too")
    }

    /// The cycle visits `allCases` once and comes back. No hardcoded count — a contributor adding a
    /// visualization should not have to touch this test.
    func testCyclingVisitsEveryVisualizationExactlyOnceAndWrapsAround() {
        var seen: [ActivityVisualization] = []
        var current = ActivityVisualization.default
        for _ in ActivityVisualization.allCases {
            seen.append(current)
            current = current.next
        }
        XCTAssertEqual(Set(seen), Set(ActivityVisualization.allCases), "every visualization must be visited")
        XCTAssertEqual(seen.count, Set(seen).count, "nothing may be visited twice in one lap")
        XCTAssertEqual(current, .default, "one lap must come back to the start")
    }

    /// Every visualization has a name in every language. The exhaustive `switch` catches a missing
    /// case at compile time, but not one that returns an empty string.
    func testEveryVisualizationHasANonEmptyTitleInEveryLanguage() {
        for visualization in ActivityVisualization.allCases {
            for lang in AppLanguage.allCases {
                let title = visualization.title(L(lang))
                XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(visualization.rawValue) has no \(lang.rawValue) title")
            }
        }
    }

    /// Save and restore. An unknown rawValue falls back to the default — going back to a build
    /// without that visualization, or a stray `defaults write`, must not leave the popover empty.
    func testSelectionRoundTripsAndUnknownValuesFallBack() {
        let name = "vis-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }

        suite.set(ActivityVisualization.monthlyHeatmap.rawValue, forKey: "activityVisualization")
        XCTAssertEqual(stored(in: suite), .monthlyHeatmap)

        suite.set("someVisualizationFromTheFuture", forKey: "activityVisualization")
        XCTAssertEqual(stored(in: suite), .default, "unknown values fall back to the default, never an empty popover")
    }

    private func stored(in suite: UserDefaults) -> ActivityVisualization {
        ActivityVisualization(rawValue: suite.string(forKey: "activityVisualization") ?? "")
            ?? .default
    }

    // MARK: Grid geometry

    private let zone = TimeZone(identifier: "America/Los_Angeles")!

    private func calendar(firstWeekday: Int = 2) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        cal.firstWeekday = firstWeekday
        return cal
    }

    private func days(_ pairs: [String: Int] = [:]) -> [String: Int] { pairs }

    func testEveryColumnHasSevenDaysSoWeekdayRowsLineUp() {
        let columns = MonthHeatmapMetrics.columns(
            days: days(), first: "2026-09-01", last: "2026-09-30",
            calendar: calendar(), timeZone: zone)
        XCTAssertFalse(columns.isEmpty)
        XCTAssertTrue(columns.allSatisfy { $0.count == 7 },
                      "a column without seven days shifts every weekday below it")
    }

    /// Days outside the range at the start of the first column and the end of the last are marked.
    /// Without the flag last month's final day draws as a zero and reads as an unused day.
    func testDaysOutsideTheMonthAreMarkedRatherThanDrawnAsZero() {
        let columns = MonthHeatmapMetrics.columns(
            days: days(), first: "2026-09-01", last: "2026-09-30",
            calendar: calendar(), timeZone: zone)
        let cells = columns.flatMap { $0 }
        // 2026-09-01 is a Tuesday, so a Monday-first grid starts with August 31.
        XCTAssertEqual(cells.filter(\.isOutsideRange).map(\.date).first, "2026-08-31")
        XCTAssertTrue(cells.filter { !$0.isOutsideRange }.allSatisfy { $0.date.hasPrefix("2026-09") },
                      "every cell marked in range must belong to the month")
        XCTAssertEqual(cells.filter { !$0.isOutsideRange }.count, 30, "September has 30 days")
    }

    /// Walks **every** combination where adding a fixed 86400 seconds would break the grid.
    ///
    /// Checking only March (spring forward) with a Monday start stayed **green** with 86400
    /// injected: the US transition (Sunday 02:00) is the last day of a Monday-first week, so the
    /// stride never crosses it. The break is **Sunday start + fall back** — 86400 seconds after
    /// Nov 1 00:00 PDT is **Nov 1 23:00 PST**, not Nov 2, so the same date appears twice.
    ///
    /// Hence both week starts × both transition months. With one combination there is no telling
    /// a guard that protects nothing from one that works.
    func testGridStaysContiguousAcrossDSTInEveryWeekStartAndDirection() {
        let months = [("2026-03-01", "2026-03-31"),    // spring forward (23 hours)
                      ("2026-11-01", "2026-11-30")]    // fall back (25 hours)
        for firstWeekday in [1, 2] {
            for (first, last) in months {
                let cal = calendar(firstWeekday: firstWeekday)
                let columns = MonthHeatmapMetrics.columns(days: days(), first: first, last: last,
                                                          calendar: cal, timeZone: zone)
                let dates = columns.flatMap { $0.map(\.date) }
                XCTAssertEqual(Set(dates).count, dates.count,
                               "firstWeekday=\(firstWeekday) \(first): a date repeats — the grid slipped a day")

                let formatter = LocalUsageReader.localDayFormatter(timeZone: zone)
                for index in 1..<dates.count {
                    let previous = formatter.date(from: dates[index - 1])!
                    let expected = formatter.string(
                        from: cal.date(byAdding: .day, value: 1, to: previous)!)
                    XCTAssertEqual(dates[index], expected,
                                   "firstWeekday=\(firstWeekday): \(dates[index - 1]) → \(dates[index]) breaks the sequence")
                }
            }
        }
    }

    func testGridStartDayFollowsTheCalendarFirstWeekday() {
        let monday = MonthHeatmapMetrics.columns(
            days: days(), first: "2026-09-01", last: "2026-09-30",
            calendar: calendar(firstWeekday: 2), timeZone: zone)
        let sunday = MonthHeatmapMetrics.columns(
            days: days(), first: "2026-09-01", last: "2026-09-30",
            calendar: calendar(firstWeekday: 1), timeZone: zone)
        XCTAssertNotEqual(monday.first?.first?.date, sunday.first?.first?.date,
                          "the first weekday is the locale's call — hardcoded, these two would match")
    }

    /// The grid covers the whole month whatever its length and starting weekday. Checking one month
    /// would pass on the case where February fits exactly four weeks.
    func testGridCoversEveryDayOfEveryMonthInAYear() throws {
        let formatter = LocalUsageReader.localDayFormatter(timeZone: zone)
        var cal = calendar()
        for month in 1...12 {
            let start = String(format: "2026-%02d-01", month)
            let startDate = try XCTUnwrap(formatter.date(from: start))
            let range = try XCTUnwrap(cal.range(of: .day, in: .month, for: startDate))
            let last = String(format: "2026-%02d-%02d", month, range.count)

            let inRange = MonthHeatmapMetrics.columns(days: days(), first: start, last: last,
                                                      calendar: cal, timeZone: zone)
                .flatMap { $0 }.filter { !$0.isOutsideRange }.map(\.date)
            XCTAssertEqual(inRange.count, range.count, "month \(month) is not fully in the grid")
            XCTAssertEqual(inRange.first, start)
            XCTAssertEqual(inRange.last, last)
        }
    }

    func testUnparseableRangeYieldsAnEmptyGridRatherThanCrashing() {
        XCTAssertTrue(MonthHeatmapMetrics.columns(days: days(), first: "nope", last: "2026-09-30",
                                                  calendar: calendar(), timeZone: zone).isEmpty)
        XCTAssertTrue(MonthHeatmapMetrics.columns(days: days(), first: "2026-09-30",
                                                  last: "2026-09-01",
                                                  calendar: calendar(), timeZone: zone).isEmpty,
                      "a reversed range makes no grid")
    }

    /// Row labels start where the grid's columns start, or every row is labeled with the wrong day.
    func testWeekdayLabelsFollowTheFirstWeekdayAndTheDisplayLanguage() {
        let mondayFirst = MonthHeatmapMetrics.weekdayLabels(firstWeekday: 2,
                                                            locale: Locale(identifier: "en_US"))
        XCTAssertEqual(mondayFirst, ["M", "T", "W", "T", "F", "S", "S"])
        let sundayFirst = MonthHeatmapMetrics.weekdayLabels(firstWeekday: 1,
                                                            locale: Locale(identifier: "ko_KR"))
        XCTAssertEqual(sundayFirst.first, "일")
        XCTAssertEqual(sundayFirst.last, "토")
    }

    // MARK: Shade levels

    /// 0 (unused) splits from 1 (a little). Boundaries are inclusive (`<=`), so a day at exactly 25%
    /// does not leak a level up.
    func testLevelSeparatesUnusedDaysAndSplitsTheRestIntoQuartiles() {
        let peak = 100_000_000
        XCTAssertEqual(MonthHeatmapMetrics.level(tokens: 0, peak: peak), 0)
        XCTAssertEqual(MonthHeatmapMetrics.level(tokens: 1, peak: peak), 1)
        XCTAssertEqual(MonthHeatmapMetrics.level(tokens: 25_000_000, peak: peak), 1)
        XCTAssertEqual(MonthHeatmapMetrics.level(tokens: 25_000_001, peak: peak), 2)
        XCTAssertEqual(MonthHeatmapMetrics.level(tokens: 50_000_000, peak: peak), 2)
        XCTAssertEqual(MonthHeatmapMetrics.level(tokens: 75_000_000, peak: peak), 3)
        XCTAssertEqual(MonthHeatmapMetrics.level(tokens: peak, peak: peak), 4)
    }

    /// Cells outside the range (-1) are clear — any color would claim something about that day.
    /// A single-provider month uses the contribution greens, not the accent color, which would read
    /// as one provider's color.
    func testOutsideRangeCellsAreDrawnAsNothing() {
        XCTAssertEqual(MonthHeatmapMetrics.fill(level: -1), Color.clear)
        XCTAssertNotEqual(MonthHeatmapMetrics.fill(level: 0), Color.clear,
                          "an unused day is drawn, not clear — the day existed")
        XCTAssertEqual(Set((0...4).map { MonthHeatmapMetrics.fill(level: $0) }).count, 5,
                       "every level needs its own green")
        for level in 1...4 {
            XCTAssertNotEqual(MonthHeatmapMetrics.fill(level: level), Color.accentColor.opacity(
                MonthHeatmapMetrics.shade(level: level)), "level \(level) uses the accent color")
        }
        XCTAssertLessThan(MonthHeatmapMetrics.shade(level: 1), MonthHeatmapMetrics.shade(level: 4),
                          "a busier day must draw stronger")
    }

    // MARK: The popover's month

    private func series(through today: String) -> [DailyUsage] {
        let day = Int(today.suffix(2))!
        return (1...day).map { index in
            let date = String(format: "%@-%02d", String(today.prefix(7)), index)
            return DailyUsage(date: date, inputTokens: 0, outputTokens: 1_000, cacheCreationTokens: 0,
                              cacheReadTokens: 0, totalTokens: 1_000, totalCost: 0)
        }
    }

    /// The grid spans the calendar month, not the series that ends today. Sized by the series it
    /// gains a column every week, and on the 1st it is a single column.
    func testGridKeepsTheMonthsWidthFromTheFirstToTheLastDay() {
        let first = MonthHeatmapMetrics.monthGrid(series: series(through: "2026-09-01"),
                                                  today: "2026-09-01",
                                                  calendar: calendar(), timeZone: zone)
        let last = MonthHeatmapMetrics.monthGrid(series: series(through: "2026-09-30"),
                                                 today: "2026-09-30",
                                                 calendar: calendar(), timeZone: zone)
        XCTAssertEqual(first.count, last.count, "the grid changed width during the month")
        XCTAssertEqual(first.flatMap { $0 }.map(\.date), last.flatMap { $0 }.map(\.date))
    }

    /// Days still to come are outside the range, so they draw as nothing rather than as unused days.
    func testDaysAfterTodayAreOutsideTheRange() {
        let cells = MonthHeatmapMetrics.monthGrid(series: series(through: "2026-09-10"),
                                                  today: "2026-09-10",
                                                  calendar: calendar(), timeZone: zone)
            .flatMap { $0 }
        let inRange = cells.filter { !$0.isOutsideRange }.map(\.date)
        XCTAssertEqual(inRange.first, "2026-09-01")
        XCTAssertEqual(inRange.last, "2026-09-10", "today is the last day in range")
        XCTAssertTrue(cells.contains { $0.date == "2026-09-30" && $0.isOutsideRange },
                      "the rest of the month is still in the grid, marked outside")
    }

    // MARK: Panel

    /// The bars inside the panel still stack by provider. `ActivityPanel` sits between the popover
    /// and `MonthDailyTrend`, so a dropped `providers` argument would silently fall back to
    /// single-color bars and still compile.
    @MainActor
    func testPanelBarsDrawTheSameAsTheTrendItWraps() throws {
        let one = series(through: "2026-08-24")
        let two = [DailyTrendStack.ProviderSeries(id: "a", name: "A", days: one, reportsCost: false),
                   DailyTrendStack.ProviderSeries(id: "b", name: "B", days: one, reportsCost: false)]
        let total = one.map { DailyUsage(date: $0.date, inputTokens: 0, outputTokens: 2_000,
                                         cacheCreationTokens: 0, cacheReadTokens: 0,
                                         totalTokens: 2_000, totalCost: 0) }
        let panel = try pixels(ActivityPanel(visualization: .monthlyBars, series: total,
                                             providers: two, providerOrder: ["a", "b"],
                                             showsCost: false, today: "2026-08-24", l: L(.en),
                                             onCycle: {}))
        let stacked = try pixels(MonthDailyTrend(series: total, providers: two,
                                                 providerOrder: ["a", "b"], showsCost: false,
                                                 today: "2026-08-24", l: L(.en),
                                                 trailing: AnyView(PageDots(current: .monthlyBars))))
        let flat = try pixels(MonthDailyTrend(series: total, showsCost: false,
                                              today: "2026-08-24", l: L(.en),
                                              trailing: AnyView(PageDots(current: .monthlyBars))))
        XCTAssertNotEqual(stacked, flat, "two providers must stack, or this test proves nothing")
        XCTAssertEqual(panel, stacked, "the panel dropped the provider stack")
    }

    /// The grid splits by provider too, like the bars. Same guard as above: the panel sits between
    /// the popover and `MonthHeatmap`, so dropping `providers` would compile and quietly draw one
    /// neutral total.
    @MainActor
    func testPanelGridSplitsByProviderLikeTheBars() throws {
        let one = series(through: "2026-08-24")
        let two = [DailyTrendStack.ProviderSeries(id: "a", name: "A", days: one, reportsCost: false),
                   DailyTrendStack.ProviderSeries(id: "b", name: "B", days: one, reportsCost: false)]
        let total = one.map { DailyUsage(date: $0.date, inputTokens: 0, outputTokens: 2_000,
                                         cacheCreationTokens: 0, cacheReadTokens: 0,
                                         totalTokens: 2_000, totalCost: 0) }
        let dots = AnyView(PageDots(current: .monthlyHeatmap))
        let panel = try pixels(ActivityPanel(visualization: .monthlyHeatmap, series: total,
                                             providers: two, providerOrder: ["a", "b"],
                                             showsCost: false, today: "2026-08-24", l: L(.en),
                                             onCycle: {}))
        let split = try pixels(MonthHeatmap(series: total, providers: two, providerOrder: ["a", "b"],
                                            showsCost: false, today: "2026-08-24", l: L(.en),
                                            trailing: dots))
        let neutral = try pixels(MonthHeatmap(series: total, showsCost: false, today: "2026-08-24",
                                              l: L(.en), trailing: dots))
        XCTAssertNotEqual(split, neutral, "two providers must split the cells, or this test proves nothing")
        XCTAssertEqual(panel, split, "the panel dropped the provider split")
    }

    @MainActor
    private func pixels<V: View>(_ view: V) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: PopoverMetrics.contentWidth))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }
}
