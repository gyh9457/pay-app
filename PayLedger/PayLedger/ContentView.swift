import SwiftUI

/// An unavailable history file only invalidates a total when that bill's
/// interval could contain a historical amount. Intervals from 2026-12 onward
/// are entirely after the latest possible enable day, so they stay computable
/// from per-record expenses. A nil interval is treated conservatively.
private func historyUnavailable(_ historyStore: HistoryStore, for interval: DateInterval?) -> Bool {
    guard historyStore.isUnavailable else { return false }
    guard let interval else { return true }
    return LedgerStats.historyAffects(interval)
}

struct ContentView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var categoryStore: CategoryStore
    @ObservedObject var historyStore: HistoryStore
    @State private var isPresentingEntry = false
    @State private var isManagingCategories = false
    @State private var isManagingHistory = false
    #if DEBUG
    @State private var clockTick = 0
    #endif

    var body: some View {
        // Resolve the reference date at render time, not at view init: a save
        // after midnight is summarized against the new day/week/month. AppClock
        // is pinned by the cross-midnight UI test and is the real date in prod.
        let now = AppClock.now
        #if DEBUG
        let _ = clockTick // re-evaluate the reference date when a UI test advances it
        #endif
        let paused = store.readiness == .needsRecovery
        NavigationStack {
            List {
                // A persistent status banner. Recovery is decided at launch,
                // before accounting opens, so this never flickers mid-session.
                if paused {
                    Section {
                        Text("账本暂需恢复，记账已暂停。请重新打开应用重试。")
                            .foregroundStyle(.orange)
                    }
                } else if store.readiness == .cleanupPending {
                    Section {
                        Text("旧账本副本待清理")
                            .foregroundStyle(.orange)
                    }
                }
                Section("支出摘要") {
                    summaryRow("今天", interval: LedgerStats.dayInterval(containing: now))
                    if let week = LedgerStats.weekInterval(containing: now) {
                        NavigationLink {
                            WeekBillView(store: store, categoryStore: categoryStore,
                                         historyStore: historyStore, interval: week)
                        } label: {
                            summaryContent("本周", interval: week)
                        }
                        .disabled(paused)
                    }
                    if let month = LedgerStats.monthInterval(containing: now) {
                        NavigationLink {
                            MonthBillView(store: store, categoryStore: categoryStore,
                                          historyStore: historyStore, interval: month)
                        } label: {
                            summaryContent("本月", interval: month, includeHistory: true)
                        }
                        .disabled(paused)
                    }
                    if let year = LedgerStats.yearInterval(containing: now) {
                        NavigationLink {
                            YearBillView(store: store, categoryStore: categoryStore,
                                         historyStore: historyStore, interval: year)
                        } label: {
                            summaryContent("本年", interval: year, includeHistory: true)
                        }
                        .disabled(paused)
                    }
                }
                Section("逐笔支出") {
                    if paused {
                        // Never show an empty/zero ledger whose integrity is
                        // unconfirmed — the recovery prompt replaces it.
                        Text("账本暂需恢复，记账已暂停。请重新打开应用重试。")
                            .foregroundStyle(.secondary)
                    } else if store.expenses.isEmpty {
                        Text("暂无记录，点下方「记一笔」开始。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.expenses.reversed()) { expense in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(categoryStore.primaryName(for: expense.categoryID))
                                    if let sub = categoryStore.subcategoryName(
                                        primaryID: expense.categoryID,
                                        subcategoryID: expense.subcategoryID) {
                                        Text(sub).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(Currency.format(expense.amountCents))
                                    .foregroundStyle(.green)
                            }
                            .modifier(ExpenseRowActions(expense: expense, store: store,
                                                        categoryStore: categoryStore))
                        }
                    }
                }
                #if DEBUG
                if AppClock.overrideDate != nil {
                    // Only present when a UI test pinned the clock; lets the
                    // cross-midnight case advance time on the open home screen.
                    Section("测试时钟") {
                        Button("测试：推进一天") {
                            AppClock.advanceOverride(by: 1)
                            clockTick += 1
                        }
                    }
                }
                #endif
            }
            .navigationTitle("随手记")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("分类") { isManagingCategories = true }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("历史") { isManagingHistory = true }
                        .accessibilityIdentifier("manageHistory")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isPresentingEntry = true } label: { Image(systemName: "plus") }
                        .disabled(paused)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { isPresentingEntry = true } label: {
                    Text("记一笔").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(paused)
                .padding()
            }
            .sheet(isPresented: $isPresentingEntry) {
                ExpenseEntryView(store: store, categoryStore: categoryStore)
            }
            .sheet(isPresented: $isManagingCategories) {
                CategoryManagementView(store: categoryStore)
            }
            .sheet(isPresented: $isManagingHistory) {
                HistoryEntryView(historyStore: historyStore, store: store)
            }
        }
    }

    private func summaryRow(_ title: String, interval: DateInterval?) -> some View {
        summaryContent(title, interval: interval)
    }

    @ViewBuilder
    private func summaryContent(_ title: String, interval: DateInterval?,
                                includeHistory: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            if store.readiness == .needsRecovery {
                Text("账本暂需恢复")
                    .foregroundStyle(.orange)
            } else if includeHistory && historyUnavailable(historyStore, for: interval) {
                // Never present a history-bearing total as complete when the
                // history file is unreadable or its on-device protection is
                // unconfirmed. Intervals after the last possible history
                // (2026-12 onward) and pure per-record summaries keep working.
                Text(HistoryStore.unavailableText)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("historyUnavailableSummary")
            } else if let total = interval.flatMap({
                includeHistory
                    ? LedgerStats.periodTotalCents(store.expenses, history: historyStore.snapshot, in: $0)
                    : LedgerStats.totalCents(store.expenses, history: historyStore.snapshot, in: $0)
            }) {
                Text(Currency.format(total))
                    .foregroundStyle(.green)
            } else {
                // Never present an overflowed/capped value as a real total.
                Text("金额超出汇总范围")
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Offline entry for the pre-enablement amounts the old app could not export.
/// Historical months are month-precise; the opening balance is one cumulative
/// amount through the day before enablement. All values are examples only.
struct HistoryEntryView: View {
    @ObservedObject var historyStore: HistoryStore
    /// Read-only access to per-record data so the form can explain, before
    /// saving, which existing records fall into the opening period.
    @ObservedObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss

    @State private var year = "2026"
    @State private var month = "10"
    @State private var monthAmount = ""
    @State private var openingAmount = ""
    /// First entry leaves the cutoff blank; a saved one is backfilled on appear.
    @State private var cutoffText = ""
    /// Distinguishes a blank field that was never touched (the saved cutoff may
    /// be reused) from one the user explicitly cleared (which must be rejected).
    @State private var cutoffEdited = false
    /// Feedback lives beside each save action so a long list of saved rows
    /// never pushes it off-screen when the user submits an invalid value.
    @State private var monthErrorMessage: String?
    @State private var openingErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if historyStore.isUnavailable {
                    Section {
                        Text("历史不可用：历史汇总文件无法读取或未能确认仅存本机，已保留原文件且不会覆盖。请重新打开应用重试。")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("historyUnavailableBanner")
                    }
                }
                Section("历史月度汇总（仅计月/年）") {
                    TextField("年份", text: $year).keyboardType(.numberPad)
                        .accessibilityIdentifier("historyYear")
                    TextField("月份", text: $month).keyboardType(.numberPad)
                        .accessibilityIdentifier("historyMonth")
                    TextField("总支出金额", text: $monthAmount).keyboardType(.decimalPad)
                        .accessibilityIdentifier("historyMonthAmount")
                    if let monthErrorMessage {
                        Text(monthErrorMessage).foregroundStyle(.orange)
                            .accessibilityIdentifier("historyErrorMessage")
                    }
                    Button("保存历史月份") { saveMonth() }
                        .accessibilityIdentifier("saveHistoryMonth")
                    ForEach(historyStore.snapshot.monthlySummaries) { item in
                        HStack {
                            Text(String(format: "%d年%d月", item.year, item.month))
                            Spacer()
                            Text(Currency.format(item.amountCents)).foregroundStyle(.green)
                        }
                        .accessibilityIdentifier("historyMonthRow")
                    }
                }
                Section("期初累计支出（截至启用前一天）") {
                    TextField("累计金额", text: $openingAmount).keyboardType(.decimalPad)
                        .accessibilityIdentifier("historyOpeningAmount")
                    TextField("累计截止日期 (yyyy-MM-dd)", text: Binding(
                        get: { cutoffText },
                        set: { newValue in
                            cutoffText = newValue
                            cutoffEdited = true
                        }
                    ))
                        .accessibilityIdentifier("historyCutoffDate")
                    // While the per-record ledger is unrecovered its expenses
                    // may be unloaded, so a "0 records covered" warning would
                    // be misleading and the opening save is paused entirely.
                    if store.readiness == .needsRecovery {
                        Text("账本暂需恢复，期初累计暂不可保存。请重新打开应用重试。")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("historyOpeningPausedBanner")
                    } else if !coveredRecords.isEmpty {
                        // Keep the covered-records explanation inside this form,
                        // ahead of the save action, so it is seen before saving
                        // and follows the cutoff the user typed.
                        Text("已有 \(coveredRecords.count) 笔逐笔记录（合计 \(coveredTotalText)）落在覆盖时段，将保留在账本中，但从账单统计中排除。")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("historyCoveredRecordsWarning")
                    }
                    if let openingErrorMessage {
                        Text(openingErrorMessage).foregroundStyle(.orange)
                            .accessibilityIdentifier("historyErrorMessage")
                    }
                    Button("保存期初累计") { saveOpening() }
                        .accessibilityIdentifier("saveHistoryOpening")
                        .disabled(store.readiness == .needsRecovery)
                    if let opening = historyStore.snapshot.openingBalance {
                        HStack {
                            Text("期初累计支出（截至 \(opening.cutoff.text)）")
                            Spacer()
                            Text(Currency.format(opening.amountCents)).foregroundStyle(.green)
                        }
                        .accessibilityIdentifier("historyOpeningRow")
                    }
                }
            }
            .onAppear {
                // Backfill only the untouched blank field. If the user already
                // cleared it, re-filling from the saved value would resurrect
                // the very fallback that must trigger validation.
                if !cutoffEdited, cutoffText.trimmingCharacters(in: .whitespaces).isEmpty,
                   let saved = historyStore.snapshot.openingBalance {
                    cutoffText = saved.cutoff.text
                }
            }
            .navigationTitle("历史账目")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// The cutoff that would be saved right now: the typed date, or the saved
    /// one only when the blank field was never edited (editing just the amount
    /// reuses it). An explicitly cleared field yields nil so preview and save
    /// share the same validation result.
    private var prospectiveCutoff: HistoryInput.CalendarDate? {
        if let parsed = HistoryInput.parseCalendarDate(cutoffText) { return parsed }
        if !cutoffEdited, cutoffText.trimmingCharacters(in: .whitespaces).isEmpty,
           let saved = historyStore.snapshot.openingBalance { return saved.cutoff }
        return nil
    }

    /// Records on or before the prospective cutoff are pre-enablement data.
    /// They stay in the ledger, but the opening balance already represents
    /// that period, so they will be excluded from every bill and summary.
    private var coveredRecords: [Expense] {
        guard let cutoff = prospectiveCutoff else { return [] }
        let cal = LedgerStats.calendar
        return store.expenses.filter { expense in
            // Use the recorded consumption day so the preview and the bills
            // (eligibleExpenses) exclude exactly the same set of records.
            LedgerStats.consumptionDay(of: expense, calendar: cal).tuple <=
                (cutoff.year, cutoff.month, cutoff.day)
        }
    }

    private var coveredTotalText: String {
        LedgerStats.sumCents(coveredRecords).map(Currency.format) ?? "金额超出汇总范围"
    }

    private func saveMonth() {
        openingErrorMessage = nil
        // History totals may be zero; opt in here so per-record entry stays
        // strictly positive via the default parser.
        guard let cents = AmountInput.parseCents(monthAmount, allowZero: true),
              let yearValue = Int(year), let monthValue = Int(month) else {
            monthErrorMessage = "请填写有效金额、年份和月份。"
            return
        }
        do {
            try historyStore.setHistoricalMonth(year: yearValue, month: monthValue, amountCents: cents)
            monthAmount = ""
            monthErrorMessage = nil
        } catch {
            monthErrorMessage = error.localizedDescription
        }
    }

    private func saveOpening() {
        monthErrorMessage = nil
        guard store.readiness != .needsRecovery else {
            openingErrorMessage = LedgerStoreError.openingBalancePausedForRecovery.localizedDescription
            return
        }
        guard let cents = AmountInput.parseCents(openingAmount, allowZero: true) else {
            openingErrorMessage = "请填写有效金额。"
            return
        }
        // Reuse the preview's single validation result so the covered-records
        // explanation and the actual save can never disagree.
        guard let cutoff = prospectiveCutoff else {
            openingErrorMessage = "请填写 2026 年 11 月的有效截止日期（yyyy-MM-dd）。"
            return
        }
        do {
            try historyStore.setOpeningBalance(amountCents: cents, cutoffYear: cutoff.year,
                                               cutoffMonth: cutoff.month, cutoffDay: cutoff.day)
            openingAmount = ""
            openingErrorMessage = nil
        } catch {
            openingErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Bill screens (issue 03)

/// A bill total is shown in the same green as home summaries, or an explicit
/// out-of-range message; it is never silently capped.
private struct BillAmount: View {
    let cents: Int?
    /// When history is unreadable or unprotected, a total that includes it is
    /// not complete and must be flagged rather than shown as a real number.
    var historyUnavailable = false

    var body: some View {
        if historyUnavailable {
            Text(HistoryStore.unavailableText).foregroundStyle(.orange)
                .accessibilityIdentifier("historyUnavailableAmount")
        } else if let cents {
            Text(Currency.format(cents)).foregroundStyle(.green)
        } else {
            Text("金额超出汇总范围").foregroundStyle(.orange)
        }
    }
}

/// The per-record row must show the same consumption day the bill used for
/// attribution. Formatting the raw instant re-read in the current zone would
/// display 11-15 for a record recorded on 11-16 after a time-zone change; the
/// stored day is the single source of truth for both the day grouping and the
/// row label.
private func billDateLabel(for expense: Expense) -> String {
    let day = LedgerStats.consumptionDay(of: expense, calendar: LedgerStats.calendar)
    return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
}

private func billMonthTitle(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月"
    formatter.timeZone = LedgerStats.calendar.timeZone
    return formatter.string(from: date)
}

private struct BillExpenseRow: View {
    let expense: Expense
    let store: LedgerStore
    let categoryStore: CategoryStore

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(categoryStore.subcategoryName(
                    primaryID: expense.categoryID,
                    subcategoryID: expense.subcategoryID)
                    ?? categoryStore.primaryName(for: expense.categoryID))
                Text(billDateLabel(for: expense))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("billExpenseDate-\(expense.id.uuidString)")
            }
            Spacer()
            Text(Currency.format(expense.amountCents)).foregroundStyle(.green)
                .accessibilityIdentifier("billExpenseAmount-\(expense.id.uuidString)")
        }
        .modifier(ExpenseRowActions(expense: expense, store: store, categoryStore: categoryStore))
    }
}

private struct ExpenseRowActions: ViewModifier {
    let expense: Expense
    let store: LedgerStore
    let categoryStore: CategoryStore
    @State private var isEditing = false
    @State private var isConfirmingDeletion = false
    @State private var isShowingDeleteError = false
    @State private var deleteError = ""

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { isEditing = true }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { isConfirmingDeletion = true } label: {
                    Label("删除", systemImage: "trash")
                }
                .tint(.red)
                Button { isEditing = true } label: {
                    Label("修改", systemImage: "pencil")
                }
                .tint(.blue)
            }
            .sheet(isPresented: $isEditing) {
                ExpenseEntryView(store: store, categoryStore: categoryStore, expense: expense)
            }
            .alert("删除这笔流水？", isPresented: $isConfirmingDeletion) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { deleteExpense() }
            } message: {
                Text("删除后无法恢复。")
            }
            .alert("无法删除流水", isPresented: $isShowingDeleteError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(deleteError)
            }
    }

    private func deleteExpense() {
        do {
            try store.deleteExpense(expense)
        } catch {
            deleteError = error.localizedDescription
            isShowingDeleteError = true
        }
    }
}

