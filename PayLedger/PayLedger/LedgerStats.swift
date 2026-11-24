import Foundation

/// Shared summary logic used by the home screen and (later) the bill screens,
/// so a single source of truth computes every total.
enum LedgerStats {
    #if DEBUG
    /// UI-test-only time-zone override so a restart under another zone can be
    /// rerun deterministically (e.g. UTC+8 → UTC+9 → UTC). Compiled out of
    /// release; production always uses the device's current zone.
    static var calendarTimeZoneOverride: TimeZone?
    #endif

    /// Gregorian calendar with Monday as the first weekday, matching the
    /// Monday-to-Sunday weekly bill in the requirements.
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        #if DEBUG
        cal.timeZone = calendarTimeZoneOverride ?? .current
        #else
        cal.timeZone = .current
        #endif
        return cal
    }

    /// Half-open interval [start, end): a record exactly at midnight on the
    /// next day belongs to the next period, never to two periods at once.
    /// - Returns: the exact total, or nil when it exceeds `Int` and cannot be
    ///   represented. Callers must show an explicit out-of-range message rather
    ///   than a capped number that would be confused with a real total.
    static func totalCents(_ expenses: [Expense], in interval: DateInterval) -> Int? {
        totalCents(expenses, in: interval, calendar: calendar)
    }

    /// Calendar-injectable form for tests whose interval is built in a specific
    /// zone; the stored consumption day resolves to midnight in that calendar.
    static func totalCents(_ expenses: [Expense], in interval: DateInterval,
                           calendar: Calendar) -> Int? {
        // Period totals and every group subtotal share the exact sum below;
        // only the set of records differs (half-open interval vs. a group).
        sumCents(expenses.filter {
            let d = billDate(of: $0, calendar: calendar)
            return d >= interval.start && d < interval.end
        })
    }

    /// The day used for every bill and coverage decision. A record saved by the
    /// app carries the day chosen at entry time; a legacy record without one
    /// falls back to the day derived from its timestamp in `calendar` (the
    /// store persists that fallback once on first load so it stays stable).
    static func consumptionDay(of expense: Expense, calendar: Calendar) -> ConsumptionDay {
        expense.consumptionDay ?? ConsumptionDay.from(expense.date, calendar: calendar)
    }

    /// The stable instant representing a record's consumption day: local
    /// midnight of that day in `calendar`. Every interval comparison uses this
    /// instead of the raw timestamp, so changing the device time zone between
    /// restarts cannot move a record into a neighbouring day/week/month.
    static func billDate(of expense: Expense, calendar: Calendar) -> Date {
        // A stored day is authoritative. Without one (a legacy record before
        // first-load backfill, or a fixture built in a specific calendar) keep
        // the raw instant: the caller's interval already carries its calendar,
        // and re-deriving a day in `calendar` would silently shift it.
        if let day = expense.consumptionDay, let date = day.date(in: calendar) { return date }
        return expense.date
    }

    /// A per-record total that also honours the opening balance. When an
    /// opening balance is set, records on or before its cutoff belong to the
    /// covered (pre-enablement) period and are excluded from every summary;
    /// without one, all records still count.
    static func totalCents(_ expenses: [Expense], history: HistorySnapshot,
                           in interval: DateInterval) -> Int? {
        totalCents(eligibleExpenses(expenses, history: history), in: interval)
    }

    static func dayInterval(containing date: Date) -> DateInterval? {
        calendar.dateInterval(of: .day, for: date)
    }

    static func weekInterval(containing date: Date) -> DateInterval? {
        calendar.dateInterval(of: .weekOfYear, for: date)
    }

    static func monthInterval(containing date: Date) -> DateInterval? {
        calendar.dateInterval(of: .month, for: date)
    }

    static func yearInterval(containing date: Date) -> DateInterval? {
        calendar.dateInterval(of: .year, for: date)
    }

    /// Exact sum of a group's cents, or nil on overflow. Bills never show a
    /// capped number in place of a real total.
    static func sumCents(_ expenses: [Expense]) -> Int? {
        sumCents(expenses.map(\.amountCents))
    }

    /// Exact sum of cent values, shared by per-record totals and the historical
    /// amounts so both overflow the same way.
    static func sumCents(_ cents: [Int]) -> Int? {
        var total = 0
        for cents in cents {
            let (sum, overflow) = total.addingReportingOverflow(cents)
            if overflow { return nil }
            total = sum
        }
        return total
    }

    // MARK: - Issue 04: month-precision history

    /// Per-record expenses that still count after an opening balance is set.
    /// Records on or before the cutoff are pre-enablement data: they stay in
    /// the ledger file byte-for-byte, but are excluded from every home summary,
    /// week/category subtotal and month/year detail or total. The cutoff is a
    /// calendar day (year/month/day), so compare the record's local calendar
    /// day rather than a raw instant — that keeps attribution stable when the
    /// device time zone changes between restarts.
    static func eligibleExpenses(_ expenses: [Expense], history: HistorySnapshot) -> [Expense] {
        eligibleExpenses(expenses, history: history, calendar: calendar)
    }

    /// Calendar-injectable form so month/year boundaries can be verified in a
    /// time zone whose month start is moved past midnight by a DST jump.
    static func eligibleExpenses(_ expenses: [Expense], history: HistorySnapshot,
                                 calendar: Calendar) -> [Expense] {
        guard let opening = history.openingBalance else { return expenses }
        return expenses.filter { expense in
            // Compare the stored consumption day, never the instant re-read in
            // the current time zone: a 23:30 record must stay on its recorded
            // day even after the device is moved to another zone.
            consumptionDay(of: expense, calendar: calendar).tuple >
                (opening.cutoffYear, opening.cutoffMonth, opening.cutoffDay)
        }
    }

    /// Historical month summaries whose month starts inside `interval`. They
    /// are month-precise, so they belong to month and year totals only.
    static func historicalMonths(in interval: DateInterval, from history: HistorySnapshot) -> [HistoricalMonth] {
        historicalMonths(in: interval, from: history, calendar: calendar)
    }

    static func historicalMonths(in interval: DateInterval, from history: HistorySnapshot,
                                 calendar: Calendar) -> [HistoricalMonth] {
        history.monthlySummaries.filter { item in
            guard let start = monthStart(year: item.year, month: item.month, calendar: calendar) else { return false }
            return start >= interval.start && start < interval.end
        }
        .sorted { ($0.year, $0.month) < ($1.year, $1.month) }
    }

    /// The opening balance belongs to the month of its stored cutoff
    /// components (the day before enablement, always November 2026). Using the
    /// stored year/month rather than an instant keeps the attribution stable
    /// across time zones and restarts. It is one cumulative value, so it is
    /// included once in that month's and that year's total.
    static func openingBalance(in interval: DateInterval, from history: HistorySnapshot) -> OpeningBalance? {
        openingBalance(in: interval, from: history, calendar: calendar)
    }

    static func openingBalance(in interval: DateInterval, from history: HistorySnapshot,
                               calendar: Calendar) -> OpeningBalance? {
        guard let opening = history.openingBalance else { return nil }
        guard let start = monthStart(year: opening.cutoffYear, month: opening.cutoffMonth, calendar: calendar),
              start >= interval.start && start < interval.end else { return nil }
        return opening
    }

    /// A month/year total. Per-record expenses use the half-open interval;
    /// historical month summaries and the opening balance are added at month
    /// precision. Day/week callers must use `totalCents`, which never includes
    /// history: a cumulative opening amount must not be spread across weeks or
    /// days that have no per-record detail.
    static func periodTotalCents(_ expenses: [Expense], history: HistorySnapshot,
                                 in interval: DateInterval) -> Int? {
        periodTotalCents(expenses, history: history, in: interval, calendar: calendar)
    }

    static func periodTotalCents(_ expenses: [Expense], history: HistorySnapshot,
                                 in interval: DateInterval, calendar: Calendar) -> Int? {
        var cents = eligibleExpenses(expenses, history: history, calendar: calendar)
            .filter {
                let d = billDate(of: $0, calendar: calendar)
                return d >= interval.start && d < interval.end
            }
            .map(\.amountCents)
        // Historical values have month-level precision only. A shorter window
        // (a day or week) must never pick up a month summary merely because it
        // contains the 1st; those callers use `totalCents`, and this guard keeps
        // the function safe even if such an interval is passed by mistake.
        if isWholeMonthOrYear(interval, calendar: calendar) {
            cents += historicalMonths(in: interval, from: history, calendar: calendar).map(\.amountCents)
            if let opening = openingBalance(in: interval, from: history, calendar: calendar) {
                cents.append(opening.amountCents)
            }
        }
        return sumCents(cents)
    }

    /// True only when the interval runs from the start of one calendar month
    /// to the end of a calendar month — the shape produced by `monthInterval`
    /// / `yearInterval`. Both ends are derived from the calendar rather than
    /// from a hardcoded 00:00: in time zones where a month starts after
    /// midnight because of a DST jump (e.g. America/Asuncion 2023-10 starts
    /// at 01:00), the real month interval no longer has a midnight start, and
    /// a midnight test would silently drop that month's history.
    private static func isWholeMonthOrYear(_ interval: DateInterval, calendar: Calendar) -> Bool {
        guard interval.end > interval.start else { return false }
        guard let startMonth = calendar.dateInterval(of: .month, for: interval.start),
              startMonth.start == interval.start else { return false }
        // `end` is exclusive. Sample the last instant inside the interval to
        // find the month whose boundary it closes.
        let lastInstant = interval.end.addingTimeInterval(-0.001)
        guard let endMonth = calendar.dateInterval(of: .month, for: lastInstant),
              endMonth.end == interval.end else { return false }
        return true
    }

    private static func monthStart(year: Int?, month: Int?, calendar: Calendar) -> Date? {
        guard let year, let month else { return nil }
        // Day 15 is always inside the month; deriving the interval from it
        // avoids the nonexistent midnight on day 1 in DST-jump time zones.
        guard let mid = calendar.date(from: DateComponents(year: year, month: month, day: 15)) else { return nil }
        return calendar.dateInterval(of: .month, for: mid)?.start
    }

    /// Whether an unavailable history file can invalidate this bill interval's
    /// total. Every historical value is month-precise and limited to months
    /// before 2026-12: monthly summaries are before 2026-11 and the opening
    /// balance belongs to its 2026-11 cutoff month (enable day at latest
    /// 2026-12-01). An interval starting on/after 2026-12-01 lies entirely
    /// after every possible history value, so its total is computable from
    /// per-record expenses alone even when history is unreadable. A nil or
    /// unresolvable boundary is treated conservatively as affected.
    static func historyAffects(_ interval: DateInterval, calendar: Calendar = calendar) -> Bool {
        guard let firstUnaffected = monthStart(year: 2026, month: 12, calendar: calendar) else { return true }
        return interval.start < firstUnaffected
    }

    /// One primary-category subtotal in the weekly bill. `expenses` are the
    /// drill-down rows (ordered by date) revealed when the subtotal expands.
    struct CategoryGroup: Identifiable, Equatable {
        var id: String { categoryID }
        let categoryID: String
        let expenses: [Expense]
    }

    /// One calendar day's records in a monthly or yearly bill.
    struct BillDay: Identifiable, Equatable {
        var id: String { dayKey }
        let dayKey: String
        let date: Date
        let expenses: [Expense]
    }

    /// One month's summary in the yearly bill; the same day rows also make up
    /// the monthly bill. Months with no records are kept so a year is complete.
    struct BillMonth: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let title: String
        let monthStart: Date
        let expenses: [Expense]
        let days: [BillDay]
    }

    /// Groups the week's individual records by primary category. Group order
    /// follows first appearance so the result is deterministic without needing
    /// the category tree; the view resolves ids to display names.
    static func weekCategoryGroups(_ expenses: [Expense], history: HistorySnapshot,
                                   in interval: DateInterval) -> [CategoryGroup] {
        weekCategoryGroups(eligibleExpenses(expenses, history: history), in: interval)
    }

    static func weekCategoryGroups(_ expenses: [Expense], in interval: DateInterval) -> [CategoryGroup] {
        var order: [String] = []
        var byID: [String: [Expense]] = [:]
        let cal = calendar
        for expense in expenses {
            let d = billDate(of: expense, calendar: cal)
            guard d >= interval.start && d < interval.end else { continue }
            if byID[expense.categoryID] == nil { order.append(expense.categoryID) }
            byID[expense.categoryID, default: []].append(expense)
        }
        return order.compactMap { id in
            guard let rows = byID[id] else { return nil }
            return CategoryGroup(categoryID: id, expenses: rows.sorted { $0.date < $1.date })
        }
    }

    /// The month's individual records grouped by calendar day, oldest first.
    static func monthDays(_ expenses: [Expense], history: HistorySnapshot,
                          in interval: DateInterval) -> [BillDay] {
        monthDays(eligibleExpenses(expenses, history: history), in: interval)
    }

    static func monthDays(_ expenses: [Expense], in interval: DateInterval) -> [BillDay] {
        let cal = calendar
        let inMonth = expenses.filter {
            let d = billDate(of: $0, calendar: cal)
            return d >= interval.start && d < interval.end
        }
        return billDays(from: inMonth)
    }

    /// All twelve months of the interval's year, each with its own day rows,
    /// so the year view can expand months independently.
    static func yearMonths(_ expenses: [Expense], history: HistorySnapshot,
                           in interval: DateInterval) -> [BillMonth] {
        yearMonths(eligibleExpenses(expenses, history: history), in: interval)
    }

    static func yearMonths(_ expenses: [Expense], in interval: DateInterval) -> [BillMonth] {
        let cal = calendar
        let inYear = expenses.filter {
            let d = billDate(of: $0, calendar: cal)
            return d >= interval.start && d < interval.end
        }
        guard let year = cal.dateComponents([.year], from: interval.start).year else { return [] }
        var months: [BillMonth] = []
        for month in 1...12 {
            guard let start = cal.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = cal.date(from: DateComponents(year: year, month: month + 1, day: 1))
            else { continue }
            let rows = inYear.filter {
                let d = billDate(of: $0, calendar: cal)
                return d >= start && d < end
            }
            months.append(BillMonth(
                key: String(format: "%04d-%02d", year, month),
                title: "\(month)月",
                monthStart: start,
                expenses: rows,
                days: billDays(from: rows)))
        }
        return months
    }

    private static func billDays(from expenses: [Expense]) -> [BillDay] {
        var order: [String] = []
        var byKey: [String: [Expense]] = [:]
        var startByKey: [String: Date] = [:]
        let cal = calendar
        for expense in expenses {
            // Group by the stable consumption day, not the timestamp re-read
            // in the current zone, so a record never jumps to another day row.
            let day = consumptionDay(of: expense, calendar: cal)
            let key = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
            if byKey[key] == nil {
                order.append(key)
                startByKey[key] = day.date(in: cal) ?? cal.startOfDay(for: expense.date)
            }
            byKey[key, default: []].append(expense)
        }
        return order.compactMap { key in
            guard let rows = byKey[key], let start = startByKey[key] else { return nil }
            return BillDay(dayKey: key, date: start, expenses: rows.sorted { $0.date < $1.date })
        }.sorted { $0.date < $1.date }
    }
}
