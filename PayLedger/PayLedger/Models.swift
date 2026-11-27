import Foundation

/// The calendar day the user chose when recording an expense. It is stored as
/// year/month/day components rather than an instant so re-opening the ledger
/// in a different device time zone never moves the record into another day.
/// `nil` only occurs on ledgers written before this field existed; the store
/// fills it once on first load using the device calendar at that moment.
struct ConsumptionDay: Codable, Equatable {
    let year: Int
    let month: Int
    let day: Int

    /// Tuples of calendar components compare oldest-to-newest, the same shape
    /// the opening cutoff uses, so coverage and bills share one comparison.
    var tuple: (Int, Int, Int) { (year, month, day) }

    static func from(_ date: Date, calendar: Calendar) -> ConsumptionDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return ConsumptionDay(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

/// A single cash expense. Amounts are stored as integer cents so that
/// summaries and bill totals never suffer from floating-point rounding.
struct Expense: Identifiable, Codable, Equatable {
    let id: UUID
    let amountCents: Int
    /// Stable primary-category id. Kept as the legacy id ("food"/"transport")
    /// so expenses saved before category maintenance existed still resolve.
    let categoryID: String
    /// Optional leaf id selected on the two-level wheel. Absent on records
    /// created before issue 02; Swift's synthesized decoder fills nil.
    let subcategoryID: String?
    let date: Date
    let note: String?
    /// The day chosen at recording time. Optional only so old ledgers still
    /// decode; synthesized decoding fills nil for the missing key. Expenses
    /// created by the app always carry a day. `var` so a first-load backfill
    /// can add it to a decoded legacy record.
    var consumptionDay: ConsumptionDay?

    init(id: UUID = UUID(), amountCents: Int, categoryID: String,
         subcategoryID: String? = nil, date: Date,
         consumptionDay: ConsumptionDay? = nil, note: String? = nil) {
        self.id = id
        self.amountCents = amountCents
        self.categoryID = categoryID
        self.subcategoryID = subcategoryID
        self.date = date
        self.note = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // Expenses created by the app carry the day chosen at record time,
        // captured in the device calendar. Callers building a record in a
        // different calendar (tests) can pass that day explicitly. nil is
        // reserved for JSON-decoded legacy records the store backfills once.
        self.consumptionDay = consumptionDay ?? ConsumptionDay.from(date, calendar: LedgerStats.calendar)
    }

    /// Whether two records describe the same expense by its original fields.
    /// `consumptionDay` is deliberately excluded: a legacy copy that had not
    /// been backfilled yet and a live copy that has represent the same expense,
    /// and migration must not import that single UUID twice. Any genuine
    /// difference in the original fields still makes the records distinct.
    func hasSameOriginalFields(as other: Expense) -> Bool {
        id == other.id
            && amountCents == other.amountCents
            && categoryID == other.categoryID
            && subcategoryID == other.subcategoryID
            && date == other.date
    }
}

/// Parses the amount typed on the entry form into integer cents.
/// This is the public seam the entry form and its tests share.
enum AmountInput {
    /// - Parameter allowZero: when true, `0` / `0.00` parse as 0. Historical
    ///   month totals and the opening balance may be zero (a user with no
    ///   pre-enablement spend); per-record expenses keep the default `false`
    ///   and stay strictly positive. Negatives and invalid input are always
    ///   rejected regardless of this flag.
    /// - Returns: cents, or nil for empty, non-numeric, non-positive
    ///   (unless `allowZero`), or sub-cent (more than two decimal places)
    ///   input.
    static func parseCents(_ raw: String, allowZero: Bool = false) -> Int? {
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
        guard cents > 0 || (allowZero && cents == 0) else { return nil }
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
        // Follow the same calendar (including a DEBUG time-zone override) that
        // attribution uses, so a pinned clock and the recorded day agree.
        formatter.timeZone = LedgerStats.calendar.timeZone
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

/// Legacy display names for category ids saved before the editable category
/// tree existed. The category store falls back to this for unknown ids.
enum ExpenseCategory {
    static func displayName(for id: String) -> String {
        switch id {
        case "food": return "食品酒水"
        case "transport": return "行车交通"
        default: return id
        }
    }
}

/// A user-editable leaf category. `id` is stable so renaming `name` never
/// orphans expenses that reference it.
struct ExpenseSubcategory: Identifiable, Codable, Equatable {
    let id: String
    var name: String
}

/// A user-editable primary category with its ordered subcategories.
struct ExpenseCategoryGroup: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var subcategories: [ExpenseSubcategory]
}

/// The built-in tree follows the order of the recorded expense picker.
/// IDs from the original example tree still identify the same expenses.
enum ExpenseCategories {
    static let defaults: [ExpenseCategoryGroup] = [
        ExpenseCategoryGroup(id: "food", name: "食品酒水", subcategories: [
            ExpenseSubcategory(id: "food-meal", name: "早午晚餐"),
            ExpenseSubcategory(id: "food-tobacco-tea", name: "烟酒茶"),
            ExpenseSubcategory(id: "food-snack", name: "水果零食"),
        ]),
        ExpenseCategoryGroup(id: "home", name: "居家物业", subcategories: [
            ExpenseSubcategory(id: "home-supplies", name: "日常用品"),
            ExpenseSubcategory(id: "home-utilities", name: "水电煤气"),
            ExpenseSubcategory(id: "home-rent", name: "房租"),
            ExpenseSubcategory(id: "home-management", name: "物业管理"),
            ExpenseSubcategory(id: "home-maintenance", name: "维修保养"),
        ]),
        ExpenseCategoryGroup(id: "clothing", name: "衣服饰品", subcategories: [
            ExpenseSubcategory(id: "clothing-clothes", name: "衣服裤子"),
            ExpenseSubcategory(id: "clothing-accessories", name: "鞋帽包包"),
            ExpenseSubcategory(id: "clothing-cosmetics", name: "化妆饰品"),
        ]),
        ExpenseCategoryGroup(id: "transport", name: "行车交通", subcategories: [
            ExpenseSubcategory(id: "transport-bus", name: "公共交通"),
            ExpenseSubcategory(id: "transport-taxi", name: "打车租车"),
            ExpenseSubcategory(id: "transport-car", name: "私家车费用"),
            ExpenseSubcategory(id: "transport-fuel", name: "油费"),
            ExpenseSubcategory(id: "transport-toll", name: "高速"),
            ExpenseSubcategory(id: "transport-supplies", name: "车内用品"),
            ExpenseSubcategory(id: "transport-parking", name: "停车费"),
            ExpenseSubcategory(id: "transport-loan", name: "车贷"),
            ExpenseSubcategory(id: "transport-fine", name: "罚款"),
            ExpenseSubcategory(id: "transport-wash", name: "洗车"),
        ]),
        ExpenseCategoryGroup(id: "communication", name: "交流通讯", subcategories: [
            ExpenseSubcategory(id: "communication-landline", name: "座机费"),
            ExpenseSubcategory(id: "communication-mobile", name: "手机费"),
            ExpenseSubcategory(id: "communication-internet", name: "上网费"),
            ExpenseSubcategory(id: "communication-postage", name: "邮寄费"),
        ]),
        ExpenseCategoryGroup(id: "leisure", name: "休闲娱乐", subcategories: [
            ExpenseSubcategory(id: "leisure-fitness", name: "运动健身"),
            ExpenseSubcategory(id: "leisure-gathering", name: "腐败聚会"),
            ExpenseSubcategory(id: "leisure-recreation", name: "休闲玩乐"),
            ExpenseSubcategory(id: "leisure-pets", name: "宠物宝贝"),
            ExpenseSubcategory(id: "leisure-travel", name: "旅游度假"),
        ]),
        ExpenseCategoryGroup(id: "education", name: "学习进修", subcategories: [
            ExpenseSubcategory(id: "education-devices", name: "数码装备"),
            ExpenseSubcategory(id: "education-books", name: "书报杂志"),
            ExpenseSubcategory(id: "education-training", name: "培训进修"),
        ]),
        ExpenseCategoryGroup(id: "social", name: "人情往来", subcategories: [
            ExpenseSubcategory(id: "social-gifts", name: "送礼请客"),
            ExpenseSubcategory(id: "social-parents", name: "孝敬家长"),
            ExpenseSubcategory(id: "social-repayment", name: "还人钱物"),
            ExpenseSubcategory(id: "social-donation", name: "慈善捐助"),
            ExpenseSubcategory(id: "social-wedding", name: "婚礼"),
        ]),
        ExpenseCategoryGroup(id: "health", name: "医疗保健", subcategories: [
            ExpenseSubcategory(id: "health-medicine", name: "药品费"),
            ExpenseSubcategory(id: "health-wellness", name: "保健费"),
            ExpenseSubcategory(id: "health-beauty", name: "美容费"),
            ExpenseSubcategory(id: "health-treatment", name: "治疗费"),
        ]),
        ExpenseCategoryGroup(id: "finance", name: "金融保险", subcategories: [
            ExpenseSubcategory(id: "finance-banking", name: "银行手续"),
            ExpenseSubcategory(id: "finance-investment", name: "投资亏损"),
            ExpenseSubcategory(id: "finance-mortgage", name: "按揭还款"),
            ExpenseSubcategory(id: "finance-tax", name: "消费税收"),
            ExpenseSubcategory(id: "finance-interest", name: "利息支出"),
            ExpenseSubcategory(id: "finance-compensation", name: "赔偿罚款"),
        ]),
        ExpenseCategoryGroup(id: "other", name: "其他杂项", subcategories: [
            ExpenseSubcategory(id: "other-expense", name: "其他支出"),
            ExpenseSubcategory(id: "other-loss", name: "意外丢失"),
            ExpenseSubcategory(id: "other-bad-debt", name: "烂账损失"),
        ]),
    ]

    private static let previousDefaultNames = [
        "transport": "交通",
        "food-snack": "零食饮料",
        "transport-bus": "公交地铁",
        "transport-taxi": "打车",
    ]

    /// Add newly built-in choices at load time while retaining user edits.
    /// The next category edit persists the merged tree through the usual save path.
    static func mergingSavedGroups(_ saved: [ExpenseCategoryGroup]) -> [ExpenseCategoryGroup] {
        // The first expanded catalog always saves the built-in home group.
        // Once present, even a deliberate rename to an old default is user data.
        let isLegacy = !saved.contains { $0.id == "home" }
        let oldNames = isLegacy ? previousDefaultNames : [:]
        let builtInIDs = Set(defaults.map(\.id))
        let updated = defaults.map { group in
            guard let existing = saved.first(where: { $0.id == group.id }) else { return group }
            let builtInChildIDs = Set(group.subcategories.map(\.id))
            let children = group.subcategories.map { child in
                guard let existingChild = existing.subcategories.first(where: { $0.id == child.id }),
                      existingChild.name != oldNames[child.id] else { return child }
                return existingChild
            }
            return ExpenseCategoryGroup(
                id: group.id,
                name: existing.name == oldNames[group.id] ? group.name : existing.name,
                subcategories: children + existing.subcategories.filter { !builtInChildIDs.contains($0.id) }
            )
        }
        return updated + saved.filter { !builtInIDs.contains($0.id) }
    }
}

// MARK: - Issue 04: historical amounts (example values only)

/// One month-level total supplied by the user because the old app could not
/// export a ledger. It is precise only to (year, month), so it has no day or
/// category breakdown. `key` is stable: re-saving the same month replaces the
/// value instead of adding a second summary (which would double-count).
struct HistoricalMonth: Identifiable, Codable, Equatable {
    let year: Int
    let month: Int
    let amountCents: Int

    var key: String { String(format: "%04d-%02d", year, month) }
    var id: String { key }

    init(year: Int, month: Int, amountCents: Int) {
        self.year = year
        self.month = month
        self.amountCents = amountCents
    }
}

/// Validation for the pre-enablement amounts the user types. Whole-month
/// summaries are accepted only for a valid year-month strictly before
/// November 2026; the opening cutoff must be a real November 2026 calendar day
/// whose next day is the enablement day. The form and the store share these
/// rules so invalid input is rejected in exactly one place.
enum HistoryInput {
    /// A date kept as the displayed calendar components, never as an instant,
    /// so a restart under a different time zone still shows the same day.
    struct CalendarDate: Equatable {
        let year: Int
        let month: Int
        let day: Int

        var text: String { String(format: "%04d-%02d-%02d", year, month, day) }
        var components: DateComponents { DateComponents(year: year, month: month, day: day) }
    }

    /// A month summary must be a valid year-month before November 2026.
    static func isValidHistoricalMonth(year: Int, month: Int) -> Bool {
        guard (1...12).contains(month), year > 0 else { return false }
        return year < 2026 || (year == 2026 && month < 11)
    }

    /// The cutoff must be a real day in November 2026. A fixed UTC Gregorian
    /// calendar round-trips the components to reject non-existent days
    /// (e.g. November 31) independently of the device time zone.
    static func isValidOpeningCutoff(year: Int, month: Int, day: Int) -> Bool {
        guard year == 2026, month == 11 else { return false }
        let cal = utcCalendar
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        return parts.year == year && parts.month == month && parts.day == day
    }

    /// Parses a strict `yyyy-MM-dd` string into validated calendar components.
    static func parseCalendarDate(_ text: String) -> CalendarDate? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let yearRange = Range(match.range(at: 1), in: text),
              let monthRange = Range(match.range(at: 2), in: text),
              let dayRange = Range(match.range(at: 3), in: text),
              let year = Int(text[yearRange]),
              let month = Int(text[monthRange]),
              let day = Int(text[dayRange]),
              isValidOpeningCutoff(year: year, month: month, day: day) else { return nil }
        return CalendarDate(year: year, month: month, day: day)
    }

    /// The first day of per-record accounting: the calendar day after cutoff.
    static func dayAfter(_ date: CalendarDate) -> CalendarDate {
        let cal = utcCalendar
        let next = cal.date(byAdding: .day, value: 1, to: cal.date(from: date.components)!)!
        let parts = cal.dateComponents([.year, .month, .day], from: next)
        return CalendarDate(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }
}

/// A single cumulative expense covering the first of the enablement month
/// through `cutoff` (the day before enablement), inclusive. The cutoff is
/// stored as calendar year/month/day, so it attributes to November 2026 and
/// survives a restart in another time zone. It is added to that month's and
/// that year's total exactly once; it has no per-day or per-category detail
/// and never appears in week/daily/category subtotals.
struct OpeningBalance: Codable, Equatable {
    let amountCents: Int
    let cutoffYear: Int
    let cutoffMonth: Int
    let cutoffDay: Int

    init(amountCents: Int, cutoffYear: Int, cutoffMonth: Int, cutoffDay: Int) {
        self.amountCents = amountCents
        self.cutoffYear = cutoffYear
        self.cutoffMonth = cutoffMonth
        self.cutoffDay = cutoffDay
    }

    /// Convenience for callers that already hold a Date (example fixtures):
    /// components are read in the ledger calendar and then stored as integers.
    init(amountCents: Int, cutoffDate: Date) {
        let parts = LedgerStats.calendar.dateComponents([.year, .month, .day], from: cutoffDate)
        self.init(amountCents: amountCents, cutoffYear: parts.year ?? 0,
                  cutoffMonth: parts.month ?? 0, cutoffDay: parts.day ?? 0)
    }

    var cutoff: HistoryInput.CalendarDate {
        HistoryInput.CalendarDate(year: cutoffYear, month: cutoffMonth, day: cutoffDay)
    }

    var enableDay: HistoryInput.CalendarDate {
        HistoryInput.dayAfter(cutoff)
    }

    var cutoffDate: Date? {
        LedgerStats.calendar.date(from: cutoff.components)
    }
}

/// All pre-enablement amounts the user supplied. Stored as one snapshot so a
/// save can publish it atomically and a restart reads the exact same values.
struct HistorySnapshot: Codable, Equatable {
    var monthlySummaries: [HistoricalMonth] = []
    var openingBalance: OpeningBalance? = nil

    init(monthlySummaries: [HistoricalMonth] = [], openingBalance: OpeningBalance? = nil) {
        self.monthlySummaries = monthlySummaries
        self.openingBalance = openingBalance
    }

    /// A decoded snapshot is published only when every field is a value the
    /// app itself could have saved. A structurally valid file with duplicate
    /// months, an out-of-range period, a negative amount or an invalid cutoff
    /// would otherwise render a plausible but wrong total. Validation shares
    /// the same rules as the input form and the setters, so a file and a fresh
    /// save can never disagree about what is a legal history. Zero is allowed
    /// for history totals (only per-record spending must be positive).
    var isValid: Bool {
        var seenKeys = Set<String>()
        for month in monthlySummaries {
            guard HistoryInput.isValidHistoricalMonth(year: month.year, month: month.month),
                  month.amountCents >= 0,
                  seenKeys.insert(month.key).inserted else { return false }
        }
        if let opening = openingBalance {
            guard opening.amountCents >= 0,
                  HistoryInput.isValidOpeningCutoff(year: opening.cutoffYear,
                                                    month: opening.cutoffMonth,
                                                    day: opening.cutoffDay) else { return false }
        }
        return true
    }
}