struct WeekBillView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var categoryStore: CategoryStore
    @ObservedObject var historyStore: HistoryStore
    let interval: DateInterval
    @State private var expandedGroups: Set<String> = []

    private var groups: [LedgerStats.CategoryGroup] {
        LedgerStats.weekCategoryGroups(store.expenses, history: historyStore.snapshot, in: interval)
    }

    var body: some View {
        List {
            Section("本周支出") {
                HStack {
                    Text("合计")
                    Spacer()
                    BillAmount(cents: LedgerStats.totalCents(
                        store.expenses, history: historyStore.snapshot, in: interval))
                }
            }
            ForEach(groups) { group in
                Section {
                    HStack {
                        Text(categoryStore.primaryName(for: group.categoryID))
                        Spacer()
                        BillAmount(cents: LedgerStats.sumCents(group.expenses))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if expandedGroups.contains(group.id) {
                            expandedGroups.remove(group.id)
                        } else {
                            expandedGroups.insert(group.id)
                        }
                    }
                    if expandedGroups.contains(group.id) {
                        ForEach(group.expenses) { expense in
                            BillExpenseRow(expense: expense, store: store, categoryStore: categoryStore)
                        }
                    }
                }
            }
        }
        .navigationTitle("周账单")
    }
}

/// Historical values for one month, shown separately from per-record detail.
/// They have no day/category breakdown, so they never appear in the daily rows
/// or category subtotals that make up the per-record part of a bill.
private struct HistoryRows: View {
    let history: HistorySnapshot
    let interval: DateInterval

