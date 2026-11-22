import SwiftUI

struct ContentView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var categoryStore: CategoryStore
    @State private var isPresentingEntry = false
    @State private var isManagingCategories = false
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
                // Offline landscape drawn in-app (no network, no external
                // asset): part of the shipped bundle, shown above the summary.
                LandscapeHeaderView()
                    .frame(height: 150)
                    .listRowInsets(EdgeInsets())
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
                Section("支出摘要（示例）") {
                    summaryRow("今天", interval: LedgerStats.dayInterval(containing: now))
                    if let week = LedgerStats.weekInterval(containing: now) {
                        NavigationLink {
                            WeekBillView(store: store, categoryStore: categoryStore, interval: week)
                        } label: {
                            summaryContent("本周", interval: week)
                        }
                        .disabled(paused)
                    }
                    if let month = LedgerStats.monthInterval(containing: now) {
                        NavigationLink {
                            MonthBillView(store: store, categoryStore: categoryStore, interval: month)
                        } label: {
                            summaryContent("本月", interval: month)
                        }
                        .disabled(paused)
                    }
                    if let year = LedgerStats.yearInterval(containing: now) {
                        NavigationLink {
                            YearBillView(store: store, categoryStore: categoryStore, interval: year)
                        } label: {
                            summaryContent("本年", interval: year)
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
                        ForEach(store.expenses) { expense in
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
        }
    }

    private func summaryRow(_ title: String, interval: DateInterval?) -> some View {
        summaryContent(title, interval: interval)
    }

    @ViewBuilder
    private func summaryContent(_ title: String, interval: DateInterval?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if store.readiness == .needsRecovery {
                Text("账本暂需恢复")
                    .foregroundStyle(.orange)
            } else if let total = interval.flatMap({ store.totalCents(in: $0) }) {
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

/// A self-contained landscape drawn with SwiftUI shapes. It ships inside the
/// app binary and needs no network or external image file, so the home screen
/// stays fully offline like the rest of the ledger.
private struct LandscapeHeaderView: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        Color(red: 0.42, green: 0.70, blue: 0.92),
                        Color(red: 0.82, green: 0.92, blue: 0.98)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                Circle()
                    .fill(Color.yellow.opacity(0.92))
                    .frame(width: 46, height: 46)
                    .position(x: w * 0.78, y: h * 0.30)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.82))
                    path.addLine(to: CGPoint(x: w * 0.26, y: h * 0.40))
                    path.addLine(to: CGPoint(x: w * 0.48, y: h * 0.74))
                    path.addLine(to: CGPoint(x: w * 0.70, y: h * 0.48))
                    path.addLine(to: CGPoint(x: w, y: h * 0.84))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.33, green: 0.52, blue: 0.43))
                Rectangle()
                    .fill(Color(red: 0.24, green: 0.47, blue: 0.66))
                    .frame(height: h * 0.20)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("离线风景图")
        .accessibilityIdentifier("landscapeHeader")
    }
}

// MARK: - Bill screens (issue 03)

/// A bill total is shown in the same green as home summaries, or an explicit
/// out-of-range message; it is never silently capped.
private struct BillAmount: View {
    let cents: Int?

    var body: some View {
        if let cents {
            Text(Currency.format(cents)).foregroundStyle(.green)
        } else {
            Text("金额超出汇总范围").foregroundStyle(.orange)
        }
    }
}

private func billDateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = LedgerStats.calendar.timeZone
    return formatter.string(from: date)
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
    let categoryStore: CategoryStore

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(categoryStore.subcategoryName(
                    primaryID: expense.categoryID,
                    subcategoryID: expense.subcategoryID)
                    ?? categoryStore.primaryName(for: expense.categoryID))
                Text(billDateLabel(expense.date))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Currency.format(expense.amountCents)).foregroundStyle(.green)
        }
    }
}

struct WeekBillView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var categoryStore: CategoryStore
    let interval: DateInterval
    @State private var expandedGroups: Set<String> = []

    private var groups: [LedgerStats.CategoryGroup] {
        LedgerStats.weekCategoryGroups(store.expenses, in: interval)
    }

    var body: some View {
        List {
            Section("本周支出") {
                HStack {
                    Text("合计")
                    Spacer()
                    BillAmount(cents: LedgerStats.totalCents(store.expenses, in: interval))
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
                            BillExpenseRow(expense: expense, categoryStore: categoryStore)
                        }
                    }
                }
            }
        }
        .navigationTitle("周账单")
    }
}

struct MonthBillView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var categoryStore: CategoryStore
    let interval: DateInterval
    /// The month's day groups start collapsed. Tapping the same month summary
    /// row expands/collapses them in place, matching the monthly bill behavior.
    @State private var isMonthExpanded = false

    private var days: [LedgerStats.BillDay] {
        LedgerStats.monthDays(store.expenses, in: interval)
    }

    var body: some View {
        List {
            Section("本月支出") {
                HStack {
                    Text("合计")
                    Text(billMonthTitle(interval.start))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    BillAmount(cents: LedgerStats.totalCents(store.expenses, in: interval))
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
                                    BillExpenseRow(expense: expense, categoryStore: categoryStore)
                                }
                            }
                        }
                    }
                }
            }
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
    let interval: DateInterval
    /// Each month expands independently. A single tap reveals the month's
    /// date-grouped individual records directly (no second tap on a date).
    @State private var expandedMonths: Set<String> = []

    private var months: [LedgerStats.BillMonth] {
        LedgerStats.yearMonths(store.expenses, in: interval)
    }

    var body: some View {
        List {
            Section("全年支出") {
                HStack {
                    Text("合计")
                    Spacer()
                    BillAmount(cents: LedgerStats.totalCents(store.expenses, in: interval))
                }
            }
            ForEach(months) { month in
                Section {
                    HStack {
                        Text(month.title)
                        Spacer()
                        BillAmount(cents: LedgerStats.sumCents(month.expenses))
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
                        if month.days.isEmpty {
                            Text("本月无记录").foregroundStyle(.secondary)
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
                                    BillExpenseRow(expense: expense, categoryStore: categoryStore)
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
