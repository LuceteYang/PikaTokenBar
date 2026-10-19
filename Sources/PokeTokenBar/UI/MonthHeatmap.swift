import AppKit
import SwiftUI

/// One cell of the heatmap.
struct ActivityCell: Equatable, Sendable {
    let date: String
    let tokens: Int
    /// Inside the grid but not part of the range. The grid is cut into whole weeks so the weekday
    /// rows line up, which puts days of the neighboring months into the first and last columns.
    /// Dropping them shortens a column and shifts every weekday below; drawing them as zero reads
    /// as "unused day".
    let isOutsideRange: Bool
}

/// Grid geometry and shading, as pure functions outside the view: inside SwiftUI they could not be
/// tested headless, and this math goes quietly wrong at week boundaries, DST and month starts
/// (the same reason `DailyTrendMetrics` exists).
enum MonthHeatmapMetrics {
    /// Row height. Cells take the row's width, so a month of five or six weeks fills the popover
    /// like the bars do instead of sitting as a small block at the left edge.
    static let cell: CGFloat = 10
    static let spacing: CGFloat = 2

    /// One-letter weekday names for the rows, starting at `firstWeekday` like `columns`. Without them
    /// nothing says which row is the weekend — the pattern the grid exists to show. The names come
    /// from the display language; the first weekday from the region, as in `columns`.
    static func weekdayLabels(firstWeekday: Int, locale: Locale) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols    // Sunday first
        let start = (firstWeekday - 1) % symbols.count
        return Array(symbols[start...] + symbols[..<start])
    }

    /// Weeks (columns) × weekdays (rows): the fewest whole weeks covering `first`…`last`.
    ///
    /// The weekday a column starts on is `calendar.firstWeekday` — Monday in some regions, Sunday
    /// in others, and that is the locale's call, not this code's.
    ///
    /// Days advance through `Calendar` rather than a fixed 86400 seconds: on a DST day the local day
    /// is 23 or 25 hours long and the grid would slip a day. Worse, that bug is green or red
    /// depending on the contributor's time zone — it passes in Asia/Seoul — so `calendar` and
    /// `timeZone` are injectable.
    static func columns(days: [String: Int], first: String, last: String,
                        calendar: Calendar = .current,
                        timeZone: TimeZone = .current) -> [[ActivityCell]] {
        var cal = calendar
        cal.timeZone = timeZone
        let formatter = LocalUsageReader.localDayFormatter(timeZone: timeZone)
        // Not a day key: give up on the grid (empty rather than a crash). Production passes the
        // month's first and last day, so this does not happen; the optionals are the API's.
        guard first <= last,
              let firstDate = formatter.date(from: first),
              let lastDate = formatter.date(from: last),
              let gridStart = cal.dateInterval(of: .weekOfYear, for: firstDate)?.start
        else { return [] }

        var columns: [[ActivityCell]] = []
        var cursor = gridStart
        while cursor <= lastDate {
            var column: [ActivityCell] = []
            for offset in 0..<7 {
                // The optional is the API's — it does not fail in the Gregorian calendar.
                guard let date = cal.date(byAdding: .day, value: offset, to: cursor) else { continue }
                let key = formatter.string(from: date)
                // "yyyy-MM-dd" sorts lexicographically the same way it sorts chronologically.
                column.append(ActivityCell(date: key, tokens: days[key] ?? 0,
                                           isOutsideRange: key < first || key > last))
            }
            columns.append(column)
            guard let nextWeek = cal.date(byAdding: .weekOfYear, value: 1, to: cursor) else { break }
            cursor = nextWeek
        }
        return columns
    }

    /// The popover's grid: the calendar month `today` falls in, with the days still to come marked
    /// outside the range. Spanning the month rather than the series (which ends today) keeps the grid
    /// the same width all month; sized by the series it would gain a column every week.
    static func monthGrid(series: [DailyUsage], today: String,
                          calendar: Calendar = .current,
                          timeZone: TimeZone = .current) -> [[ActivityCell]] {
        let month = DailyTrendMetrics.monthColumns(series: series, today: today)
        guard let first = month.first?.date, let last = month.last?.date else { return [] }
        let days = Dictionary(month.map { ($0.date, $0.tokens) }, uniquingKeysWith: +)
        return columns(days: days, first: first, last: last, calendar: calendar, timeZone: timeZone)
            .map { column in
                column.map { cell in
                    // A day still to come has nothing to say yet, same as a day of another month.
                    cell.date > today
                        ? ActivityCell(date: cell.date, tokens: cell.tokens, isOutsideRange: true)
                        : cell
                }
            }
    }

    /// Shade level 0…4: 0 is an unused day, 1…4 are quartiles of the peak.
    ///
    /// No `peak == 0` guard: `peak` is the month's maximum, so once `tokens > 0` holds,
    /// `peak >= tokens > 0` does too (and the caller only draws when `peak > 0`).
    static func level(tokens: Int, peak: Int) -> Int {
        guard tokens > 0 else { return 0 }
        let ratio = Double(tokens) / Double(peak)
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.50 { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }

    /// Level → strength, shared by both fills below so one level reads the same in gray and in a
    /// provider's color.
    static func shade(level: Int) -> Double {
        switch level {
        case 1:  return 0.35
        case 2:  return 0.55
        case 3:  return 0.78
        default: return 1
        }
    }

    /// Level → color for a single-provider month: the contribution-graph greens developers already
    /// read without a legend ("darker = less, brighter = more"). Not the accent color — the grid is
    /// a total, and the accent (blue by default) would read as a provider in the bars' palette.
    /// Light and dark each get their own scale, as on GitHub, so level 1 never vanishes into the
    /// background. Only 0 is near the background, so that edge alone says "used that day".
    static func fill(level: Int) -> Color {
        switch level {
        case 0...4:    return contributionGreens[level]
        default:       return Color.clear      // outside the range or still to come: holds a place, claims nothing
        }
    }

    /// Index = level. Light / dark hex pairs of the contribution graph.
    static let contributionGreens: [Color] = [
        (0xEBEDF0, 0x161B22), (0x9BE9A8, 0x0E4429), (0x40C463, 0x006D32),
        (0x30A14E, 0x26A641), (0x216E39, 0x39D353),
    ].map { light, dark in
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

/// This month's usage as a calendar grid — `ActivityVisualization.monthlyHeatmap`.
///
/// It draws the same data as `MonthDailyTrend` but answers a different question. Bars compare
/// amounts by height; the grid's rows are fixed weekdays, so a habit like "barely anything on
/// weekends" shows at a glance. The two are alternatives, not a hierarchy.
///
/// The display gate is a meaningful value (`peak > 0`), not `series.isEmpty` — the producer fills
/// unused days with zeros, so the series is non-empty even for a month with no usage at all.
@MainActor
struct MonthHeatmap: View {
    let series: [DailyUsage]
    /// Each provider's own month series. With two or more used this month, every cell splits
    /// left → right into provider shares in the bars' colors, with the same legend; otherwise the
    /// cells are neutral.
    var providers: [DailyTrendStack.ProviderSeries] = []
    /// `UsageStore.registeredProviderIDs`, so a provider has the same color here as in the bars.
    var providerOrder: [String] = []
    let showsCost: Bool
    /// Today's `localDay` key, injected so the view does not read the clock again.
    let today: String
    let l: L
    /// The switch dots, as in `MonthDailyTrend.trailing`.
    var trailing = AnyView(EmptyView())

    /// The hovered cell. The cells are too small to carry a tooltip of their own, so the caption's
    /// readout follows the pointer and falls back to today.
    @State private var hovered: String?

    var body: some View {
        let columns = DailyTrendMetrics.monthColumns(series: series, today: today)
        let peak = columns.map(\.tokens).max() ?? 0
        if peak > 0 {
            let stack = DailyTrendStack.ordered(providers)
            let colors = DailyTrendStack.colorIndices(for: stack.map(\.id), registry: providerOrder,
                                                      paletteCount: MonthDailyTrend.providerPalette.count)
            VStack(alignment: .leading, spacing: 3) {
                captionRow(peak: peak, showsPeak: DailyTrendMetrics.showsPeak(columns))
                grid(peak: peak, stack: stack, colors: colors)
                if DailyTrendStack.isStacked(stack) {
                    MonthDailyTrend.legend(stack, colors: colors)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 4)
        }
    }

    /// Same layout as the bars' caption — title, readout, peak, switch dots. The peak stays for the
    /// same reason: shades are relative, so one place has to state the absolute scale.
    private func captionRow(peak: Int, showsPeak: Bool) -> some View {
        HStack(spacing: 5) {
            // If anything has to give in a narrow language, it is the title: the readout (the
            // number people open the popover for) stays on one line.
            Text(l.monthlyHeatmap)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(MonthDailyTrend.readout(series: series, today: hovered ?? today,
                                         showsCost: showsCost, l: l))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Spacer()
            if showsPeak {
                Text(l.peakDay)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(TokenFormatter.compact(peak))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            trailing
        }
    }

    private func grid(peak: Int, stack: [DailyTrendStack.ProviderSeries],
                      colors: [String: Int]) -> some View {
        HStack(alignment: .top, spacing: MonthHeatmapMetrics.spacing + 2) {
            VStack(alignment: .leading, spacing: MonthHeatmapMetrics.spacing) {
                ForEach(Array(MonthHeatmapMetrics.weekdayLabels(
                    firstWeekday: Calendar.current.firstWeekday,
                    locale: l.lang.displayLocale).enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(height: MonthHeatmapMetrics.cell)
                }
            }
            HStack(spacing: MonthHeatmapMetrics.spacing) {
                ForEach(Array(MonthHeatmapMetrics.monthGrid(series: series, today: today)
                    .enumerated()), id: \.offset) { _, column in
                    VStack(spacing: MonthHeatmapMetrics.spacing) {
                        ForEach(column, id: \.date) { cell in
                            self.cellView(cell, peak: peak, stack: stack, colors: colors)
                        }
                    }
                }
            }
        }
    }

    private func cellView(_ cell: ActivityCell, peak: Int, stack: [DailyTrendStack.ProviderSeries],
                          colors: [String: Int]) -> some View {
        let level = cell.isOutsideRange ? -1
                                        : MonthHeatmapMetrics.level(tokens: cell.tokens, peak: peak)
        return fill(cell, level: level, stack: stack, colors: colors)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(cell.date == today ? Color.primary.opacity(0.55) : Color.clear,
                                  lineWidth: 1)
            )
            .frame(maxWidth: .infinity, minHeight: MonthHeatmapMetrics.cell, maxHeight: MonthHeatmapMetrics.cell)
            .contentShape(Rectangle())
            .onHover { inside in
                guard !cell.isOutsideRange else { return }
                hovered = inside ? cell.date : nil
            }
    }

    /// A provider-split cell when the month is stacked and the day was used; a neutral one otherwise.
    /// The split reuses the bars' `segments`, laid sideways: shares left → right in stack order.
    @ViewBuilder
    private func fill(_ cell: ActivityCell, level: Int, stack: [DailyTrendStack.ProviderSeries],
                      colors: [String: Int]) -> some View {
        if level > 0, DailyTrendStack.isStacked(stack) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(DailyTrendStack.segments(on: cell.date, stack: stack,
                                                     barHeight: geometry.size.width),
                            id: \.providerID) { segment in
                        MonthDailyTrend.color(for: segment.providerID, in: colors)
                            .opacity(MonthHeatmapMetrics.shade(level: level))
                            .frame(width: segment.height)
                    }
                }
            }
        } else {
            Rectangle().fill(MonthHeatmapMetrics.fill(level: level))
        }
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