    private var months: [HistoricalMonth] {
        LedgerStats.historicalMonths(in: interval, from: history)
    }
    private var opening: OpeningBalance? {
        LedgerStats.openingBalance(in: interval, from: history)
    }

    var body: some View {
        if !months.isEmpty || opening != nil {
            Section("历史汇总（仅计月/年，无逐笔明细）") {
                ForEach(months) { item in
                    HStack {
                        Text(String(format: "%d年%d月", item.year, item.month))
                        Spacer()
                        Text(Currency.format(item.amountCents)).foregroundStyle(.green)
                    }
                    .accessibilityIdentifier("billHistoryMonthRow")
                }
                if let opening {
                    HStack {
                        Text("期初累计支出")
                        Spacer()
                        Text(Currency.format(opening.amountCents)).foregroundStyle(.green)
                    }
                    .accessibilityIdentifier("billHistoryOpeningRow")
                }
            }
        }
    }
}

struct MonthBillView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var categoryStore: CategoryStore
    @ObservedObject var historyStore: HistoryStore
    let interval: DateInterval
    /// The month's day groups start collapsed. Tapping the same month summary
    /// row expands/collapses them in place, matching the monthly bill behavior.
    @State private var isMonthExpanded = false

    private var days: [LedgerStats.BillDay] {
        LedgerStats.monthDays(store.expenses, history: historyStore.snapshot, in: interval)
    }

    var body: some View {
        List {
            Section("本月支出") {
                HStack {
                    Text("合计")
                    Text(billMonthTitle(interval.start))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    BillAmount(cents: LedgerStats.periodTotalCents(
                        store.expenses, history: historyStore.snapshot, in: interval),
                        historyUnavailable: historyUnavailable(historyStore, for: interval))
                }
                .contentShape(Rectangle())
                .onTapGesture { isMonthExpanded.toggle() }
                if isMonthExpanded {
                    if days.isEmpty {
                        Text("本月暂无逐笔记录").foregroundStyle(.secondary)
                    } else {
                        ForEach(days) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(day.dayKey)
                                    Spacer()
                                    BillAmount(cents: LedgerStats.sumCents(day.expenses))
                                }
                                ForEach(day.expenses) { expense in
                                    BillExpenseRow(expense: expense, store: store, categoryStore: categoryStore)
                                }
                            }
                        }
                    }
                }
            }
            HistoryRows(history: historyStore.snapshot, interval: interval)
        }
        .navigationTitle("月账单")
    }
}

