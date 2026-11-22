import Foundation

/// A single cash expense. Amounts are stored as integer cents so that
/// summaries and bill totals never suffer from floating-point rounding.
struct Expense: Identifiable, Codable, Equatable {
    let id: UUID
    let amountCents: Int
    let categoryID: String
    let date: Date

    init(id: UUID = UUID(), amountCents: Int, categoryID: String, date: Date) {
        self.id = id
        self.amountCents = amountCents
        self.categoryID = categoryID
        self.date = date
    }
}

/// Parses the amount typed on the entry form into integer cents.
/// This is the public seam the entry form and its tests share.
enum AmountInput {
    /// - Returns: cents, or nil for empty, non-numeric, non-positive,
    ///   or sub-cent (more than two decimal places) input.
    static func parseCents(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // A native decimal pad lets the user begin at the separator (".05" or
        // ",05"), and a decimal-comma locale emits "," instead of "." ("12,34").
        // Accept one optional separator ("." or ",") with 1-2 fraction digits
        // and treat an omitted integer part as zero. More fraction digits
        // ("1,234") or a second separator is a grouping/thousands form and
        // stays rejected. Any number of integer digits is fine as long as the
        // resulting cents fit in Int.
        let pattern = #"^(\d*)(?:[.,](\d{1,2}))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let wholeRange = Range(match.range(at: 1), in: text) else { return nil }

        let wholeText = text[wholeRange]
        let fractionRange = Range(match.range(at: 2), in: text)
        // At least one digit must be present in either part; "." / "," alone
        // is not an amount.
        guard !wholeText.isEmpty || fractionRange != nil else { return nil }
        guard let whole = (wholeText.isEmpty ? 0 : Int(wholeText)) else { return nil }

        var fraction = 0
        if let fractionRange {
            let digits = text[fractionRange]
            guard let part = Int(digits) else { return nil }
            fraction = digits.count == 1 ? part * 10 : part
        }

        // whole * 100 + fraction must stay within Int; check before multiplying
        // so an overflowing amount is rejected instead of trapping or wrapping.
        guard whole <= (Int.max - fraction) / 100 else { return nil }
        let cents = whole * 100 + fraction
        guard cents > 0 else { return nil }
        return cents
    }
}

/// Clock used for "now". Production always uses the real date; UI tests pin
/// it via the `PAYLEDGER_TEST_NOW` launch environment (local time, "yyyy-MM-dd'T'HH:mm:ss")
/// so the cross-midnight scenario is rerunnable and deterministic. Production
/// launches never set that variable.
enum AppClock {
    static var overrideDate: Date?

    static var now: Date {
        overrideDate ?? Date()
    }

    /// Advances a pinned clock so a UI test can cross midnight on an already
    /// open screen without terminating and relaunching the app.
    static func advanceOverride(by days: Int) {
        guard let current = overrideDate else { return }
        overrideDate = Calendar.current.date(byAdding: .day, value: days, to: current)
    }

    /// Parses the pinned date in the device's local time zone.
    static func parseOverride(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: string)
    }
}

enum Currency {
    static func format(_ cents: Int) -> String {
        // Use %lld (Int64) for the yuan part: a 32-bit %d overflows at
        // 2,147,483,647 and renders large totals as negative numbers.
        let yuan = Int64(cents / 100)
        let fraction = Int64(abs(cents % 100))
        return String(format: "%lld.%02lld", yuan, fraction)
    }
}

/// Maps the example category identifiers used by the entry form to the
/// names shown in the ledger list. Full category maintenance is issue 02.
enum ExpenseCategory {
    static func displayName(for id: String) -> String {
        switch id {
        case "food": return "食品酒水"
        case "transport": return "交通"
        default: return id
        }
    }
}
