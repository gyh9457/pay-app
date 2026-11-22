import Foundation

/// Shared summary logic used by the home screen and (later) the bill screens,
/// so a single source of truth computes every total.
enum LedgerStats {
    /// Gregorian calendar with Monday as the first weekday, matching the
    /// Monday-to-Sunday weekly bill in the requirements.
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = .current
        return cal
    }

    /// Half-open interval [start, end): a record exactly at midnight on the
    /// next day belongs to the next period, never to two periods at once.
    /// - Returns: the exact total, or nil when it exceeds `Int` and cannot be
    ///   represented. Callers must show an explicit out-of-range message rather
    ///   than a capped number that would be confused with a real total.
    static func totalCents(_ expenses: [Expense], in interval: DateInterval) -> Int? {
        // Period totals and every group subtotal share the exact sum below;
        // only the set of records differs (half-open interval vs. a group).
        sumCents(expenses.filter { $0.date >= interval.start && $0.date < interval.end })
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
        var total = 0
        for expense in expenses {
            let (sum, overflow) = total.addingReportingOverflow(expense.amountCents)
            if overflow { return nil }
            total = sum
        }
        return total
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
    static func weekCategoryGroups(_ expenses: [Expense], in interval: DateInterval) -> [CategoryGroup] {
        var order: [String] = []
        var byID: [String: [Expense]] = [:]
        for expense in expenses where expense.date >= interval.start && expense.date < interval.end {
            if byID[expense.categoryID] == nil { order.append(expense.categoryID) }
            byID[expense.categoryID, default: []].append(expense)
        }
        return order.compactMap { id in
            guard let rows = byID[id] else { return nil }
            return CategoryGroup(categoryID: id, expenses: rows.sorted { $0.date < $1.date })
        }
    }

    /// The month's individual records grouped by calendar day, oldest first.
    static func monthDays(_ expenses: [Expense], in interval: DateInterval) -> [BillDay] {
        let inMonth = expenses.filter { $0.date >= interval.start && $0.date < interval.end }
        return billDays(from: inMonth)
    }

    /// All twelve months of the interval's year, each with its own day rows,
    /// so the year view can expand months independently.
    static func yearMonths(_ expenses: [Expense], in interval: DateInterval) -> [BillMonth] {
        let inYear = expenses.filter { $0.date >= interval.start && $0.date < interval.end }
        guard let year = calendar.dateComponents([.year], from: interval.start).year else { return [] }
        var months: [BillMonth] = []
        for month in 1...12 {
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = calendar.date(from: DateComponents(year: year, month: month + 1, day: 1))
            else { continue }
            let rows = inYear.filter { $0.date >= start && $0.date < end }
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
        for expense in expenses {
            let key = dayKey(for: expense.date)
            if byKey[key] == nil {
                order.append(key)
                startByKey[key] = calendar.startOfDay(for: expense.date)
            }
            byKey[key, default: []].append(expense)
        }
        return order.compactMap { key in
            guard let rows = byKey[key], let start = startByKey[key] else { return nil }
            return BillDay(dayKey: key, date: start, expenses: rows.sorted { $0.date < $1.date })
        }.sorted { $0.date < $1.date }
    }

    private static func dayKey(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