/// A year bill's expanded rows, flattened so each individual expense is its
/// own List row. The date header stays visible above that day's expenses, but
/// pairing a subcategory with its amount is now scoped to one row.
private enum YearBillRow: Identifiable {
    case dayHeader(LedgerStats.BillDay)
    case expense(Expense)

    var id: String {
        switch self {
        case .dayHeader(let day): return "day-\(day.id)"
        case .expense(let expense): return "expense-\(expense.id.uuidString)"
        }
    }

    static func rows(for month: LedgerStats.BillMonth) -> [YearBillRow] {
        var result: [YearBillRow] = []
        for day in month.days {
            result.append(.dayHeader(day))
            for expense in day.expenses { result.append(.expense(expense)) }
        }
        return result
    }
}

struct YearBillView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var categoryStore: CategoryStore
    @ObservedObject var historyStore: HistoryStore
    let interval: DateInterval
    /// Each month expands independently. A single tap reveals the month's
    /// date-grouped individual records directly (no second tap on a date).
    @State private var expandedMonths: Set<String> = []
    /// The home link passes the current year, which is the default. History
    /// lives in an earlier year, so the year bill can step back/forward to a
    /// year that owns monthly summaries or the opening balance without
    /// leaving the year-bill page. Month expansion ids include the year, so
    /// each year's months expand independently.
    @State private var yearOffset = 0

    private var baseYear: Int {
        LedgerStats.calendar.dateComponents([.year], from: interval.start).year ?? 0
    }
    private var displayYear: Int { baseYear + yearOffset }
    /// The interval actually rendered. Built from a mid-year anchor so the
    /// displayed year is independent of "now" — with the clock in 2027 the
    /// 2026 history year is still fully viewable.
    private var displayedInterval: DateInterval {
        guard let anchor = LedgerStats.calendar.date(
            from: DateComponents(year: displayYear, month: 6, day: 1)),
              let year = LedgerStats.yearInterval(containing: anchor) else { return interval }
        return year
    }

    private var months: [LedgerStats.BillMonth] {
        LedgerStats.yearMonths(store.expenses, history: historyStore.snapshot, in: displayedInterval)
    }

    private func monthInterval(for month: LedgerStats.BillMonth) -> DateInterval? {
        LedgerStats.calendar.dateInterval(of: .month, for: month.monthStart)
    }

    /// A month with only a historical summary has no per-record rows by
    /// design, so the generic "本月无记录" would contradict the visible
    /// history row. Such months get an explicit per-record-only empty state;
    /// months with neither kind of row keep the original empty state.
    private func monthHasHistory(_ month: LedgerStats.BillMonth) -> Bool {
        guard let monthInterval = monthInterval(for: month) else { return false }
        return !LedgerStats.historicalMonths(in: monthInterval, from: historyStore.snapshot).isEmpty
            || LedgerStats.openingBalance(in: monthInterval, from: historyStore.snapshot) != nil
    }

    var body: some View {
        List {
            Section("账单年份") {
                HStack {
                    Button("上一年") { yearOffset -= 1 }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("yearBillPreviousYear")
                    Spacer()
                    Text(String(format: "%d年", displayYear))
                        .accessibilityIdentifier("yearBillCurrentYear")
                    Spacer()
                    Button("下一年") { yearOffset += 1 }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("yearBillNextYear")
                }
            }
            Section("全年支出") {
                HStack {
                    Text("合计")
                    Spacer()
                    BillAmount(cents: LedgerStats.periodTotalCents(
                        store.expenses, history: historyStore.snapshot, in: displayedInterval),
                        historyUnavailable: historyUnavailable(historyStore, for: displayedInterval))
                }
            }
            ForEach(months) { month in
                Section {
                    HStack {
                        Text(month.title)
                        Spacer()
                        BillAmount(cents: monthInterval(for: month).flatMap {
                            LedgerStats.periodTotalCents(store.expenses, history: historyStore.snapshot, in: $0)
                        }, historyUnavailable: historyUnavailable(historyStore, for: monthInterval(for: month)))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if expandedMonths.contains(month.id) {
                            expandedMonths.remove(month.id)
                        } else {
                            expandedMonths.insert(month.id)
                        }
                    }
                    if expandedMonths.contains(month.id) {
                        if let monthInterval = monthInterval(for: month) {
                            HistoryRows(history: historyStore.snapshot, interval: monthInterval)
                        }
                        if month.days.isEmpty {
                            Text(monthHasHistory(month) ? "本月无逐笔记录" : "本月无记录")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(YearBillRow.rows(for: month)) { row in
                                switch row {
                                case .dayHeader(let day):
                                    HStack {
                                        Text(day.dayKey)
                                        Spacer()
                                        BillAmount(cents: LedgerStats.sumCents(day.expenses))
                                    }
                                case .expense(let expense):
                                    BillExpenseRow(expense: expense, store: store, categoryStore: categoryStore)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("年账单")
    }
}
