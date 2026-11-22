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
        var total = 0
        for expense in expenses where expense.date >= interval.start && expense.date < interval.end {
            let (sum, overflow) = total.addingReportingOverflow(expense.amountCents)
            if overflow { return nil }
            total = sum
        }
        return total
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
}
